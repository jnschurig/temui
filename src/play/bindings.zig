//! Game bindings: which key presses which RetroPad button on port 0
//! (item 06). The table is hardcoded until item 11, which reuses `validate`
//! to reject remaps.
//!
//! A key matches by its character in the active layout, with Shift ignored
//! and only with no Ctrl, Alt or Super held, so chords such as Ctrl-] or
//! Ctrl-C never leak into the game as `]` or `c`.

const std = @import("std");
const keys = @import("../term/keys.zig");

/// RetroPad buttons, numbered as `RETRO_DEVICE_ID_JOYPAD_*` (the index into
/// `host.Buttons`).
pub const Button = enum(u4) {
    b = 0,
    y = 1,
    select = 2,
    start = 3,
    up = 4,
    down = 5,
    left = 6,
    right = 7,
    a = 8,
    x = 9,
    l = 10,
    r = 11,
    l2 = 12,
    r2 = 13,
    l3 = 14,
    r3 = 15,
};

pub const Binding = struct {
    key: keys.Key,
    button: Button,
};

fn char(c: u21, button: Button) Binding {
    return .{ .key = .{ .char = c }, .button = button };
}

/// One table for SNES, NES and GB alike: the cores map RetroPad A/B/Start/
/// Select onto their own buttons. A/B/X/Y form a SNES diamond (X top, Y
/// left, B bottom, A right). Arrows and L2/R2/L3/R3 are unbound.
pub const default = [_]Binding{
    char('e', .up),
    char('s', .left),
    char('d', .down),
    char('f', .right),
    char('l', .a),
    char('k', .b),
    char('i', .x),
    char('j', .y),
    char('a', .l),
    char(';', .r),
    char('h', .start),
    char('g', .select),
};

/// The buttons a table must bind.
pub const listed = [_]Button{ .up, .down, .left, .right, .a, .b, .x, .y, .l, .r, .start, .select };

/// The button `e` presses, if any. Ignores `e.kind`: the caller decides what
/// presses, repeats and releases mean.
pub fn lookup(table: []const Binding, e: keys.Event) ?Button {
    if (e.mods.chord()) return null;
    const k = normalize(e.key);
    for (table) |b| if (normalize(b.key).eql(k)) return b.button;
    return null;
}

/// Keys that can never be game bindings, on any path: Esc, the mode-key
/// chord (Ctrl + `mode_key`) and Ctrl-C.
pub fn reserved(e: keys.Event, mode_key: u21) bool {
    return switch (e.key) {
        .named => |n| n == .escape,
        .char => e.isCtrlC() or e.isChord(mode_key),
    };
}

pub const ValidateError = error{ ReservedKey, DuplicateKey, UnboundButton };

/// Checks a table: no reserved key, no key bound twice, and every `listed`
/// button bound.
pub fn validate(table: []const Binding, mode_key: u21) ValidateError!void {
    for (table, 0..) |b, i| {
        if (reserved(.{ .key = b.key }, mode_key)) return error.ReservedKey;
        for (table[0..i]) |prev| if (normalize(prev.key).eql(normalize(b.key))) return error.DuplicateKey;
    }
    for (listed) |button| {
        for (table) |b| {
            if (b.button == button) break;
        } else return error.UnboundButton;
    }
}

fn normalize(k: keys.Key) keys.Key {
    return switch (k) {
        .char => |c| .{ .char = keys.lower(c) },
        .named => k,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "button numbers match libretro" {
    const c = @import("libretro");
    try testing.expectEqual(c.RETRO_DEVICE_ID_JOYPAD_B, @intFromEnum(Button.b));
    try testing.expectEqual(c.RETRO_DEVICE_ID_JOYPAD_SELECT, @intFromEnum(Button.select));
    try testing.expectEqual(c.RETRO_DEVICE_ID_JOYPAD_UP, @intFromEnum(Button.up));
    try testing.expectEqual(c.RETRO_DEVICE_ID_JOYPAD_A, @intFromEnum(Button.a));
    try testing.expectEqual(c.RETRO_DEVICE_ID_JOYPAD_R, @intFromEnum(Button.r));
    try testing.expectEqual(c.RETRO_DEVICE_ID_JOYPAD_R3, @intFromEnum(Button.r3));
}

test "default table is valid" {
    try validate(&default, ']');
    // A different mode key that collides with no binding is fine too.
    try validate(&default, 'z');
}

test "validate rejects reserved, duplicate and missing" {
    var t = default;
    t[0] = .{ .key = .{ .named = .escape }, .button = .up };
    try testing.expectError(error.ReservedKey, validate(&t, ']'));

    t = default;
    t[1] = char('E', .left); // same key as `e`, case-insensitively
    try testing.expectError(error.DuplicateKey, validate(&t, ']'));

    try testing.expectError(error.UnboundButton, validate(default[0..11], ']'));
}

test "lookup: shift and caps match, chords don't" {
    const t = &default;
    try testing.expectEqual(@as(?Button, .up), lookup(t, keys.Event.char('e')));
    try testing.expectEqual(@as(?Button, .up), lookup(t, .{ .key = .{ .char = 'e' }, .shifted = 'E', .mods = .{ .shift = true } }));
    // A decoder that reports the uppercase character (Caps Lock).
    try testing.expectEqual(@as(?Button, .up), lookup(t, keys.Event.char('E')));
    try testing.expectEqual(@as(?Button, .r), lookup(t, keys.Event.char(';')));
    try testing.expectEqual(@as(?Button, .start), lookup(t, .{ .key = .{ .char = 'h' }, .kind = .release }));
    try testing.expectEqual(@as(?Button, null), lookup(t, .{ .key = .{ .char = 'e' }, .mods = .{ .ctrl = true } }));
    try testing.expectEqual(@as(?Button, null), lookup(t, .{ .key = .{ .char = 'e' }, .mods = .{ .alt = true } }));
    try testing.expectEqual(@as(?Button, null), lookup(t, .{ .key = .{ .char = 'e' }, .mods = .{ .super = true } }));
    try testing.expectEqual(@as(?Button, null), lookup(t, keys.Event.char(' ')));
    try testing.expectEqual(@as(?Button, null), lookup(t, keys.Event.named(.up)));
}

test "reserved keys" {
    const ctrl: keys.Mods = .{ .ctrl = true };
    try testing.expect(reserved(keys.Event.named(.escape), ']'));
    try testing.expect(reserved(.{ .key = .{ .char = 'c' }, .mods = ctrl }, ']'));
    try testing.expect(reserved(.{ .key = .{ .char = ']' }, .mods = ctrl }, ']'));
    try testing.expect(reserved(.{ .key = .{ .char = 'a' }, .mods = ctrl }, 'a'));
    try testing.expect(!reserved(.{ .key = .{ .char = 'a' }, .mods = ctrl }, ']'));
    try testing.expect(!reserved(keys.Event.char(']'), ']'));
    try testing.expect(!reserved(keys.Event.named(.enter), ']'));
    try testing.expect(!reserved(keys.Event.char(' '), ']'));
}
