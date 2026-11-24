//! termbench command-line parsing. Pure: no I/O except `usage`.

const std = @import("std");

pub const Command = enum { run, detect, procs, help };

pub const Res = enum {
    @"256x224",
    @"320x240",

    pub fn width(r: Res) u32 {
        return switch (r) {
            .@"256x224" => 256,
            .@"320x240" => 320,
        };
    }
    pub fn height(r: Res) u32 {
        return switch (r) {
            .@"256x224" => 224,
            .@"320x240" => 240,
        };
    }
};

pub const Scene = enum { scroll, sprites };

pub const Transport = enum {
    @"inline-rgb",
    @"inline-rgba",
    @"inline-zlib",
    file,
    shm,
    @"half-full",
    @"half-diff",

    pub fn isHalfBlock(t: Transport) bool {
        return t == .@"half-full" or t == .@"half-diff";
    }
};

pub fn Set(comptime E: type) type {
    return std.EnumSet(E);
}

pub const Options = struct {
    command: Command = .run,
    duration_s: f64 = 10,
    res: Set(Res) = .full,
    scene: Set(Scene) = .full,
    transport: Set(Transport) = .full,
    /// 0 = unpaced.
    fps: f64 = 0,
    max_inflight: u32 = 8,
    ack_timeout_s: f64 = 1,
    overlay: bool = true,
    double_buffer: bool = false,
    term_pids: [16]i32 = undefined,
    term_pid_count: usize = 0,
    out: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    verbose: bool = false,
};

pub const Error = struct {
    msg: []const u8,
    arg: []const u8,

    pub fn write(e: Error, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("termbench: {s}: '{s}'\nTry 'termbench --help'.\n", .{ e.msg, e.arg });
    }
};

pub const Result = union(enum) {
    ok: Options,
    err: Error,
};

pub fn parse(args: []const [:0]const u8) Result {
    var o: Options = .{};
    var i: usize = 0;
    var first = true;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        defer first = false;
        if (first and eql(arg, "run")) {
            o.command = .run;
            continue;
        }
        if (first and eql(arg, "detect")) {
            o.command = .detect;
            continue;
        }
        if (first and eql(arg, "procs")) {
            o.command = .procs;
            continue;
        }
        if (eql(arg, "-h") or eql(arg, "--help")) {
            o.command = .help;
            continue;
        }
        if (eql(arg, "-v") or eql(arg, "--verbose")) {
            o.verbose = true;
            continue;
        }
        if (eql(arg, "--no-overlay")) {
            o.overlay = false;
            continue;
        }
        if (eql(arg, "--double-buffer")) {
            o.double_buffer = true;
            continue;
        }
        // Options with a value: `--name value` or `--name=value`.
        var name = arg;
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            name = arg[0..eq];
            value = arg[eq + 1 ..];
        }
        const valued = [_][]const u8{ "--duration", "--res", "--scene", "--transport", "--fps", "--max-inflight", "--ack-timeout", "--term-pid", "--out", "--log-file" };
        var known = false;
        for (valued) |v| known = known or eql(name, v);
        if (!known) return .{ .err = .{ .msg = "unknown argument", .arg = arg } };
        if (value == null) {
            i += 1;
            if (i >= args.len) return .{ .err = .{ .msg = "option requires a value", .arg = arg } };
            value = args[i];
        }
        const v = value.?;
        if (v.len == 0) return .{ .err = .{ .msg = "option requires a value", .arg = name } };
        const bad: Result = .{ .err = .{ .msg = "invalid value", .arg = v } };
        if (eql(name, "--duration")) {
            o.duration_s = std.fmt.parseFloat(f64, v) catch return bad;
            if (!(o.duration_s > 0 and o.duration_s <= 1e6)) return bad;
        } else if (eql(name, "--fps")) {
            o.fps = std.fmt.parseFloat(f64, v) catch return bad;
            if (!(o.fps == 0 or (o.fps >= 1e-3 and o.fps <= 1e6))) return bad;
        } else if (eql(name, "--ack-timeout")) {
            o.ack_timeout_s = std.fmt.parseFloat(f64, v) catch return bad;
            if (!(o.ack_timeout_s > 0 and o.ack_timeout_s <= 1e6)) return bad;
        } else if (eql(name, "--max-inflight")) {
            o.max_inflight = std.fmt.parseInt(u32, v, 10) catch return bad;
            if (o.max_inflight == 0) return bad;
        } else if (eql(name, "--term-pid")) {
            if (o.term_pid_count == o.term_pids.len) return bad;
            o.term_pids[o.term_pid_count] = std.fmt.parseInt(i32, v, 10) catch return bad;
            o.term_pid_count += 1;
        } else if (eql(name, "--out")) {
            o.out = v;
        } else if (eql(name, "--log-file")) {
            o.log_file = v;
        } else if (eql(name, "--res")) {
            o.res = parseSet(Res, v) orelse return bad;
        } else if (eql(name, "--scene")) {
            o.scene = parseSet(Scene, v) orelse return bad;
        } else if (eql(name, "--transport")) {
            o.transport = parseSet(Transport, v) orelse return bad;
        }
    }
    return .{ .ok = o };
}

/// Comma-separated enum names, e.g. "shm,half-diff".
fn parseSet(comptime E: type, v: []const u8) ?Set(E) {
    var s: Set(E) = .empty;
    var it = std.mem.splitScalar(u8, v, ',');
    while (it.next()) |name| s.insert(std.meta.stringToEnum(E, name) orelse return null);
    return s;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\termbench — terminal graphics throughput spike (roadmap item 02)
        \\
        \\Usage:
        \\  termbench [run] [options]   run the benchmark matrix in this terminal
        \\  termbench detect [options]  probe terminal capabilities
        \\  termbench procs [options]   show the terminal processes CPU is sampled from
        \\
        \\Options:
        \\  --duration S        seconds per cell (default 10)
        \\  --res LIST          256x224,320x240
        \\  --scene LIST        scroll,sprites
        \\  --transport LIST    inline-rgb,inline-rgba,inline-zlib,file,shm,half-full,half-diff
        \\  --fps N             cap frame rate (default 0 = unpaced)
        \\  --max-inflight N    unacknowledged frames before blocking (default 8)
        \\  --ack-timeout S     fail a cell after S seconds without an ack (default 1)
        \\  --no-overlay        no live status bar
        \\  --double-buffer     alternate two kitty image ids
        \\  --term-pid PID      terminal process to sample (repeatable; default: auto)
        \\  --out PATH          results file (default ./termbench-<terminal>-<time>.jsonl)
        \\  --log-file PATH     log to PATH instead of the temui log directory
        \\  -v, --verbose       debug logging
        \\  -h, --help          this help
        \\
        \\Photosensitivity warning: the default matrix can flash rapidly (single-id kitty
        \\frames flickered in Ghostty 1.4.0). Use --double-buffer, --fps 60, or a small window.
        \\
    );
}

test "defaults run the full matrix unpaced" {
    const o = parse(&.{}).ok;
    try std.testing.expectEqual(Command.run, o.command);
    try std.testing.expectEqual(@as(usize, 7), o.transport.count());
    try std.testing.expectEqual(@as(usize, 2), o.res.count());
    try std.testing.expectEqual(@as(f64, 0), o.fps);
}

test "subsets, values and errors" {
    const o = parse(&.{ "detect", "--transport=shm,half-diff", "--duration", "2.5", "--term-pid", "42", "--term-pid=7" }).ok;
    try std.testing.expectEqual(Command.detect, o.command);
    try std.testing.expect(o.transport.contains(.shm) and o.transport.contains(.@"half-diff"));
    try std.testing.expectEqual(@as(usize, 2), o.transport.count());
    try std.testing.expectEqual(@as(f64, 2.5), o.duration_s);
    try std.testing.expectEqualSlices(i32, &.{ 42, 7 }, o.term_pids[0..o.term_pid_count]);
    try std.testing.expect(parse(&.{"--transport=bogus"}) == .err);
    try std.testing.expect(parse(&.{"--fps"}) == .err);
    try std.testing.expect(parse(&.{"--nope"}) == .err);
    try std.testing.expect(parse(&.{ "run", "detect" }) == .err);
}
