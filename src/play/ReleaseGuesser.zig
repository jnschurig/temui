//! Release guessing for the legacy input path (D9, item 06), which sees
//! only presses: a held key shows up as auto-repeat, and its release as the
//! repeats stopping. Pure: every time is passed in.
//!
//! A new press holds its key for the *initial window* (the terminal's delay
//! before the first repeat, plus margin). Each repeat renews the hold for
//! the *release timeout* (a few repeat intervals). Both are learned from
//! the last few observations, clamped, and start fresh each run.
//!
//! Terminals repeat only the most recent key, so pressing a second key
//! doesn't release the first directly: its repeats stop and its hold runs
//! out on its own.

const std = @import("std");
const keys = @import("../term/keys.zig");

const log = std.log.scoped(.input);

const ReleaseGuesser = @This();

const ms = std.time.ns_per_ms;

pub const default_initial_ns: i96 = 500 * ms;
pub const initial_min_ns: i96 = 250 * ms;
pub const initial_max_ns: i96 = 800 * ms;
/// Before any repeat interval is measured, the longest allowed timeout, so
/// a slow repeat rate never stutters.
pub const default_release_ns: i96 = release_max_ns;
pub const release_min_ns: i96 = 50 * ms;
pub const release_max_ns: i96 = 200 * ms;

/// The most keys held at once. More than this is mashing; the oldest hold
/// is dropped (see `Press.evicted`).
pub const capacity = 16;

const Held = struct {
    key: keys.Key,
    pressed_ns: i96,
    last_ns: i96,
    repeated: bool,
};

held: [capacity]Held = undefined,
len: usize = 0,
initial_ns: i96 = default_initial_ns,
release_ns: i96 = default_release_ns,
first_gaps: Samples = .{},
intervals: Samples = .{},

pub const Press = struct {
    kind: enum { new, repeat },
    /// A key dropped to make room: release it now.
    evicted: ?keys.Key = null,
};

/// A press of `key` at `now`: a repeat when `key` is already held, else a
/// new hold. Call `expire(now)` first, so a hold that has run out isn't
/// taken for a repeat.
pub fn press(g: *ReleaseGuesser, key: keys.Key, now: i96) Press {
    for (g.held[0..g.len]) |*h| {
        if (!h.key.eql(key)) continue;
        if (h.repeated) {
            g.intervals.push(now - h.last_ns);
            g.learnRelease();
        } else {
            g.first_gaps.push(now - h.pressed_ns);
            g.learnInitial();
            h.repeated = true;
        }
        h.last_ns = now;
        return .{ .kind = .repeat };
    }
    var result: Press = .{ .kind = .new };
    if (g.len == capacity) {
        var oldest: usize = 0;
        for (g.held[1..g.len], 1..) |h, i| {
            if (g.deadlineOf(h) < g.deadlineOf(g.held[oldest])) oldest = i;
        }
        result.evicted = g.held[oldest].key;
        g.removeAt(oldest);
    }
    g.held[g.len] = .{ .key = key, .pressed_ns = now, .last_ns = now, .repeated = false };
    g.len += 1;
    return result;
}

/// When the next hold runs out, if any key is held.
pub fn nextDeadline(g: *const ReleaseGuesser) ?i96 {
    var next: ?i96 = null;
    for (g.held[0..g.len]) |h| {
        const d = g.deadlineOf(h);
        if (next == null or d < next.?) next = d;
    }
    return next;
}

/// Ends every hold that has run out by `now` and returns their keys, in
/// `out`.
pub fn expire(g: *ReleaseGuesser, now: i96, out: *[capacity]keys.Key) []keys.Key {
    var n: usize = 0;
    var i: usize = 0;
    while (i < g.len) {
        if (g.deadlineOf(g.held[i]) <= now) {
            out[n] = g.held[i].key;
            n += 1;
            g.removeAt(i);
        } else i += 1;
    }
    return out[0..n];
}

/// Forgets every hold, e.g. on a mode switch. Learned timings are kept.
pub fn releaseAll(g: *ReleaseGuesser) void {
    g.len = 0;
}

pub fn isHeld(g: *const ReleaseGuesser, key: keys.Key) bool {
    for (g.held[0..g.len]) |h| if (h.key.eql(key)) return true;
    return false;
}

fn deadlineOf(g: *const ReleaseGuesser, h: Held) i96 {
    return if (h.repeated) h.last_ns + g.release_ns else h.pressed_ns + g.initial_ns;
}

fn removeAt(g: *ReleaseGuesser, i: usize) void {
    // Order is kept, so `expire` returns keys in press order.
    std.mem.copyForwards(Held, g.held[i .. g.len - 1], g.held[i + 1 .. g.len]);
    g.len -= 1;
}

fn learnInitial(g: *ReleaseGuesser) void {
    const v = std.math.clamp(@divTrunc(g.first_gaps.median() * 12, 10), initial_min_ns, initial_max_ns);
    if (v == g.initial_ns) return;
    g.initial_ns = v;
    log.info("legacy keys: initial window {d} ms", .{@divTrunc(v, ms)});
}

fn learnRelease(g: *ReleaseGuesser) void {
    const v = std.math.clamp(@divTrunc(g.intervals.median() * 5, 2), release_min_ns, release_max_ns);
    if (v == g.release_ns) return;
    g.release_ns = v;
    log.info("legacy keys: release timeout {d} ms", .{@divTrunc(v, ms)});
}

/// The last 8 observations.
const Samples = struct {
    buf: [8]i96 = undefined,
    len: usize = 0,
    next: usize = 0,

    fn push(s: *Samples, v: i96) void {
        s.buf[s.next] = v;
        s.next = (s.next + 1) % s.buf.len;
        s.len = @min(s.len + 1, s.buf.len);
    }

    fn median(s: *const Samples) i96 {
        std.debug.assert(s.len > 0);
        var sorted = s.buf;
        const v = sorted[0..s.len];
        std.mem.sortUnstable(i96, v, {}, std.sort.asc(i96));
        const mid = s.len / 2;
        return if (s.len % 2 == 1) v[mid] else @divTrunc(v[mid - 1] + v[mid], 2);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const e_key: keys.Key = .{ .char = 'e' };
const f_key: keys.Key = .{ .char = 'f' };

/// Runs `expire(now)` and checks it released exactly `want`.
fn expectExpire(g: *ReleaseGuesser, now_ms: i96, want: []const keys.Key) !void {
    var out: [capacity]keys.Key = undefined;
    const got = g.expire(now_ms * ms, &out);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, k| try testing.expect(w.eql(k));
}

fn pressAt(g: *ReleaseGuesser, key: keys.Key, now_ms: i96) !@FieldType(Press, "kind") {
    try expectExpire(g, now_ms, &.{});
    const p = g.press(key, now_ms * ms);
    try testing.expectEqual(@as(?keys.Key, null), p.evicted);
    return p.kind;
}

test "a tap is released at the initial window" {
    var g: ReleaseGuesser = .{};
    try testing.expectEqual(.new, try pressAt(&g, e_key, 0));
    try testing.expectEqual(@as(?i96, 500 * ms), g.nextDeadline());
    try expectExpire(&g, 499, &.{});
    try expectExpire(&g, 500, &.{e_key});
    try testing.expectEqual(@as(?i96, null), g.nextDeadline());
}

test "a hold is continuous through the initial delay and repeats, then released" {
    var g: ReleaseGuesser = .{};
    try testing.expectEqual(.new, try pressAt(&g, e_key, 0));
    // 400 ms initial delay, then 33 ms repeats: never released in between
    // (pressAt checks expire returns nothing at each repeat).
    var t: i96 = 400;
    while (t < 2000) : (t += 33) {
        try testing.expectEqual(.repeat, try pressAt(&g, e_key, t));
        try testing.expect(g.isHeld(e_key));
    }
    const last = t - 33;
    // Learned: initial 1.2 × 400 = 480, release 2.5 × 33 = 82.5 ms.
    try testing.expectEqual(@as(i96, 480 * ms), g.initial_ns);
    try testing.expectEqual(@as(i96, 82_500_000), g.release_ns);
    try expectExpire(&g, last + 82, &.{});
    try expectExpire(&g, last + 83, &.{e_key});
}

test "before an interval is measured, one repeat holds for the max timeout" {
    var g: ReleaseGuesser = .{};
    _ = try pressAt(&g, e_key, 0);
    _ = try pressAt(&g, e_key, 400);
    try testing.expectEqual(@as(?i96, 600 * ms), g.nextDeadline());
}

test "learning uses the median and clamps" {
    var g: ReleaseGuesser = .{};
    // Short initial delays clamp to 250 ms.
    _ = try pressAt(&g, e_key, 0);
    _ = try pressAt(&g, e_key, 100);
    try testing.expectEqual(initial_min_ns, g.initial_ns);
    // Fast repeats clamp to 50 ms.
    _ = try pressAt(&g, e_key, 110);
    try testing.expectEqual(release_min_ns, g.release_ns);
    try expectExpire(&g, 160, &.{e_key});

    // Slow repeats clamp to 200 ms. Three samples of 150 outvote the 10.
    var t: i96 = 1000;
    _ = try pressAt(&g, f_key, t);
    t += 200;
    _ = try pressAt(&g, f_key, t);
    for (0..3) |_| {
        t += 40; // within the current timeout
        _ = try pressAt(&g, f_key, t);
    }
    // Samples: 10, 40, 40, 40 → median 40 → 100 ms.
    try testing.expectEqual(@as(i96, 100 * ms), g.release_ns);
    for (0..5) |_| {
        t += 90;
        _ = try pressAt(&g, f_key, t);
    }
    // The last 8: 40×3, 90×5 → median 90 → 225, clamped to 200.
    try testing.expectEqual(release_max_ns, g.release_ns);
}

test "the initial window clamps at the max" {
    var g: ReleaseGuesser = .{};
    var t: i96 = 0;
    // Each first repeat lands just inside the current window, pushing the
    // learned window up until the clamp holds it.
    for (0..20) |_| {
        _ = try pressAt(&g, e_key, t);
        t += @divTrunc(g.initial_ns, ms) - 1;
        try testing.expectEqual(.repeat, try pressAt(&g, e_key, t));
        try testing.expect(g.initial_ns <= initial_max_ns);
        t += 1000;
        try expectExpire(&g, t, &.{e_key});
    }
    try testing.expectEqual(initial_max_ns, g.initial_ns);
}

test "two keys one after the other each run out on their own" {
    var g: ReleaseGuesser = .{};
    _ = try pressAt(&g, e_key, 0);
    _ = try pressAt(&g, e_key, 400);
    _ = try pressAt(&g, e_key, 433);
    // f pressed: e's repeats stop, f is new.
    try testing.expectEqual(.new, try pressAt(&g, f_key, 450));
    try testing.expect(g.isHeld(e_key) and g.isHeld(f_key));
    // e: 433 + 82.5 ms. f: 450 + 480 ms.
    try expectExpire(&g, 515, &.{});
    try expectExpire(&g, 516, &.{e_key});
    try testing.expect(g.isHeld(f_key));
    try expectExpire(&g, 929, &.{});
    try expectExpire(&g, 930, &.{f_key});
}

test "releaseAll keeps learned timings; full set evicts the soonest hold" {
    var g: ReleaseGuesser = .{};
    _ = try pressAt(&g, e_key, 0);
    _ = try pressAt(&g, e_key, 300);
    g.releaseAll();
    try testing.expect(!g.isHeld(e_key));
    try testing.expectEqual(@as(i96, 360 * ms), g.initial_ns);

    for (0..capacity) |i| _ = g.press(.{ .char = @intCast('a' + i) }, @intCast(i));
    const p = g.press(.{ .char = '1' }, capacity);
    try testing.expectEqual(.new, p.kind);
    try testing.expect(p.evicted.?.eql(.{ .char = 'a' }));
    try testing.expectEqual(@as(usize, capacity), g.len);
}
