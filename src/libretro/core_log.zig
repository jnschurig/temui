//! Core log routing. Cores log through a variadic C callback; `core_log.c`
//! formats each message and calls `temui_core_log_sink`, which forwards it to
//! `sink` (the file log under the `core` scope by default).

const std = @import("std");

/// The function to hand to cores in `retro_log_callback.log`
/// (`retro_log_printf_t`). Defined in `core_log.c`.
pub extern fn temui_core_log(level: c_int, fmt: ?[*:0]const u8, ...) callconv(.c) void;

pub const Sink = *const fn (level: std.log.Level, msg: []const u8) void;

/// Where formatted core messages go. Tests swap this to capture them.
pub var sink: Sink = &toFileLog;

/// Maps a `retro_log_level` (DEBUG=0, INFO=1, WARN=2, ERROR=3) to a std level.
/// Out-of-range values are logged as warnings rather than dropped.
pub fn mapLevel(level: c_int) std.log.Level {
    return switch (level) {
        0 => .debug,
        1 => .info,
        2 => .warn,
        3 => .err,
        else => .warn,
    };
}

export fn temui_core_log_sink(level: c_int, msg: [*]const u8, len: usize) callconv(.c) void {
    sink(mapLevel(level), msg[0..len]);
}

fn toFileLog(level: std.log.Level, msg: []const u8) void {
    const log = std.log.scoped(.core);
    switch (level) {
        .debug => log.debug("{s}", .{msg}),
        .info => log.info("{s}", .{msg}),
        .warn => log.warn("{s}", .{msg}),
        .err => log.err("{s}", .{msg}),
    }
}

const testing = std.testing;

const Capture = struct {
    var buf: [2048]u8 = undefined;
    var len: usize = 0;
    var level: std.log.Level = .debug;
    var calls: usize = 0;

    fn record(l: std.log.Level, msg: []const u8) void {
        @memcpy(buf[0..msg.len], msg);
        len = msg.len;
        level = l;
        calls += 1;
    }

    fn text() []const u8 {
        return buf[0..len];
    }
};

fn withCapture() Sink {
    const prev = sink;
    sink = &Capture.record;
    Capture.calls = 0;
    return prev;
}

/// Calls the C shim through the callback type cores use.
const LogFn = *const fn (c_int, ?[*:0]const u8, ...) callconv(.c) void;
const logp: LogFn = &temui_core_log;

test "formats integers, strings, chars and percent" {
    const prev = withCapture();
    defer sink = prev;
    logp(1, "%d %u %x %X %s %c %%", @as(c_int, -42), @as(c_uint, 7), @as(c_uint, 255), @as(c_uint, 0xab), @as([*:0]const u8, "snes9x"), @as(c_int, 'Z'));
    try testing.expectEqualStrings("-42 7 ff AB snes9x Z %", Capture.text());
    try testing.expectEqual(std.log.Level.info, Capture.level);
}

test "formats 64-bit and size_t" {
    const prev = withCapture();
    defer sink = prev;
    logp(0, "%lld %llu %zu", @as(c_longlong, -1234567890123), @as(c_ulonglong, 18446744073709551615), @as(usize, 4096));
    try testing.expectEqualStrings("-1234567890123 18446744073709551615 4096", Capture.text());
}

test "formats floats, width and precision" {
    const prev = withCapture();
    defer sink = prev;
    logp(0, "[%.3f] [%5d] [%-4s] [%08x] [%.2s]", @as(f64, 60.0988), @as(c_int, 42), @as([*:0]const u8, "ab"), @as(c_uint, 0xbeef), @as([*:0]const u8, "xyz"));
    try testing.expectEqualStrings("[60.099] [   42] [ab  ] [0000beef] [xy]", Capture.text());
}

test "strips one trailing newline" {
    const prev = withCapture();
    defer sink = prev;
    logp(2, "loaded %s\n", @as([*:0]const u8, "rom"));
    try testing.expectEqualStrings("loaded rom", Capture.text());
    logp(2, "crlf\r\n");
    try testing.expectEqualStrings("crlf", Capture.text());
    logp(2, "two\n\n");
    try testing.expectEqualStrings("two\n", Capture.text());
}

test "truncates long messages with an ellipsis" {
    const prev = withCapture();
    defer sink = prev;
    const long: [1500:0]u8 = @splat('x');
    logp(3, "%s", @as([*:0]const u8, &long));
    const t = Capture.text();
    try testing.expectEqual(@as(usize, 1023), t.len);
    try testing.expect(std.mem.endsWith(u8, t, "x\u{2026}"));
    try testing.expectEqual(std.log.Level.err, Capture.level);
}

test "null format" {
    const prev = withCapture();
    defer sink = prev;
    logp(1, null);
    try testing.expectEqualStrings("(null format)", Capture.text());
}

test "level mapping" {
    try testing.expectEqual(std.log.Level.debug, mapLevel(0));
    try testing.expectEqual(std.log.Level.info, mapLevel(1));
    try testing.expectEqual(std.log.Level.warn, mapLevel(2));
    try testing.expectEqual(std.log.Level.err, mapLevel(3));
    try testing.expectEqual(std.log.Level.warn, mapLevel(99));
    try testing.expectEqual(std.log.Level.warn, mapLevel(-1));
}
