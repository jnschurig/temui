//! Play-loop counters (D13): per-second rates over a sliding window, and
//! whole-run totals for the exit summary. Times are passed in, so it is
//! tested without a real clock.
//!
//! The window is ten 100 ms buckets (plus the one filling) in a ring, so
//! recording and reading cost the same however many frames run (unthrottled
//! runs thousands a second).
//! Rates cover the ten complete buckets before the current one: exactly the
//! last whole second, up to 100 ms old. The partial bucket is left out on
//! purpose: callers sample right after a frame runs, and a window ending at
//! a frame would always count one frame too many (60.8 fps at a steady 60).

const std = @import("std");

const Stats = @This();

pub const bucket_ns: i96 = 100 * std.time.ns_per_ms;
pub const buckets = 10;

pub const Counts = struct {
    /// Frames the core ran.
    emulated: u64 = 0,
    /// Frames drawn to the terminal.
    presented: u64 = 0,
    /// Bytes written to the terminal (frames, overlay, clears).
    bytes: u64 = 0,
    /// Time spent encoding frames for the terminal (the renderer's present,
    /// not the write).
    encode_ns: u64 = 0,
    /// Time spent in terminal writes.
    write_ns: u64 = 0,

    fn add(a: *Counts, b: Counts) void {
        a.emulated += b.emulated;
        a.presented += b.presented;
        a.bytes += b.bytes;
        a.encode_ns += b.encode_ns;
        a.write_ns += b.write_ns;
    }
};

/// Per-second rates over the window.
pub const Rates = struct {
    emulated_fps: f64 = 0,
    presented_fps: f64 = 0,
    bytes_per_s: f64 = 0,
    /// Nanoseconds of frame encoding per second of wall time.
    encode_ns_per_s: f64 = 0,
    /// Nanoseconds of terminal writes per second of wall time.
    write_ns_per_s: f64 = 0,
};

const Bucket = struct {
    /// `floor(t / bucket_ns)` of the times counted here.
    index: i96,
    counts: Counts = .{},
};

start_ns: i96,
/// The window's buckets plus the current, partial one.
ring: [buckets + 1]Bucket,
totals: Counts = .{},
/// Times the schedule was re-based because emulation fell behind.
rebases: u64 = 0,

pub fn init(now_ns: i96) Stats {
    // Every slot starts stale (an index no current time maps to).
    const stale: Bucket = .{ .index = std.math.minInt(i96) };
    return .{ .start_ns = now_ns, .ring = @splat(stale) };
}

fn indexOf(t: i96) i96 {
    return @divFloor(t, bucket_ns);
}

fn slot(s: *Stats, now_ns: i96) *Counts {
    const i = indexOf(now_ns);
    const b = &s.ring[@intCast(@mod(i, buckets + 1))];
    if (b.index != i) b.* = .{ .index = i };
    return &b.counts;
}

pub fn record(s: *Stats, now_ns: i96, c: Counts) void {
    s.slot(now_ns).add(c);
    s.totals.add(c);
}

pub fn emulated(s: *Stats, now_ns: i96, n: u64) void {
    s.record(now_ns, .{ .emulated = n });
}

pub fn presented(s: *Stats, now_ns: i96) void {
    s.record(now_ns, .{ .presented = 1 });
}

/// One write to the terminal: `bytes` long, taking `ns`.
pub fn wrote(s: *Stats, now_ns: i96, bytes: u64, ns: u64) void {
    s.record(now_ns, .{ .bytes = bytes, .write_ns = ns });
}

/// One frame encoded for the terminal, taking `ns`.
pub fn encoded(s: *Stats, now_ns: i96, ns: u64) void {
    s.record(now_ns, .{ .encode_ns = ns });
}

pub fn rebased(s: *Stats) void {
    s.rebases += 1;
}

/// Rates over the complete buckets before the one `now_ns` falls in (the
/// first second of a run: since the start).
pub fn rates(s: *const Stats, now_ns: i96) Rates {
    const cur = indexOf(now_ns);
    const first = cur - buckets;
    const span = cur * bucket_ns - @max(s.start_ns, first * bucket_ns);
    if (span <= 0) return .{};
    var sum: Counts = .{};
    for (s.ring) |b| {
        if (b.index >= first and b.index < cur) sum.add(b.counts);
    }
    const secs: f64 = @as(f64, @floatFromInt(span)) / std.time.ns_per_s;
    return .{
        .emulated_fps = @as(f64, @floatFromInt(sum.emulated)) / secs,
        .presented_fps = @as(f64, @floatFromInt(sum.presented)) / secs,
        .bytes_per_s = @as(f64, @floatFromInt(sum.bytes)) / secs,
        .encode_ns_per_s = @as(f64, @floatFromInt(sum.encode_ns)) / secs,
        .write_ns_per_s = @as(f64, @floatFromInt(sum.write_ns)) / secs,
    };
}

/// The exit line: `N frames in S s: emu X fps, presented Y fps`.
pub fn summary(s: *const Stats, w: *std.Io.Writer, now_ns: i96) std.Io.Writer.Error!void {
    const secs: f64 = @as(f64, @floatFromInt(@max(now_ns - s.start_ns, 0))) / std.time.ns_per_s;
    const emu: f64 = if (secs > 0) @as(f64, @floatFromInt(s.totals.emulated)) / secs else 0;
    const pres: f64 = if (secs > 0) @as(f64, @floatFromInt(s.totals.presented)) / secs else 0;
    try w.print("{d} frames in {d:.1} s: emu {d:.2} fps, presented {d:.2} fps\n", .{
        s.totals.emulated, secs, emu, pres,
    });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const ms = std.time.ns_per_ms;
const ns_per_s = std.time.ns_per_s;

fn expectApprox(want: f64, got: f64) !void {
    try testing.expectApproxEqAbs(want, got, 1e-6);
}

test "steady 60 fps reads as 60 once the window is full" {
    const t0: i96 = 5 * ns_per_s;
    var s: Stats = .init(t0);
    var t = t0;
    for (0..180) |_| {
        s.emulated(t, 1);
        s.presented(t);
        s.encoded(t, 20_000);
        s.wrote(t, 1000, 50_000);
        t += @divTrunc(ns_per_s, 60);
    }
    // Every bucket in the window is at 60 fps.
    const r = s.rates(t0 + 3 * ns_per_s);
    try testing.expectApproxEqAbs(60, r.emulated_fps, 1.5);
    try testing.expectApproxEqAbs(60, r.presented_fps, 1.5);
    try testing.expectApproxEqAbs(60_000, r.bytes_per_s, 1500);
    try testing.expectApproxEqAbs(1.2 * ms, r.encode_ns_per_s, 0.1 * ms);
    try testing.expectApproxEqAbs(3 * ms, r.write_ns_per_s, 0.1 * ms);
    try testing.expectEqual(180, s.totals.emulated);
}

test "rates early in a run divide by the time elapsed, not a full second" {
    var s: Stats = .init(0);
    s.emulated(0, 10);
    s.emulated(150 * ms, 20);
    s.emulated(220 * ms, 99); // in the partial bucket: not yet counted
    const r = s.rates(250 * ms);
    try expectApprox(150, r.emulated_fps); // 30 frames in the complete 0.2 s
}

test "a window ending on a frame doesn't count it twice" {
    // Frames at exactly 60 Hz, sampled right after each one: always 60.
    var s: Stats = .init(0);
    var k: i96 = 0;
    while (k < 600) : (k += 1) {
        const t = @divTrunc(k * ns_per_s, 60);
        s.emulated(t, 1);
        if (k >= 120) try testing.expectApproxEqAbs(60, s.rates(t).emulated_fps, 1e-9);
    }
}

test "the window forgets old buckets" {
    var s: Stats = .init(0);
    s.emulated(50 * ms, 100);
    // At 1.15 s the window is 0.1..1.1 s: the bucket at 0..100 ms is out.
    try expectApprox(0, s.rates(1150 * ms).emulated_fps);
    // At 1.05 s it is the last one in: 100 frames over the second 0..1 s.
    try expectApprox(100, s.rates(1050 * ms).emulated_fps);
    // At 0.95 s: 100 frames over the complete 0.9 s.
    try testing.expectApproxEqAbs(100.0 / 0.9, s.rates(950 * ms).emulated_fps, 1e-6);
    // A slot reused for a later bucket starts from zero.
    s.emulated(1050 * ms, 7);
    const r = s.rates(1100 * ms);
    try expectApprox(7, r.emulated_fps); // window 0.1..1.1 s
    try testing.expectEqual(107, s.totals.emulated);
}

test "a gap longer than the window reads as zero" {
    var s: Stats = .init(0);
    for (0..10) |i| s.presented(@as(i96, @intCast(i)) * 100 * ms);
    try testing.expect(s.rates(999 * ms).presented_fps > 0);
    try expectApprox(0, s.rates(60 * ns_per_s).presented_fps);
}

test "no time elapsed gives zero rates" {
    var s: Stats = .init(42);
    s.emulated(42, 5);
    try expectApprox(0, s.rates(42).emulated_fps);
}

test "summary line" {
    var s: Stats = .init(0);
    s.emulated(0, 600);
    for (0..300) |_| s.presented(0);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.summary(&w, 10 * ns_per_s);
    try testing.expectEqualStrings("600 frames in 10.0 s: emu 60.00 fps, presented 30.00 fps\n", w.buffered());
}

test "summary with no time elapsed" {
    var s: Stats = .init(0);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.summary(&w, 0);
    try testing.expectEqualStrings("0 frames in 0.0 s: emu 0.00 fps, presented 0.00 fps\n", w.buffered());
}
