//! Command-line parsing. Pure: no process state, no I/O except `usage`.

const std = @import("std");
const env = @import("libretro/env.zig");
const Backend = @import("term/caps.zig").Backend;
pub const Speed = @import("play/Pacer.zig").Speed;

pub const Command = enum { none, help, version, run, detect, play };

/// At most this many `--option` flags; parsing stays allocation-free.
pub const max_core_options = 64;

pub const Options = struct {
    command: Command = .none,
    verbose: bool = false,
    log_file: ?[]const u8 = null,
    /// `--renderer`; null is `auto`. Valid with `detect` and `play`.
    renderer: ?Backend = null,
    /// `detect --json`.
    json: bool = false,
    /// Set when `command == .run`.
    run: Run = .{},
    /// Set when `command == .play`.
    play: Play = .{},
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

/// `temui play <rom> --core <path> ...`. `core` and `rom` are always set once
/// parsing succeeds with `command == .play`.
pub const Play = struct {
    core: []const u8 = "",
    rom: []const u8 = "",
    speed: Speed = .normal,
    /// `--present-fps`; null is the core's fps.
    present_fps: ?f64 = null,
    overlay: bool = false,
    paused: bool = false,
    /// `--duration`, in seconds of wall time.
    duration_s: ?f64 = null,
    system_dir: ?[]const u8 = null,
    save_dir: ?[]const u8 = null,
    option_buf: [max_core_options]env.Override = undefined,
    option_len: usize = 0,

    /// The `--option` overrides in command-line order. Points into `self`, so
    /// take it from a `Play` that stays put.
    pub fn options(self: *const Play) []const env.Override {
        return self.option_buf[0..self.option_len];
    }
};

/// The range `--speed`, `--present-fps` and `--duration` take. Both ends
/// keep later conversions to nanoseconds far from overflow: a frame period
/// at the smallest speed or present rate is still well inside an i96.
pub const min_number: f64 = 0.001;
pub const max_number: f64 = 1_000_000;

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
        /// `arg` is a run option given without `run` (or, for the options
        /// `run` shares with `play`, without either).
        run_only,
        /// `arg` is a detect option given without `detect` (or, for
        /// `--renderer`, without `detect` or `play`).
        detect_only,
        /// `arg` is a play option given without `play`.
        play_only,
        /// `arg`'s `value` is not one of the allowed choices.
        invalid_choice,
        /// `run` without `--headless`.
        headless_required,
        /// `arg` is a required option of the command (`value`) that is missing.
        missing_required,
        /// `arg`'s `value` is not a positive integer.
        invalid_number,
        /// `--speed`'s `value` is not a positive number or `max`.
        invalid_speed,
        /// `arg`'s `value` is not a positive number.
        invalid_positive,
        /// `--option`'s `value` is not `key=value` with a non-empty key.
        malformed_option,
        too_many_options,
    };

    pub fn write(e: Error, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (e.kind) {
            .unknown_option => try w.print("temui: unknown option '{s}'\n", .{e.arg}),
            .missing_value => try w.print("temui: option '{s}' requires a value\n", .{e.arg}),
            .unexpected_argument => try w.print("temui: unexpected argument '{s}'\n", .{e.arg}),
            .run_only, .detect_only, .play_only => try w.print("temui: option '{s}' is only valid with {s}\n", .{ e.arg, validWith(e.arg) }),
            .invalid_choice => try w.print("temui: option '{s}' needs one of kitty, halfblock, ascii, auto; got '{s}'\n", .{ e.arg, e.value }),
            .headless_required => try w.writeAll("temui: run requires --headless (interactive run arrives in a later item)\n"),
            .missing_required => try w.print("temui: {s} requires '{s}'\n", .{ e.value, e.arg }),
            .invalid_number => try w.print("temui: option '{s}' needs a positive integer, got '{s}'\n", .{ e.arg, e.value }),
            .invalid_speed => try w.print("temui: option '{s}' needs a number from {d} to {d} or 'max', got '{s}'\n", .{ e.arg, min_number, max_number, e.value }),
            .invalid_positive => try w.print("temui: option '{s}' needs a number from {d} to {d}, got '{s}'\n", .{ e.arg, min_number, max_number, e.value }),
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
const Valued = enum { log_file, renderer, core, rom, frames, dump_ppm, dump_every, option, system_dir, save_dir, speed, present_fps, duration };

fn valuedName(v: Valued) []const u8 {
    return switch (v) {
        .log_file => "--log-file",
        .renderer => "--renderer",
        .core => "--core",
        .rom => "--rom",
        .frames => "--frames",
        .dump_ppm => "--dump-ppm",
        .dump_every => "--dump-every",
        .option => "--option",
        .system_dir => "--system-dir",
        .save_dir => "--save-dir",
        .speed => "--speed",
        .present_fps => "--present-fps",
        .duration => "--duration",
    };
}

/// Which commands a command-specific option is valid with.
const Where = enum {
    run,
    play,
    run_play,
    detect,
    detect_play,

    fn allows(w: Where, c: Command) bool {
        return switch (w) {
            .run => c == .run,
            .play => c == .play,
            .run_play => c == .run or c == .play,
            .detect => c == .detect,
            .detect_play => c == .detect or c == .play,
        };
    }

    /// The error for using an option of this kind with the wrong command.
    fn misplaced(w: Where) Error.Kind {
        return switch (w) {
            .run, .run_play => .run_only,
            .play => .play_only,
            .detect, .detect_play => .detect_only,
        };
    }
};

/// Null for global options (and unknown names).
fn whereOf(name: []const u8) ?Where {
    const table = [_]struct { []const u8, Where }{
        .{ "--headless", .run },         .{ "--rom", .run },             .{ "--frames", .run },
        .{ "--dump-ppm", .run },         .{ "--dump-every", .run },      .{ "--core", .run_play },
        .{ "--option", .run_play },      .{ "--system-dir", .run_play }, .{ "--save-dir", .run_play },
        .{ "--speed", .play },           .{ "--present-fps", .play },    .{ "--duration", .play },
        .{ "--overlay", .play },         .{ "--paused", .play },         .{ "--json", .detect },
        .{ "--renderer", .detect_play },
    };
    for (table) |e| if (eql(e[0], name)) return e[1];
    return null;
}

/// The commands `name` is valid with, for error messages.
fn validWith(name: []const u8) []const u8 {
    return switch (whereOf(name) orelse return "another command") {
        .run => "'run'",
        .play => "'play'",
        .run_play => "'run' or 'play'",
        .detect => "'detect'",
        .detect_play => "'detect' or 'play'",
    };
}

/// Parses arguments, excluding the program name (argv[0]).
/// `--help` takes precedence over everything else, `--version` over commands.
pub fn parse(args: []const [:0]const u8) Result {
    var opts: Options = .{};
    // The command word (`run`, `detect`, `play`), wherever it appears.
    var cmd: Command = .none;
    var headless = false;
    var frames_set = false;
    // The first option of each kind and its position, so that once the
    // command is known the earliest misplaced one is reported.
    const Seen = struct { name: []const u8, pos: usize };
    var first: std.EnumArray(Where, ?Seen) = .initFill(null);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        const pos = i;
        if (eql(arg, "-h") or eql(arg, "--help")) {
            opts.command = .help;
        } else if (eql(arg, "-V") or eql(arg, "--version")) {
            if (opts.command != .help) opts.command = .version;
        } else if (eql(arg, "-v") or eql(arg, "--verbose")) {
            opts.verbose = true;
        } else if (eql(arg, "--headless")) {
            headless = true;
        } else if (eql(arg, "--json")) {
            opts.json = true;
        } else if (eql(arg, "--overlay")) {
            opts.play.overlay = true;
        } else if (eql(arg, "--paused")) {
            opts.play.paused = true;
        } else if (matchValued(arg)) |m| {
            const value = m.inline_value orelse blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            const name = valuedName(m.which);
            if (value.len == 0) return .{ .err = .{ .kind = .missing_value, .arg = name } };
            switch (m.which) {
                .log_file => opts.log_file = value,
                .renderer => opts.renderer = if (eql(value, "auto")) null else std.meta.stringToEnum(Backend, value) orelse
                    return .{ .err = .{ .kind = .invalid_choice, .arg = name, .value = value } },
                // Shared with `play`, which takes them from `opts.run` below.
                .core => opts.run.core = value,
                .system_dir => opts.run.system_dir = value,
                .save_dir => opts.run.save_dir = value,
                .rom => opts.run.rom = value,
                .dump_ppm => opts.run.dump_ppm = value,
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
                .speed => opts.play.speed = if (eql(value, "max")) .max else .{
                    .x = parsePositive(value) orelse return .{ .err = .{ .kind = .invalid_speed, .arg = name, .value = value } },
                },
                .present_fps, .duration => {
                    const x = parsePositive(value) orelse return .{ .err = .{ .kind = .invalid_positive, .arg = name, .value = value } };
                    if (m.which == .present_fps) opts.play.present_fps = x else opts.play.duration_s = x;
                },
            }
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .err = .{ .kind = .unknown_option, .arg = arg } };
        } else if (cmd == .none and (eql(arg, "run") or eql(arg, "detect") or eql(arg, "play"))) {
            cmd = std.meta.stringToEnum(Command, arg).?;
            continue;
        } else if (cmd == .play and opts.play.rom.len == 0) {
            opts.play.rom = arg;
            continue;
        } else {
            return .{ .err = .{ .kind = .unexpected_argument, .arg = arg } };
        }
        // Options only reach here; positionals `continue` above.
        const name = if (matchValued(arg)) |m| valuedName(m.which) else arg;
        if (whereOf(name)) |w| {
            if (first.get(w) == null) first.set(w, .{ .name = name, .pos = pos });
        }
    }

    if (opts.command != .none) return .{ .ok = opts };

    var misplaced: ?struct { Where, Seen } = null;
    for (std.enums.values(Where)) |w| {
        if (w.allows(cmd)) continue;
        const seen = first.get(w) orelse continue;
        if (misplaced == null or seen.pos < misplaced.?[1].pos) misplaced = .{ w, seen };
    }
    if (misplaced) |m| return .{ .err = .{ .kind = m[0].misplaced(), .arg = m[1].name } };

    switch (cmd) {
        .none => {},
        .detect => opts.command = .detect,
        .run => {
            if (!headless) return .{ .err = .{ .kind = .headless_required, .arg = "run" } };
            if (opts.run.core.len == 0) return missingRequired("--core", "run");
            if (opts.run.rom.len == 0) return missingRequired("--rom", "run");
            if (!frames_set) return missingRequired("--frames", "run");
            opts.command = .run;
        },
        .play => {
            if (opts.play.rom.len == 0) return missingRequired("<rom>", "play");
            if (opts.run.core.len == 0) return missingRequired("--core", "play");
            const p = &opts.play;
            p.core = opts.run.core;
            p.system_dir = opts.run.system_dir;
            p.save_dir = opts.run.save_dir;
            p.option_len = opts.run.option_len;
            @memcpy(p.option_buf[0..p.option_len], opts.run.options());
            opts.run = .{};
            opts.command = .play;
        },
        .help, .version => unreachable,
    }
    return .{ .ok = opts };
}

fn missingRequired(arg: []const u8, command: []const u8) Result {
    return .{ .err = .{ .kind = .missing_required, .arg = arg, .value = command } };
}

/// A decimal number from `min_number` to `max_number`: digits with at most
/// one '.', so no signs, exponents, `inf` or `nan`.
fn parsePositive(value: []const u8) ?f64 {
    var dots: usize = 0;
    var digits: usize = 0;
    for (value) |ch| {
        if (ch == '.') dots += 1 else if (std.ascii.isDigit(ch)) digits += 1 else return null;
    }
    if (dots > 1 or digits == 0) return null;
    const x = std.fmt.parseFloat(f64, value) catch return null;
    if (!(x >= min_number) or x > max_number) return null;
    return x;
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
        \\       temui play <rom> --core <path> [play options]
        \\       temui run --headless --core <path> --rom <path> --frames <N> [run options]
        \\       temui detect [--json] [--renderer <name>]
        \\
        \\Options:
        \\  -h, --help              Show this help and exit
        \\  -V, --version           Show the version and exit
        \\  -v, --verbose           Log at debug level
        \\      --log-file <path>   Log to <path> instead of the log directory
        \\      --renderer <name>   kitty, halfblock, ascii or auto (default); 'play' and 'detect'
        \\
        \\Play options (run a game in this terminal):
        \\      --core <path>       The libretro core to load
        \\      --speed <x>         Starting speed: a multiple such as 0.25 or 4, or max (default 1)
        \\      --present-fps <f>   Draw at most <f> frames per second (default: the core's fps)
        \\      --overlay           Start with the stats overlay shown
        \\      --paused            Start paused, showing the first frame
        \\      --duration <s>      Quit after <s> seconds
        \\      --option, --system-dir, --save-dir   As for 'run'
        \\
        \\Play keys (temporary, until modes arrive):
        \\  q, Ctrl-C   Quit                 p   Pause / resume
        \\  .           Step one frame       o   Show / hide the overlay
        \\  + or =      Faster               -   Slower
        \\  0           Normal speed
        \\
        \\Detect options (show what temui would use in this terminal):
        \\      --json              Print the result as JSON
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
    var buf: [4096]u8 = undefined;
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

test "detect: command, --json and --renderer" {
    try expectOk(&.{"detect"}, .{ .command = .detect });
    const r = parse(&.{ "--renderer", "halfblock", "detect", "--json" });
    try testing.expect(r == .ok);
    try testing.expectEqual(Command.detect, r.ok.command);
    try testing.expect(r.ok.json);
    try testing.expectEqual(@as(?Backend, .halfblock), r.ok.renderer);
    for ([_]struct { [:0]const u8, ?Backend }{ .{ "kitty", .kitty }, .{ "ascii", .ascii }, .{ "auto", null } }) |c| {
        var buf: [32]u8 = undefined;
        const arg = try std.fmt.bufPrintSentinel(&buf, "--renderer={s}", .{c[0]}, 0);
        const rr = parse(&.{ "detect", arg });
        try testing.expectEqual(c[1], rr.ok.renderer);
    }
    try expectOk(&.{ "detect", "--help" }, .{ .command = .help });
}

test "detect: usage errors" {
    try expectErr(&.{ "--renderer", "kitty" }, .detect_only, "--renderer");
    try expectErr(&.{"--json"}, .detect_only, "--json");
    try expectErr(&.{ "run", "--headless", "--core", "c", "--rom", "g", "--frames", "1", "--renderer", "ascii" }, .detect_only, "--renderer");
    try expectErr(&.{ "detect", "--renderer", "sixel" }, .invalid_choice, "--renderer");
    try expectErr(&.{ "detect", "--renderer" }, .missing_value, "--renderer");
    try expectErr(&.{ "detect", "--core", "c" }, .run_only, "--core");
    try expectErr(&.{ "detect", "run" }, .unexpected_argument, "run");
    try expectErr(&.{ "run", "detect" }, .unexpected_argument, "detect");
    try expectErr(&.{ "detect", "detect" }, .unexpected_argument, "detect");
}

fn expectPlay(args: []const [:0]const u8) !Options {
    const r = parse(args);
    if (r == .err) {
        std.debug.print("unexpected error: {t} {s} {s}\n", .{ r.err.kind, r.err.arg, r.err.value });
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(Command.play, r.ok.command);
    return r.ok;
}

test "play: required arguments and defaults" {
    const o = try expectPlay(&.{ "play", "g.sfc", "--core", "c.so" });
    const p = o.play;
    try testing.expectEqualStrings("c.so", p.core);
    try testing.expectEqualStrings("g.sfc", p.rom);
    try testing.expect(p.speed.eql(.normal));
    try testing.expectEqual(null, p.present_fps);
    try testing.expect(!p.overlay);
    try testing.expect(!p.paused);
    try testing.expectEqual(null, p.duration_s);
    try testing.expectEqual(null, p.system_dir);
    try testing.expectEqual(null, p.save_dir);
    try testing.expectEqual(0, p.options().len);
    try testing.expectEqual(null, o.renderer);
    // The ROM may come anywhere after `play`.
    const o2 = try expectPlay(&.{ "--core=c.so", "play", "--overlay", "g.sfc" });
    try testing.expectEqualStrings("g.sfc", o2.play.rom);
}

test "play: every option, both value forms" {
    const o = try expectPlay(&.{
        "play",         "--core",           "c.dylib",    "--speed",
        "0.25",         "--present-fps=30", "--overlay",  "--paused",
        "--duration",   "1.5",              "--option",   "a=1",
        "--option=b=2", "--system-dir=sys", "--save-dir", "saves",
        "--renderer",   "halfblock",        "-v",         "g.gb",
    });
    const p = o.play;
    try testing.expectEqualStrings("c.dylib", p.core);
    try testing.expectEqualStrings("g.gb", p.rom);
    try testing.expect(p.speed.eql(.{ .x = 0.25 }));
    try testing.expectEqual(30, p.present_fps.?);
    try testing.expect(p.overlay);
    try testing.expect(p.paused);
    try testing.expectEqual(1.5, p.duration_s.?);
    try testing.expectEqualStrings("sys", p.system_dir.?);
    try testing.expectEqualStrings("saves", p.save_dir.?);
    try testing.expectEqual(2, p.options().len);
    try testing.expectEqualStrings("a", p.options()[0].key);
    try testing.expectEqualStrings("2", p.options()[1].value);
    try testing.expectEqual(@as(?Backend, .halfblock), o.renderer);
    try testing.expect(o.verbose);

    const o2 = try expectPlay(&.{ "play", "g", "--core", "c", "--speed=max", "--present-fps", "0.2", "--duration=300", "--renderer=auto" });
    try testing.expect(o2.play.speed.eql(.max));
    try testing.expectEqual(0.2, o2.play.present_fps.?);
    try testing.expectEqual(300, o2.play.duration_s.?);
    try testing.expectEqual(null, o2.renderer);
    try testing.expect((try expectPlay(&.{ "play", "g", "--core", "c", "--speed", "4" })).play.speed.eql(.{ .x = 4 }));
}

test "play: number validation" {
    for ([_][:0]const u8{ "--speed", "--present-fps", "--duration" }) |opt| {
        for ([_][:0]const u8{ "0", "0.0", "-1", "+1", "abc", "1e3", "inf", "nan", ".", "1.2.3", " 1", "1_0", "1000001", "0.0009", "0.000000000000000000000001" }) |bad| {
            const r = parse(&.{ "play", "g", "--core", "c", opt, bad });
            try testing.expect(r == .err);
            const want: Error.Kind = if (eql(opt, "--speed")) .invalid_speed else .invalid_positive;
            try testing.expectEqual(want, r.err.kind);
            try testing.expectEqualStrings(opt, r.err.arg);
            try testing.expectEqualStrings(bad, r.err.value);
        }
        for ([_][:0]const u8{ ".5", "5.", "1000000", "0.001" }) |good| {
            _ = try expectPlay(&.{ "play", "g", "--core", "c", opt, good });
        }
    }
    try expectErr(&.{ "play", "g", "--core", "c", "--present-fps", "max" }, .invalid_positive, "--present-fps");
    try expectErr(&.{ "play", "g", "--core", "c", "--speed" }, .missing_value, "--speed");
}

test "play: usage errors" {
    try expectErr(&.{ "play", "--core", "c" }, .missing_required, "<rom>");
    try expectErr(&.{ "play", "g" }, .missing_required, "--core");
    try expectErr(&.{"play"}, .missing_required, "<rom>");
    try expectErr(&.{ "play", "g", "h", "--core", "c" }, .unexpected_argument, "h");
    try expectErr(&.{ "play", "g", "--core", "c", "--rom", "x" }, .run_only, "--rom");
    try expectErr(&.{ "play", "g", "--core", "c", "--headless" }, .run_only, "--headless");
    try expectErr(&.{ "play", "g", "--core", "c", "--frames", "1" }, .run_only, "--frames");
    try expectErr(&.{ "play", "g", "--core", "c", "--json" }, .detect_only, "--json");
    try expectErr(&.{ "run", "play" }, .unexpected_argument, "play");
    try expectErr(&.{ "detect", "play" }, .unexpected_argument, "play");
    // Play options without `play`.
    for ([_][:0]const u8{ "--overlay", "--paused" }) |flag| {
        try expectErr(&.{flag}, .play_only, flag);
        try expectErr(&.{ "detect", flag }, .play_only, flag);
    }
    try expectErr(&.{ "--speed", "2" }, .play_only, "--speed");
    try expectErr(&.{ "run", "--headless", "--core", "c", "--rom", "g", "--frames", "1", "--duration=5" }, .play_only, "--duration");
    // The earliest misplaced option is the one reported.
    try expectErr(&.{ "detect", "--paused", "--core", "c" }, .play_only, "--paused");
    try expectErr(&.{ "detect", "--core", "c", "--paused" }, .run_only, "--core");
    try expectOk(&.{ "play", "--help" }, .{ .command = .help });
    try expectOk(&.{ "play", "g", "--version" }, .{ .command = .version });
}

test "play: error messages" {
    const cases = [_]struct { Error, []const u8 }{
        .{ .{ .kind = .missing_required, .arg = "<rom>", .value = "play" }, "temui: play requires '<rom>'\n" },
        .{ .{ .kind = .missing_required, .arg = "--core", .value = "run" }, "temui: run requires '--core'\n" },
        .{ .{ .kind = .play_only, .arg = "--overlay" }, "temui: option '--overlay' is only valid with 'play'\n" },
        .{ .{ .kind = .run_only, .arg = "--core" }, "temui: option '--core' is only valid with 'run' or 'play'\n" },
        .{ .{ .kind = .run_only, .arg = "--frames" }, "temui: option '--frames' is only valid with 'run'\n" },
        .{ .{ .kind = .detect_only, .arg = "--renderer" }, "temui: option '--renderer' is only valid with 'detect' or 'play'\n" },
        .{ .{ .kind = .detect_only, .arg = "--json" }, "temui: option '--json' is only valid with 'detect'\n" },
        .{ .{ .kind = .invalid_speed, .arg = "--speed", .value = "0" }, "temui: option '--speed' needs a number from 0.001 to 1000000 or 'max', got '0'\n" },
        .{ .{ .kind = .invalid_positive, .arg = "--duration", .value = "x" }, "temui: option '--duration' needs a number from 0.001 to 1000000, got 'x'\n" },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try c[0].write(&w);
        const out = w.buffered();
        try testing.expectEqualStrings(c[1], out[0 .. std.mem.indexOfScalar(u8, out, '\n').? + 1]);
    }
}

test "usage documents play" {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try usage(&w, "/logs");
    for ([_][]const u8{ "temui play <rom> --core <path>", "--speed <x>", "--present-fps <f>", "--overlay", "--paused", "--duration <s>", "Play keys (temporary" }) |want| {
        if (std.mem.indexOf(u8, w.buffered(), want) == null) {
            std.debug.print("usage lacks '{s}'\n", .{want});
            return error.TestUnexpectedResult;
        }
    }
}
