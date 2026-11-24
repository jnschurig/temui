//! Live-run statistics from ack timestamps, byte counts and CPU deltas.
//! Ported from `spikes/termbench/stats.zig`.

const std = @import("std");

pub const target_fps = 60;
const s_ns = std.time.ns_per_s;

pub const Input = struct {
    /// Monotonic ns when the cell's first frame was sent.
    start_ns: u64,
    /// Monotonic ns when the cell ended (wall time = end - start).
    end_ns: u64,
    /// Ack (presentation) timestamps for this cell's frames, ascending.
    acks: []const u64,
    /// Bytes written to stdout during the cell (frames, DSRs, status bar).
    bytes: u64,
    self_cpu_ns: u64,
    /// Null when the terminal's processes could not be sampled.
    term_cpu_ns: ?u64 = null,
};

pub const Stats = struct {
    frames: u64,
    wall_s: f64,
    avg_fps: f64,
    /// Over full 1-s windows from start; avg when the cell is under 1 s.
    min_fps: f64,
    max_fps: f64,
    windows: u64,
    /// 99th-percentile interval between consecutive acks ("1% low").
    p99_frame_ms: f64,
    bytes_per_s: f64,
    self_cpu_pct: f64,
    self_ms_per_frame: f64,
    term_cpu_pct: ?f64,
    term_ms_per_frame: ?f64,
    /// Every full 1-s window had ≥ 60 acked frames.
    pass: bool,
};

fn f(x: u64) f64 {
    return @floatFromInt(x);
}

/// `scratch` must hold at least `in.acks.len` values.
pub fn compute(in: Input, scratch: []u64) Stats {
    const wall_ns = @max(in.end_ns -| in.start_ns, 1);
    const wall_s = f(wall_ns) / s_ns;
    const frames: u64 = in.acks.len;
    const avg = f(frames) / wall_s;

    // Acked frames per full 1-s window.
    const windows = wall_ns / s_ns;
    var min_fps: f64 = avg;
    var max_fps: f64 = avg;
    if (windows > 0) {
        min_fps = std.math.inf(f64);
        max_fps = 0;
        var i: usize = 0;
        var k: u64 = 0;
        while (k < windows) : (k += 1) {
            const lim = in.start_ns + (k + 1) * s_ns;
            var count: u64 = 0;
            while (i < in.acks.len and in.acks[i] < lim) : (i += 1) {
                if (in.acks[i] >= in.start_ns) count += 1;
            }
            min_fps = @min(min_fps, f(count));
            max_fps = @max(max_fps, f(count));
        }
    }

    var p99_ms: f64 = 0;
    if (frames > 0) {
        const iv = scratch[0..in.acks.len];
        var prev = in.start_ns;
        for (in.acks, iv) |a, *o| {
            o.* = a -| prev;
            prev = a;
        }
        std.mem.sort(u64, iv, {}, std.sort.asc(u64));
        // Nearest rank.
        const rank = (iv.len * 99 + 99) / 100;
        p99_ms = f(iv[rank - 1]) / std.time.ns_per_ms;
    }

    const per_frame = struct {
        fn ms(cpu: u64, n: u64) f64 {
            return if (n == 0) 0 else f(cpu) / f(n) / std.time.ns_per_ms;
        }
    }.ms;

    return .{
        .frames = frames,
        .wall_s = wall_s,
        .avg_fps = avg,
        .min_fps = min_fps,
        .max_fps = max_fps,
        .windows = windows,
        .p99_frame_ms = p99_ms,
        .bytes_per_s = f(in.bytes) / wall_s,
        .self_cpu_pct = 100 * f(in.self_cpu_ns) / f(wall_ns),
        .self_ms_per_frame = per_frame(in.self_cpu_ns, frames),
        .term_cpu_pct = if (in.term_cpu_ns) |t| 100 * f(t) / f(wall_ns) else null,
        .term_ms_per_frame = if (in.term_cpu_ns) |t| per_frame(t, frames) else null,
        .pass = frames > 0 and min_fps >= target_fps,
    };
}

const testing = std.testing;
const start: u64 = 5 * s_ns;

/// `per_window[k]` acks evenly spread over window k (offset so none sits on
/// a window boundary).
fn evenAcks(buf: []u64, per_window: []const u64) []u64 {
    var n: usize = 0;
    for (per_window, 0..) |count, k| {
        for (0..count) |j| {
            buf[n] = start + k * s_ns + j * s_ns / count + 1000;
            n += 1;
        }
    }
    return buf[0..n];
}

test "steady 120 fps passes" {
    var buf: [360]u64 = undefined;
    var scratch: [360]u64 = undefined;
    const acks = evenAcks(&buf, &.{ 120, 120, 120 });
    const s = compute(.{ .start_ns = start, .end_ns = start + 3 * s_ns, .acks = acks, .bytes = 3_000_000, .self_cpu_ns = 1500 * std.time.ns_per_ms, .term_cpu_ns = 300 * std.time.ns_per_ms }, &scratch);
    try testing.expectEqual(@as(u64, 360), s.frames);
    try testing.expectEqual(@as(u64, 3), s.windows);
    try testing.expectApproxEqAbs(@as(f64, 120), s.avg_fps, 1e-9);
    try testing.expectEqual(@as(f64, 120), s.min_fps);
    try testing.expectEqual(@as(f64, 120), s.max_fps);
    try testing.expectApproxEqAbs(@as(f64, 1000.0 / 120.0), s.p99_frame_ms, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1_000_000), s.bytes_per_s, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 50), s.self_cpu_pct, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1500.0 / 360.0), s.self_ms_per_frame, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), s.term_cpu_pct.?, 1e-9);
    try testing.expect(s.pass);
}

test "one window at 59 fps fails" {
    var buf: [400]u64 = undefined;
    var scratch: [400]u64 = undefined;
    const acks = evenAcks(&buf, &.{ 120, 59, 120 });
    const s = compute(.{ .start_ns = start, .end_ns = start + 3 * s_ns, .acks = acks, .bytes = 0, .self_cpu_ns = 0 }, &scratch);
    try testing.expectEqual(@as(f64, 59), s.min_fps);
    try testing.expectEqual(@as(f64, 120), s.max_fps);
    try testing.expectEqual(@as(?f64, null), s.term_cpu_pct);
    try testing.expect(!s.pass);
}

test "p99 frame interval uses nearest rank" {
    const ms = std.time.ns_per_ms;
    var buf: [100]u64 = undefined;
    var scratch: [100]u64 = undefined;
    for ([_]struct { long: usize, want: f64 }{ .{ .long = 1, .want = 10 }, .{ .long = 2, .want = 50 } }) |c| {
        var t = start;
        for (&buf, 0..) |*a, j| {
            t += if (j < c.long) 50 * ms else 10 * ms;
            a.* = t;
        }
        const s = compute(.{ .start_ns = start, .end_ns = t, .acks = &buf, .bytes = 0, .self_cpu_ns = 0 }, &scratch);
        try testing.expectApproxEqAbs(c.want, s.p99_frame_ms, 1e-9);
    }
}

test "no frames fails; short cells use avg for min/max" {
    var scratch: [1]u64 = undefined;
    const none = compute(.{ .start_ns = start, .end_ns = start + 2 * s_ns, .acks = &.{}, .bytes = 0, .self_cpu_ns = 0 }, &scratch);
    try testing.expect(!none.pass);
    try testing.expectEqual(@as(f64, 0), none.min_fps);

    var buf: [50]u64 = undefined;
    var scratch2: [50]u64 = undefined;
    for (&buf, 0..) |*a, j| a.* = start + (j + 1) * 10 * std.time.ns_per_ms;
    const short = compute(.{ .start_ns = start, .end_ns = start + s_ns / 2, .acks = &buf, .bytes = 0, .self_cpu_ns = 0 }, &scratch2);
    try testing.expectEqual(@as(u64, 0), short.windows);
    try testing.expectApproxEqAbs(@as(f64, 100), short.min_fps, 1e-9);
    try testing.expect(short.pass);
}
