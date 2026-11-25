//! Frame scheduling for the play loop (D8): pure arithmetic over times the
//! caller passes in, so it is tested without a real clock.
//!
//! The schedule is absolute: frame `base_frame + k` is due at
//! `base_ns + k·period`, so jitter in when the loop wakes never accumulates
//! into drift. It is re-based (to "now", next frame due immediately) on
//! resume, on a speed change, and when emulation falls more than `max_lag_ns`
//! behind; only the last counts as a re-base in `rebases`, since it is the
//! one the user sees as lag.

const std = @import("std");

const Pacer = @This();

/// Behind schedule by more than this, the schedule restarts from now: the
/// game slows down instead of spiralling to catch up.
pub const max_lag_ns: i96 = 100 * std.time.ns_per_ms;

/// The speed ladder the temporary keys walk; `max` sits above its top.
pub const ladder = [_]f64{ 0.25, 0.5, 1, 2, 4, 8 };

pub const Speed = union(enum) {
    /// A multiple of the core's fps (> 0); < 1 is slow motion.
    x: f64,
    /// Unthrottled: frames back to back.
    max,

    pub const normal: Speed = .{ .x = 1 };

    pub fn eql(a: Speed, b: Speed) bool {
        return switch (a) {
            .max => b == .max,
            .x => |ax| b == .x and ax == b.x,
        };
    }

    /// The next ladder step above `s` (`max` past the top).
    pub fn faster(s: Speed) Speed {
        const x = switch (s) {
            .max => return .max,
            .x => |x| x,
        };
        for (ladder) |l| if (l > x * (1 + eps)) return .{ .x = l };
        return .max;
    }

    /// The next ladder step below `s`; at or below the bottom it stays.
    pub fn slower(s: Speed) Speed {
        const x = switch (s) {
            .max => return .{ .x = ladder[ladder.len - 1] },
            .x => |x| x,
        };
        var i = ladder.len;
        while (i > 0) {
            i -= 1;
            if (ladder[i] < x * (1 - eps)) return .{ .x = ladder[i] };
        }
        return s;
    }

    /// Off-ladder values within this relative distance count as on it.
    const eps = 1e-9;
};

/// The core's frames per second (> 0).
fps: f64,
speed: Speed,
paused: bool,
/// Schedule origin: frame number `base_frame` was due at `base_ns`.
base_ns: i96,
base_frame: u64,
/// Frames run so far.
frames: u64 = 0,
/// Times the schedule was re-based because emulation fell behind.
rebases: u64 = 0,
/// Frames granted by `step` while paused and not yet run.
step_credit: u64 = 0,

pub fn init(fps: f64, speed: Speed, paused: bool, now_ns: i96) Pacer {
    std.debug.assert(fps > 0);
    if (speed == .x) std.debug.assert(speed.x > 0);
    return .{ .fps = fps, .speed = speed, .paused = paused, .base_ns = now_ns, .base_frame = 0 };
}

/// Frames per second at the current speed; null when unthrottled.
fn rate(p: *const Pacer) ?f64 {
    return switch (p.speed) {
        .max => null,
        .x => |x| p.fps * x,
    };
}

/// When frame `base_frame + k` is due.
fn deadline(p: *const Pacer, k: u64, r: f64) i96 {
    const off: f64 = @as(f64, @floatFromInt(k)) * std.time.ns_per_s / r;
    return p.base_ns + @as(i96, @intFromFloat(@floor(off)));
}

fn rebase(p: *Pacer, now_ns: i96) void {
    p.base_ns = now_ns;
    p.base_frame = p.frames;
}

/// How many frames should run now. Paused: the frames `step` granted.
/// Unthrottled: `maxInt(u64)` (the caller bounds the batch by time). If the
/// next frame is more than `max_lag_ns` late, the schedule is re-based first
/// (counted in `rebases`) and one frame is due.
pub fn due(p: *Pacer, now_ns: i96) u64 {
    if (p.paused) return p.step_credit;
    const r = p.rate() orelse return std.math.maxInt(u64);
    const k = p.frames - p.base_frame;
    const next = p.deadline(k, r);
    if (now_ns < next) return 0;
    if (now_ns - next > max_lag_ns) {
        p.rebase(now_ns);
        p.rebases += 1;
        return 1;
    }
    // Frames due by now: the largest n with deadline(k + n - 1) <= now.
    // Estimated with floats, then corrected so it agrees with `deadline`.
    const elapsed: f64 = @floatFromInt(now_ns - p.base_ns);
    var last: u64 = @intFromFloat(@floor(elapsed * r / std.time.ns_per_s));
    while (last > k and p.deadline(last, r) > now_ns) last -= 1;
    while (p.deadline(last + 1, r) <= now_ns) last += 1;
    return last - k + 1;
}

/// Records that `n` frames ran.
pub fn ran(p: *Pacer, n: u64) void {
    p.frames += n;
    if (p.paused) p.step_credit -|= n;
}

/// When the next frame is due; null when paused or unthrottled.
pub fn nextDeadline(p: *const Pacer) ?i96 {
    if (p.paused) return null;
    const r = p.rate() orelse return null;
    return p.deadline(p.frames - p.base_frame, r);
}

pub fn pause(p: *Pacer) void {
    p.paused = true;
    p.step_credit = 0;
}

/// Restarts the schedule at `now_ns`, so there is no catch-up burst.
pub fn resumeAt(p: *Pacer, now_ns: i96) void {
    if (!p.paused) return;
    p.paused = false;
    p.step_credit = 0;
    p.rebase(now_ns);
}

/// While paused, grants exactly one more frame; otherwise ignored.
pub fn step(p: *Pacer) void {
    if (p.paused) p.step_credit += 1;
}

pub fn setSpeed(p: *Pacer, speed: Speed, now_ns: i96) void {
    if (speed == .x) std.debug.assert(speed.x > 0);
    p.speed = speed;
    p.rebase(now_ns);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const ns_per_s = std.time.ns_per_s;
const ms = std.time.ns_per_ms;

/// Simulates a loop that wakes at each deadline plus `jitter(i)` ns and runs
/// whatever is due, until `end_ns`. Returns frames run.
fn simulate(p: *Pacer, start_ns: i96, end_ns: i96, jitter: *const fn (u64) i96) u64 {
    var now = start_ns;
    var wakes: u64 = 0;
    while (now < end_ns) : (wakes += 1) {
        const n = p.due(now);
        p.ran(n);
        const next = p.nextDeadline() orelse unreachable;
        now = @max(now + 1, next + jitter(wakes));
    }
    return p.frames;
}

fn noJitter(_: u64) i96 {
    return 0;
}

fn someJitter(i: u64) i96 {
    // 0..3.9 ms late, varying; never enough to trigger a re-base.
    return @intCast((i * 7919) % 4000 * 1000);
}

test "60 fps for 300 simulated seconds is exactly 18000 frames" {
    var p: Pacer = .init(60, .normal, false, 0);
    try testing.expectEqual(18000, simulate(&p, 0, 300 * ns_per_s, noJitter));
    try testing.expectEqual(0, p.rebases);
}

test "jitter does not accumulate into drift" {
    var p: Pacer = .init(60, .normal, false, 0);
    const n = simulate(&p, 0, 300 * ns_per_s, someJitter);
    // Each wake is late by < 4 ms, so at most one frame is still pending.
    try testing.expect(n >= 17999 and n <= 18000);
    try testing.expectEqual(0, p.rebases);
}

test "non-integer fps (SNES NTSC) stays on schedule" {
    const fps = 60.098813897440515;
    var p: Pacer = .init(fps, .normal, false, 0);
    const n = simulate(&p, 0, 100 * ns_per_s, someJitter);
    const want: f64 = fps * 100;
    try testing.expect(@abs(@as(f64, @floatFromInt(n)) - want) <= 1.5);
}

test "4x and 0.25x rates" {
    var fast: Pacer = .init(60, .{ .x = 4 }, false, 0);
    try testing.expectEqual(2400, simulate(&fast, 0, 10 * ns_per_s, noJitter));
    var slow: Pacer = .init(60, .{ .x = 0.25 }, false, 0);
    try testing.expectEqual(150, simulate(&slow, 0, 10 * ns_per_s, noJitter));
}

test "due counts every frame whose deadline has passed" {
    var p: Pacer = .init(60, .normal, false, 1000);
    try testing.expectEqual(1, p.due(1000)); // frame 0 is due at the start
    try testing.expectEqual(0, p.due(999));
    // 50 ms in: frames 0, 1, 2 (at 0, 16.67, 33.33 ms) plus frame 3 at 50 ms.
    try testing.expectEqual(4, p.due(1000 + 50 * ms));
    p.ran(4);
    try testing.expectEqual(0, p.due(1000 + 50 * ms + 1));
    try testing.expectEqual(1000 + 66_666_666, p.nextDeadline().?);
}

test "a short stall catches up; a long one re-bases once" {
    var p: Pacer = .init(60, .normal, false, 0);
    p.ran(p.due(0));
    // 50 ms late: catch up with a burst, no re-base.
    var now: i96 = p.nextDeadline().? + 50 * ms;
    const burst = p.due(now);
    try testing.expectEqual(4, burst);
    try testing.expectEqual(0, p.rebases);
    p.ran(burst);

    // 150 ms late: re-base, exactly one frame now, no burst.
    now = p.nextDeadline().? + 150 * ms;
    try testing.expectEqual(1, p.due(now));
    try testing.expectEqual(1, p.rebases);
    p.ran(1);
    try testing.expectEqual(0, p.due(now));
    try testing.expectEqual(now + 16_666_666, p.nextDeadline().?);
}

test "pause runs nothing; step grants exactly one frame each" {
    var p: Pacer = .init(60, .normal, false, 0);
    p.ran(p.due(0));
    p.pause();
    try testing.expectEqual(0, p.due(10 * ns_per_s));
    try testing.expectEqual(null, p.nextDeadline());
    for (0..5) |_| {
        p.step();
        const n = p.due(10 * ns_per_s);
        try testing.expectEqual(1, n);
        p.ran(n);
        try testing.expectEqual(0, p.due(10 * ns_per_s));
    }
    try testing.expectEqual(6, p.frames);
    try testing.expectEqual(0, p.rebases);
}

test "step is ignored while running" {
    var p: Pacer = .init(60, .normal, false, 0);
    p.step();
    try testing.expectEqual(0, p.step_credit);
}

test "resume after a long pause has no catch-up burst" {
    var p: Pacer = .init(60, .normal, true, 0);
    try testing.expectEqual(0, p.due(0));
    p.resumeAt(60 * ns_per_s);
    try testing.expectEqual(1, p.due(60 * ns_per_s));
    try testing.expectEqual(0, p.rebases);
}

test "speed change re-bases without counting lag" {
    var p: Pacer = .init(60, .normal, false, 0);
    p.ran(p.due(0));
    p.setSpeed(.{ .x = 2 }, 5 * ns_per_s);
    try testing.expectEqual(1, p.due(5 * ns_per_s));
    p.ran(1);
    try testing.expectEqual(5 * ns_per_s + 8_333_333, p.nextDeadline().?);
    try testing.expectEqual(0, p.rebases);
}

test "unthrottled: everything is due and there is no deadline" {
    var p: Pacer = .init(60, .max, false, 0);
    try testing.expectEqual(std.math.maxInt(u64), p.due(0));
    try testing.expectEqual(null, p.nextDeadline());
    p.ran(1000);
    p.setSpeed(.normal, 1 * ns_per_s);
    try testing.expectEqual(1, p.due(1 * ns_per_s));
}

test "ladder: faster, slower, edges and off-ladder values" {
    const S = Speed;
    try testing.expect(S.normal.faster().eql(.{ .x = 2 }));
    try testing.expect((S{ .x = 8 }).faster().eql(.max));
    try testing.expect((S{ .max = {} }).faster().eql(.max));
    try testing.expect((S{ .max = {} }).slower().eql(.{ .x = 8 }));
    try testing.expect(S.normal.slower().eql(.{ .x = 0.5 }));
    try testing.expect((S{ .x = 0.25 }).slower().eql(.{ .x = 0.25 }));
    try testing.expect((S{ .x = 0.1 }).slower().eql(.{ .x = 0.1 }));
    try testing.expect((S{ .x = 0.1 }).faster().eql(.{ .x = 0.25 }));
    try testing.expect((S{ .x = 3 }).faster().eql(.{ .x = 4 }));
    try testing.expect((S{ .x = 3 }).slower().eql(.{ .x = 2 }));
    try testing.expect((S{ .x = 20 }).faster().eql(.max));
    try testing.expect((S{ .x = 20 }).slower().eql(.{ .x = 8 }));
    try testing.expect(!(S{ .max = {} }).eql(.normal));
}
