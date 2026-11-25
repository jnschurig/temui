//! The stats overlay's text (D13): one line, e.g.
//! `emu 60.0 · pres 60.0 · 1× · 2.1 MB/s · enc 1.2 ms/s · wr 3.0 ms/s · lag 2`.
//! `enc` is the time spent encoding frames and `wr` the time spent writing
//! them, both per second of wall time.
//! Drawing it is the viewer's job; this only builds the string.

const std = @import("std");
const Pacer = @import("Pacer.zig");
const Stats = @import("Stats.zig");

pub const State = struct {
    rates: Stats.Rates,
    speed: Pacer.Speed,
    paused: bool,
    /// Schedule re-bases so far; the lag part shows only when > 0.
    rebases: u64,
};

/// Large enough for any line `format` builds before truncation.
pub const max_len = 192;

/// Builds the line in `buf` and returns it, cut to at most `max_cols`
/// cells. Every character in it is one cell wide.
pub fn format(buf: *[max_len]u8, st: State, max_cols: usize) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, st) catch unreachable; // max_len fits the longest line
    return truncate(w.buffered(), max_cols);
}

fn write(w: *std.Io.Writer, st: State) std.Io.Writer.Error!void {
    const sep = " · ";
    try w.print("emu {d:.1}" ++ sep ++ "pres {d:.1}" ++ sep, .{
        clampRate(st.rates.emulated_fps), clampRate(st.rates.presented_fps),
    });
    try writeSpeed(w, st.speed, st.paused);
    try w.writeAll(sep);
    try writeBytes(w, st.rates.bytes_per_s);
    try w.writeAll(sep ++ "enc ");
    try writeMs(w, st.rates.encode_ns_per_s);
    try w.writeAll(sep ++ "wr ");
    try writeMs(w, st.rates.write_ns_per_s);
    if (st.rebases > 0) try w.print(sep ++ "lag {d}", .{st.rebases});
}

/// `0.4 ms/s`, `9.9 ms/s`, `12 ms/s`: one decimal below 10.
fn writeMs(w: *std.Io.Writer, ns_per_s: f64) !void {
    const v = ns_per_s / std.time.ns_per_ms;
    if (v < 9.95) try w.print("{d:.1}", .{v}) else try w.print("{d:.0}", .{@min(v, 9_999_999)});
    try w.writeAll(" ms/s");
}

/// Keeps absurd values from widening the line past `max_len`.
fn clampRate(v: f64) f64 {
    return @min(v, 9_999_999);
}

fn writeSpeed(w: *std.Io.Writer, speed: Pacer.Speed, paused: bool) !void {
    if (paused) return w.writeAll("paused");
    switch (speed) {
        .max => try w.writeAll("max"),
        .x => |x| {
            // Up to two decimals, trailing zeros dropped: 1×, 0.25×, 1.5×.
            var tmp: [32]u8 = undefined;
            var s: []const u8 = std.fmt.bufPrint(&tmp, "{d:.2}", .{clampRate(x)}) catch unreachable;
            s = std.mem.trimEnd(u8, s, "0");
            s = std.mem.trimEnd(u8, s, ".");
            try w.print("{s}×", .{s});
        },
    }
}

/// Decimal units: 512 B/s, 2.1 kB/s, 2.1 MB/s, 1.3 GB/s.
fn writeBytes(w: *std.Io.Writer, v: f64) !void {
    const units = [_][]const u8{ "B/s", "kB/s", "MB/s", "GB/s" };
    var x = v;
    var u: usize = 0;
    // Move up a unit when rounding would print 1000 (or 1000.0).
    while (x >= @as(f64, if (u == 0) 999.5 else 999.95) and u < units.len - 1) : (u += 1) x /= 1000;
    if (u == 0) return w.print("{d:.0} {s}", .{ x, units[u] });
    try w.print("{d:.1} {s}", .{ @min(x, 9_999_999), units[u] });
}

/// The longest prefix of `s` that is at most `cols` code points (cells).
fn truncate(s: []const u8, cols: usize) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < cols) : (n += 1) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch unreachable;
    }
    return s[0..i];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const steady: Stats.Rates = .{
    .emulated_fps = 60,
    .presented_fps = 59.96,
    .bytes_per_s = 2_100_000,
    .encode_ns_per_s = 1_200_000,
    .write_ns_per_s = 3_000_000,
};

fn expectLine(want: []const u8, st: State, cols: usize) !void {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings(want, format(&buf, st, cols));
}

test "a steady 1x line" {
    try expectLine(
        "emu 60.0 · pres 60.0 · 1× · 2.1 MB/s · enc 1.2 ms/s · wr 3.0 ms/s",
        .{ .rates = steady, .speed = .normal, .paused = false, .rebases = 0 },
        200,
    );
}

test "speeds" {
    const cases = [_]struct { Pacer.Speed, bool, []const u8 }{
        .{ .{ .x = 4 }, false, "4×" },
        .{ .{ .x = 0.25 }, false, "0.25×" },
        .{ .{ .x = 1.5 }, false, "1.5×" },
        .{ .{ .x = 3 }, false, "3×" },
        .{ .max, false, "max" },
        .{ .{ .x = 4 }, true, "paused" },
        .{ .max, true, "paused" },
    };
    for (cases) |c| {
        var buf: [max_len]u8 = undefined;
        const line = format(&buf, .{ .rates = steady, .speed = c[0], .paused = c[1], .rebases = 0 }, 200);
        const want = try std.fmt.allocPrint(testing.allocator, " · {s} · ", .{c[2]});
        defer testing.allocator.free(want);
        try testing.expect(std.mem.indexOf(u8, line, want) != null);
    }
}

test "lag shows only after a re-base" {
    try expectLine(
        "emu 60.0 · pres 60.0 · 1× · 2.1 MB/s · enc 1.2 ms/s · wr 3.0 ms/s · lag 2",
        .{ .rates = steady, .speed = .normal, .paused = false, .rebases = 2 },
        200,
    );
}

test "units" {
    const cases = [_]struct { f64, f64, f64, []const u8 }{
        .{ 0, 0, 0, "0 B/s · enc 0.0 ms/s · wr 0.0 ms/s" },
        .{ 512, 50_000, 400_000, "512 B/s · enc 0.1 ms/s · wr 0.4 ms/s" },
        .{ 999.4, 9_940_000, 9_940_000, "999 B/s · enc 9.9 ms/s · wr 9.9 ms/s" },
        .{ 999.9, 9_960_000, 9_960_000, "1.0 kB/s · enc 10 ms/s · wr 10 ms/s" },
        .{ 2_100, 250_000_000, 12_400_000, "2.1 kB/s · enc 250 ms/s · wr 12 ms/s" },
        .{ 999_960, 0, 1e9, "1.0 MB/s · enc 0.0 ms/s · wr 1000 ms/s" },
        .{ 1.3e9, 0, 0, "1.3 GB/s · enc 0.0 ms/s · wr 0.0 ms/s" },
        .{ 4e12, 0, 0, "4000.0 GB/s · enc 0.0 ms/s · wr 0.0 ms/s" },
    };
    for (cases) |c| {
        var buf: [max_len]u8 = undefined;
        const rates: Stats.Rates = .{ .bytes_per_s = c[0], .encode_ns_per_s = c[1], .write_ns_per_s = c[2] };
        const line = format(&buf, .{ .rates = rates, .speed = .normal, .paused = false, .rebases = 0 }, 200);
        if (!std.mem.endsWith(u8, line, c[3])) {
            std.debug.print("got: {s}\nwant suffix: {s}\n", .{ line, c[3] });
            return error.TestUnexpectedResult;
        }
    }
}

test "truncation counts cells, not bytes" {
    const st: State = .{ .rates = steady, .speed = .normal, .paused = false, .rebases = 0 };
    try expectLine("emu 60.0 ·", st, 10);
    try expectLine("emu 60.0 · pres 60.0 · 1×", st, 25);
    try expectLine("", st, 0);
}

test "extreme values still fit" {
    var buf: [max_len]u8 = undefined;
    const huge: Stats.Rates = .{ .emulated_fps = 1e300, .presented_fps = 1e300, .bytes_per_s = 1e300, .encode_ns_per_s = 1e300, .write_ns_per_s = 1e300 };
    const line = format(&buf, .{ .rates = huge, .speed = .{ .x = 1e300 }, .paused = false, .rebases = std.math.maxInt(u64) }, 1000);
    try testing.expect(line.len > 0);
}
