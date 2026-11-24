//! Command-line parsing. Pure: no process state, no I/O except `usage`.

const std = @import("std");
const env = @import("libretro/env.zig");

pub const Command = enum { none, help, version, run };

/// At most this many `--option` flags; parsing stays allocation-free.
pub const max_core_options = 64;

pub const Options = struct {
    command: Command = .none,
    verbose: bool = false,
    log_file: ?[]const u8 = null,
    /// Set when `command == .run`.
    run: Run = .{},
};

/// `temui run --headless ...`. `core`, `rom` and `frames` are always set once
/// parsing succeeds with `command == .run`.
pub const Run = struct {
    core: []const u8 = "",
    rom: []const u8 = "",
    frames: u64 = 0,
    dump_ppm: ?[]const u8 = null,
    dump_every: u64 = 1,
    system_dir: ?[]const u8 = null,
    save_dir: ?[]const u8 = null,
    option_buf: [max_core_options]env.Override = undefined,
    option_len: usize = 0,

    /// The `--option` overrides in command-line order. Points into `self`, so
    /// take it from a `Run` that stays put.
    pub fn options(self: *const Run) []const env.Override {
        return self.option_buf[0..self.option_len];
    }
};

pub const Error = struct {
    kind: Kind,
    /// The offending argument (or the option's name), as given.
    arg: []const u8,
    /// The offending value, for kinds that have one.
    value: []const u8 = "",

    pub const Kind = enum {
        unknown_option,
        missing_value,
        unexpected_argument,
        /// `arg` is a run option given without the `run` command.
        run_only,
        /// `run` without `--headless`.
        headless_required,
        /// `arg` is a required run option that is missing.
        missing_required,
        /// `arg`'s `value` is not a positive integer.
        invalid_number,
        /// `--option`'s `value` is not `key=value` with a non-empty key.
        malformed_option,
        too_many_options,
    };

    pub fn write(e: Error, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (e.kind) {
            .unknown_option => try w.print("temui: unknown option '{s}'\n", .{e.arg}),
            .missing_value => try w.print("temui: option '{s}' requires a value\n", .{e.arg}),
            .unexpected_argument => try w.print("temui: unexpected argument '{s}'\n", .{e.arg}),
            .run_only => try w.print("temui: option '{s}' is only valid with 'run'\n", .{e.arg}),
            .headless_required => try w.writeAll("temui: run requires --headless (interactive run arrives in a later item)\n"),
            .missing_required => try w.print("temui: run requires '{s}'\n", .{e.arg}),
            .invalid_number => try w.print("temui: option '{s}' needs a positive integer, got '{s}'\n", .{ e.arg, e.value }),
            .malformed_option => try w.print("temui: option '{s}' needs <key>=<value>, got '{s}'\n", .{ e.arg, e.value }),
            .too_many_options => try w.print("temui: too many '{s}' options (at most {d})\n", .{ e.arg, max_core_options }),
        }
        try w.writeAll("Try 'temui --help' for more information.\n");
    }
};

pub const Result = union(enum) {
    ok: Options,
    err: Error,
};

/// Options that take a value, as `--name value` or `--name=value`.
const Valued = enum { log_file, core, rom, frames, dump_ppm, dump_every, option, system_dir, save_dir };

fn valuedName(v: Valued) []const u8 {
    return switch (v) {
        .log_file => "--log-file",
        .core => "--core",
        .rom => "--rom",
        .frames => "--frames",
        .dump_ppm => "--dump-ppm",
        .dump_every => "--dump-every",
        .option => "--option",
        .system_dir => "--system-dir",
        .save_dir => "--save-dir",
    };
}

/// Parses arguments, excluding the program name (argv[0]).
/// `--help` takes precedence over everything else, `--version` over `run`.
pub fn parse(args: []const [:0]const u8) Result {
    var opts: Options = .{};
    var run_cmd = false;
    var headless = false;
    var frames_set = false;
    // The first run option seen, for the error when `run` is missing.
    var first_run_option: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (eql(arg, "-h") or eql(arg, "--help")) {
            opts.command = .help;
        } else if (eql(arg, "-V") or eql(arg, "--version")) {
            if (opts.command != .help) opts.command = .version;
        } else if (eql(arg, "-v") or eql(arg, "--verbose")) {
            opts.verbose = true;
        } else if (eql(arg, "--headless")) {
            headless = true;
            if (first_run_option == null) first_run_option = arg;
        } else if (matchValued(arg)) |m| {
            const value = m.inline_value orelse blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            const name = valuedName(m.which);
            if (value.len == 0) return .{ .err = .{ .kind = .missing_value, .arg = name } };
            if (m.which != .log_file and first_run_option == null) first_run_option = name;
            switch (m.which) {
                .log_file => opts.log_file = value,
                .core => opts.run.core = value,
                .rom => opts.run.rom = value,
                .dump_ppm => opts.run.dump_ppm = value,
                .system_dir => opts.run.system_dir = value,
                .save_dir => opts.run.save_dir = value,
                .frames, .dump_every => {
                    // parseInt also accepts '+' and '_' separators; allow digits only.
                    const digits = for (value) |ch| {
                        if (!std.ascii.isDigit(ch)) break false;
                    } else true;
                    const n = if (digits) std.fmt.parseInt(u64, value, 10) catch 0 else 0;
                    if (n == 0) return .{ .err = .{ .kind = .invalid_number, .arg = name, .value = value } };
                    if (m.which == .frames) {
                        opts.run.frames = n;
                        frames_set = true;
                    } else opts.run.dump_every = n;
                },
                .option => {
                    const eq = std.mem.indexOfScalar(u8, value, '=') orelse 0;
                    if (eq == 0) return .{ .err = .{ .kind = .malformed_option, .arg = name, .value = value } };
                    if (opts.run.option_len == max_core_options) return .{ .err = .{ .kind = .too_many_options, .arg = name } };
                    opts.run.option_buf[opts.run.option_len] = .{ .key = value[0..eq], .value = value[eq + 1 ..] };
                    opts.run.option_len += 1;
                },
            }
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .err = .{ .kind = .unknown_option, .arg = arg } };
        } else if (eql(arg, "run") and !run_cmd) {
            run_cmd = true;
        } else {
            return .{ .err = .{ .kind = .unexpected_argument, .arg = arg } };
        }
    }

    if (opts.command != .none) return .{ .ok = opts };
    if (!run_cmd) {
        if (first_run_option) |name| return .{ .err = .{ .kind = .run_only, .arg = name } };
        return .{ .ok = opts };
    }
    if (!headless) return .{ .err = .{ .kind = .headless_required, .arg = "run" } };
    if (opts.run.core.len == 0) return .{ .err = .{ .kind = .missing_required, .arg = "--core" } };
    if (opts.run.rom.len == 0) return .{ .err = .{ .kind = .missing_required, .arg = "--rom" } };
    if (!frames_set) return .{ .err = .{ .kind = .missing_required, .arg = "--frames" } };
    opts.command = .run;
    return .{ .ok = opts };
}

const Match = struct { which: Valued, inline_value: ?[]const u8 };

/// Recognises `--name` and `--name=value` for every valued option.
fn matchValued(arg: []const u8) ?Match {
    inline for (@typeInfo(Valued).@"enum".field_names) |field| {
        const v = @field(Valued, field);
        const name = valuedName(v);
        if (eql(arg, name)) return .{ .which = v, .inline_value = null };
        if (std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=')
            return .{ .which = v, .inline_value = arg[name.len + 1 ..] };
    }
    return null;
}

pub fn usage(w: *std.Io.Writer, log_dir: []const u8) std.Io.Writer.Error!void {
    try w.print(
        \\temui — a terminal libretro frontend
        \\
        \\Usage: temui [options]
        \\       temui run --headless --core <path> --rom <path> --frames <N> [run options]
        \\
        \\Options:
        \\  -h, --help              Show this help and exit
        \\  -V, --version           Show the version and exit
        \\  -v, --verbose           Log at debug level
        \\      --log-file <path>   Log to <path> instead of the log directory
        \\
        \\Run options:
        \\      --headless          Run without a display (required for now)
        \\      --core <path>       The libretro core to load
        \\      --rom <path>        The content to load
        \\      --frames <N>        Run N frames as fast as possible, then exit
        \\      --dump-ppm <dir>    Write frames to <dir>/frame-NNNNNN.ppm
        \\      --dump-every <K>    Dump every K-th frame (default 1); the last is always dumped
        \\      --option <k>=<v>    Set a core option (repeatable)
        \\      --system-dir <dir>  The core's system (BIOS) directory (default: the ROM's)
        \\      --save-dir <dir>    The core's save directory (default: the ROM's)
        \\
        \\Logs: {s}
        \\
    , .{log_dir});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

fn expectOk(args: []const [:0]const u8, want: Options) !void {
    const r = parse(args);
    try testing.expect(r == .ok);
    try testing.expectEqual(want.command, r.ok.command);
    try testing.expectEqual(want.verbose, r.ok.verbose);
    if (want.log_file) |p| {
        try testing.expectEqualStrings(p, r.ok.log_file.?);
    } else {
        try testing.expectEqual(null, r.ok.log_file);
    }
}

fn expectErr(args: []const [:0]const u8, kind: Error.Kind, arg: []const u8) !void {
    const r = parse(args);
    try testing.expect(r == .err);
    try testing.expectEqual(kind, r.err.kind);
    try testing.expectEqualStrings(arg, r.err.arg);
}

test "no arguments" {
    try expectOk(&.{}, .{});
}

test "help and version flags" {
    try expectOk(&.{"-h"}, .{ .command = .help });
    try expectOk(&.{"--help"}, .{ .command = .help });
    try expectOk(&.{"-V"}, .{ .command = .version });
    try expectOk(&.{"--version"}, .{ .command = .version });
    try expectOk(&.{ "--version", "--help" }, .{ .command = .help });
    try expectOk(&.{ "--help", "--version" }, .{ .command = .help });
}

test "verbose and log file" {
    try expectOk(&.{"-v"}, .{ .verbose = true });
    try expectOk(&.{ "--verbose", "--version" }, .{ .command = .version, .verbose = true });
    try expectOk(&.{ "--log-file", "/tmp/x.log" }, .{ .log_file = "/tmp/x.log" });
    try expectOk(&.{"--log-file=/tmp/y.log"}, .{ .log_file = "/tmp/y.log" });
    try expectOk(&.{ "-v", "--log-file", "a", "-V" }, .{ .command = .version, .verbose = true, .log_file = "a" });
}

test "errors" {
    try expectErr(&.{"--bogus"}, .unknown_option, "--bogus");
    try expectErr(&.{"-x"}, .unknown_option, "-x");
    try expectErr(&.{"--log-file"}, .missing_value, "--log-file");
    try expectErr(&.{ "--log-file", "" }, .missing_value, "--log-file");
    try expectErr(&.{"--log-file="}, .missing_value, "--log-file");
    try expectErr(&.{"game.sfc"}, .unexpected_argument, "game.sfc");
    try expectErr(&.{"-"}, .unexpected_argument, "-");
}

test "error message" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (Error{ .kind = .unknown_option, .arg = "--bogus" }).write(&w);
    try testing.expectEqualStrings(
        "temui: unknown option '--bogus'\nTry 'temui --help' for more information.\n",
        w.buffered(),
    );
}

test "usage mentions log dir" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try usage(&w, "/logs/here");
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Logs: /logs/here\n") != null);
}

fn expectRun(args: []const [:0]const u8) !Run {
    const r = parse(args);
    if (r == .err) {
        std.debug.print("unexpected error: {t} {s} {s}\n", .{ r.err.kind, r.err.arg, r.err.value });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(Command.run, r.ok.command);
    return r.ok.run;
}

const base_run = [_][:0]const u8{ "run", "--headless", "--core", "c.so", "--rom", "g.sfc", "--frames", "60" };

test "run: required options and defaults" {
    const r = try expectRun(&base_run);
    try testing.expectEqualStrings("c.so", r.core);
    try testing.expectEqualStrings("g.sfc", r.rom);
    try testing.expectEqual(60, r.frames);
    try testing.expectEqual(null, r.dump_ppm);
    try testing.expectEqual(1, r.dump_every);
    try testing.expectEqual(null, r.system_dir);
    try testing.expectEqual(null, r.save_dir);
    try testing.expectEqual(0, r.options().len);
}

test "run: every option, both value forms, any order" {
    const r = try expectRun(&.{
        "-v",             "--frames=10",      "run",              "--core=c.dylib",
        "--headless",     "--rom",            "g.gb",             "--dump-ppm",
        "out",            "--dump-every=5",   "--option",         "a=1",
        "--option=b=x=y", "--option",         "c=",               "--system-dir",
        "sys",            "--save-dir=saves", "--log-file=l.log",
    });
    try testing.expectEqualStrings("c.dylib", r.core);
    try testing.expectEqualStrings("g.gb", r.rom);
    try testing.expectEqual(10, r.frames);
    try testing.expectEqualStrings("out", r.dump_ppm.?);
    try testing.expectEqual(5, r.dump_every);
    try testing.expectEqualStrings("sys", r.system_dir.?);
    try testing.expectEqualStrings("saves", r.save_dir.?);
    const o = r.options();
    try testing.expectEqual(3, o.len);
    try testing.expectEqualStrings("a", o[0].key);
    try testing.expectEqualStrings("1", o[0].value);
    try testing.expectEqualStrings("b", o[1].key);
    try testing.expectEqualStrings("x=y", o[1].value);
    try testing.expectEqualStrings("c", o[2].key);
    try testing.expectEqualStrings("", o[2].value);
}

test "run: usage errors" {
    try expectErr(&.{ "run", "--core", "c", "--rom", "g", "--frames", "1" }, .headless_required, "run");
    try expectErr(&.{ "run", "--headless", "--rom", "g", "--frames", "1" }, .missing_required, "--core");
    try expectErr(&.{ "run", "--headless", "--core", "c", "--frames", "1" }, .missing_required, "--rom");
    try expectErr(&.{ "run", "--headless", "--core", "c", "--rom", "g" }, .missing_required, "--frames");
    try expectErr(&.{ "run", "--headless", "--core" }, .missing_value, "--core");
    try expectErr(&.{ "run", "--headless", "--core=" }, .missing_value, "--core");
    try expectErr(&.{ "--core", "c" }, .run_only, "--core");
    try expectErr(&.{"--headless"}, .run_only, "--headless");
    try expectErr(&.{ "run", "run" }, .unexpected_argument, "run");
    try expectErr(&.{ "run", "--bogus" }, .unknown_option, "--bogus");
}

test "run: N and K must be positive integers" {
    for ([_][:0]const u8{ "0", "abc", "-5", "+5", "1_000", " 5", "1.5", "99999999999999999999999" }) |bad| {
        var args = base_run;
        args[7] = bad;
        const r = parse(&args);
        try testing.expect(r == .err);
        try testing.expectEqual(Error.Kind.invalid_number, r.err.kind);
        try testing.expectEqualStrings("--frames", r.err.arg);
        try testing.expectEqualStrings(bad, r.err.value);
    }
    var args: [10][:0]const u8 = undefined;
    @memcpy(args[0..8], &base_run);
    args[8] = "--dump-every";
    args[9] = "0";
    try expectErr(&args, .invalid_number, "--dump-every");
}

test "run: malformed and too many --option" {
    var args: [10][:0]const u8 = undefined;
    @memcpy(args[0..8], &base_run);
    args[8] = "--option";
    for ([_][:0]const u8{ "novalue", "=v" }) |bad| {
        args[9] = bad;
        try expectErr(&args, .malformed_option, "--option");
    }

    var many: [8 + 2 * (max_core_options + 1)][:0]const u8 = undefined;
    @memcpy(many[0..8], &base_run);
    for (0..max_core_options + 1) |k| {
        many[8 + 2 * k] = "--option";
        many[9 + 2 * k] = "k=v";
    }
    // Exactly the maximum is fine; one more is an error.
    try testing.expectEqual(max_core_options, (try expectRun(many[0 .. many.len - 2])).option_len);
    try expectErr(&many, .too_many_options, "--option");
}

test "run: help wins" {
    try expectOk(&.{ "run", "--help" }, .{ .command = .help });
    try expectOk(&.{ "run", "--core", "c", "--help" }, .{ .command = .help });
}

test "run error messages" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try (Error{ .kind = .invalid_number, .arg = "--frames", .value = "0" }).write(&w);
    try testing.expectEqualStrings(
        "temui: option '--frames' needs a positive integer, got '0'\nTry 'temui --help' for more information.\n",
        w.buffered(),
    );
}
