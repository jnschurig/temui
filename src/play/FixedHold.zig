//! The fixed hold for `--keyboard legacy` (D9, item 06), for scripts and
//! automation: the path sees only presses, so a press holds its key for a
//! fixed `hold_ns`, and another press of the same key while it is held
//! renews the hold. Nothing is learned. Pure: every time is passed in.
//!
//! To hold a key, a script resends it within `hold_ns`. A terminal's own
//! auto-repeat starts too late for that (its delay is 250–800 ms), which is
//! why people get game input only with release events.

const std = @import("std");
const keys = @import("../term/keys.zig");

const FixedHold = @This();

pub const hold_ns: i96 = 100 * std.time.ns_per_ms;

/// The most keys held at once. More than this is mashing; the hold that
/// runs out soonest is dropped to make room.
pub const capacity = 16;

pub const Held = struct { key: keys.Key, until: i96 };

held: [capacity]Held = undefined,
len: usize = 0,

/// A press of `key` at `now`: holds it until `now + hold_ns`, or renews
/// the hold to then. Call `expire(now)` first, so a hold that has run out
/// isn't renewed.
pub fn press(f: *FixedHold, key: keys.Key, now: i96) void {
    const until = now + hold_ns;
    for (f.held[0..f.len]) |*h| if (h.key.eql(key)) {
        h.until = until;
        return;
    };
    if (f.len == capacity) {
        var soonest: usize = 0;
        for (f.held[1..f.len], 1..) |h, i| {
            if (h.until < f.held[soonest].until) soonest = i;
        }
        f.removeAt(soonest);
    }
    f.held[f.len] = .{ .key = key, .until = until };
    f.len += 1;
}

/// When the next hold runs out, if any key is held.
pub fn nextDeadline(f: *const FixedHold) ?i96 {
    var next: ?i96 = null;
    for (f.held[0..f.len]) |h| {
        if (next == null or h.until < next.?) next = h.until;
    }
    return next;
}

/// Ends every hold that has run out by `now` and returns their keys, in
/// `out`.
pub fn expire(f: *FixedHold, now: i96, out: *[capacity]keys.Key) []keys.Key {
    var n: usize = 0;
    var i: usize = 0;
    while (i < f.len) {
        if (f.held[i].until <= now) {
            out[n] = f.held[i].key;
            n += 1;
            f.removeAt(i);
        } else i += 1;
    }
    return out[0..n];
}

/// Forgets every hold, e.g. on a mode switch.
pub fn releaseAll(f: *FixedHold) void {
    f.len = 0;
}

pub fn isHeld(f: *const FixedHold, key: keys.Key) bool {
    for (f.held[0..f.len]) |h| if (h.key.eql(key)) return true;
    return false;
}

pub fn heldKeys(f: *const FixedHold) []const Held {
    return f.held[0..f.len];
}

fn removeAt(f: *FixedHold, i: usize) void {
    // Order is kept, so `expire` returns keys in press order.
    std.mem.copyForwards(Held, f.held[i .. f.len - 1], f.held[i + 1 .. f.len]);
    f.len -= 1;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const ms = std.time.ns_per_ms;

fn k(c: u21) keys.Key {
    return .{ .char = c };
}

test "a tap is released at 100 ms" {
    var f: FixedHold = .{};
    var buf: [capacity]keys.Key = undefined;
    f.press(k('e'), 1000 * ms);
    try testing.expectEqual(@as(?i96, 1100 * ms), f.nextDeadline());
    try testing.expectEqual(0, f.expire(1099 * ms, &buf).len);
    try testing.expect(f.isHeld(k('e')));
    const out = f.expire(1100 * ms, &buf);
    try testing.expectEqual(1, out.len);
    try testing.expect(out[0].eql(k('e')));
    try testing.expect(!f.isHeld(k('e')));
    try testing.expectEqual(@as(?i96, null), f.nextDeadline());
}

test "repeats renew the hold; release is 100 ms after the last press" {
    var f: FixedHold = .{};
    var buf: [capacity]keys.Key = undefined;
    var t: i96 = 0;
    while (t <= 990) : (t += 33) {
        try testing.expectEqual(0, f.expire(t * ms, &buf).len);
        f.press(k('f'), t * ms);
        try testing.expect(f.isHeld(k('f')));
    }
    const last = t - 33;
    try testing.expectEqual(@as(?i96, (last + 100) * ms), f.nextDeadline());
    try testing.expectEqual(0, f.expire((last + 99) * ms, &buf).len);
    try testing.expectEqual(1, f.expire((last + 100) * ms, &buf).len);
    // Nothing is learned: the next tap is held for 100 ms again.
    f.press(k('f'), 5000 * ms);
    try testing.expectEqual(@as(?i96, 5100 * ms), f.nextDeadline());
}

test "two keys held at once expire independently" {
    var f: FixedHold = .{};
    var buf: [capacity]keys.Key = undefined;
    f.press(k('e'), 0);
    f.press(k('l'), 50 * ms);
    try testing.expect(f.isHeld(k('e')) and f.isHeld(k('l')));
    const out = f.expire(100 * ms, &buf);
    try testing.expectEqual(1, out.len);
    try testing.expect(out[0].eql(k('e')));
    try testing.expect(f.isHeld(k('l')));
    try testing.expectEqual(1, f.expire(150 * ms, &buf).len);
    f.press(k('e'), 200 * ms);
    f.releaseAll();
    try testing.expectEqual(0, f.len);
}

test "past capacity, the hold that runs out soonest is evicted" {
    var f: FixedHold = .{};
    for (0..capacity) |i| f.press(k('a' + @as(u21, @intCast(i))), @as(i96, @intCast(i)) * ms);
    // Renew 'a', so 'b' is now the soonest to run out.
    f.press(k('a'), 16 * ms);
    f.press(k('z'), 20 * ms);
    try testing.expectEqual(capacity, f.len);
    try testing.expect(f.isHeld(k('a')) and f.isHeld(k('z')));
    try testing.expect(!f.isHeld(k('b')));
}
