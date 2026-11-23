//! Command-line parsing. Pure: no process state, no I/O except `usage`.

const std = @import("std");

pub const Command = enum { none, help, version };

pub const Options = struct {
    command: Command = .none,
    verbose: bool = false,
    log_file: ?[]const u8 = null,
};

pub const Error = struct {
    kind: Kind,
    /// The offending argument, as given.
    arg: []const u8,

    pub const Kind = enum { unknown_option, missing_value, unexpected_argument };

    pub fn write(e: Error, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (e.kind) {
            .unknown_option => try w.print("temui: unknown option '{s}'\n", .{e.arg}),
            .missing_value => try w.print("temui: option '{s}' requires a value\n", .{e.arg}),
            .unexpected_argument => try w.print("temui: unexpected argument '{s}'\n", .{e.arg}),
        }
        try w.writeAll("Try 'temui --help' for more information.\n");
    }
};

pub const Result = union(enum) {
    ok: Options,
    err: Error,
};

/// Parses arguments, excluding the program name (argv[0]).
/// `--help` takes precedence over `--version` when both are given.
pub fn parse(args: []const [:0]const u8) Result {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (eql(arg, "-h") or eql(arg, "--help")) {
            opts.command = .help;
        } else if (eql(arg, "-V") or eql(arg, "--version")) {
            if (opts.command != .help) opts.command = .version;
        } else if (eql(arg, "-v") or eql(arg, "--verbose")) {
            opts.verbose = true;
        } else if (eql(arg, "--log-file")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return .{ .err = .{ .kind = .missing_value, .arg = arg } };
            opts.log_file = args[i];
        } else if (std.mem.startsWith(u8, arg, "--log-file=")) {
            const value = arg["--log-file=".len..];
            if (value.len == 0) return .{ .err = .{ .kind = .missing_value, .arg = "--log-file" } };
            opts.log_file = value;
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .err = .{ .kind = .unknown_option, .arg = arg } };
        } else {
            return .{ .err = .{ .kind = .unexpected_argument, .arg = arg } };
        }
    }
    return .{ .ok = opts };
}

pub fn usage(w: *std.Io.Writer, log_dir: []const u8) std.Io.Writer.Error!void {
    try w.print(
        \\temui — a terminal libretro frontend
        \\
        \\Usage: temui [options]
        \\
        \\Options:
        \\  -h, --help             Show this help and exit
        \\  -V, --version          Show the version and exit
        \\  -v, --verbose          Log at debug level
        \\      --log-file <path>  Log to <path> instead of the log directory
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
