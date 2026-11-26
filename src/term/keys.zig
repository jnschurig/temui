//! The one key event type every input path produces (kitty keyboard
//! protocol, legacy terminal bytes, Windows console records). Bindings, the
//! mode key and the mode logic see only these, never raw bytes (item 06).

const std = @import("std");

pub const Named = enum {
    enter,
    tab,
    backspace,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_super,
    right_super,
    caps_lock,

    pub fn isModifier(n: Named) bool {
        return @intFromEnum(n) >= @intFromEnum(Named.left_shift);
    }

    /// F1 + `i` (0-based), for decoders that number the function keys.
    pub fn f(i: u8) Named {
        std.debug.assert(i < 12);
        return @enumFromInt(@intFromEnum(Named.f1) + i);
    }
};

pub const Key = union(enum) {
    /// A character key, by its unshifted character in the active layout.
    /// ASCII letters are always lowercase, so Shift-z and Caps-lock Z are
    /// both `z`.
    char: u21,
    named: Named,

    pub fn eql(a: Key, b: Key) bool {
        return switch (a) {
            .char => |c| b == .char and b.char == c,
            .named => |n| b == .named and b.named == n,
        };
    }
};

pub const Mods = packed struct(u4) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,

    pub const none: Mods = .{};

    /// Ctrl, Alt or Super: a chord, never a plain key.
    pub fn chord(m: Mods) bool {
        return m.ctrl or m.alt or m.super;
    }

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u4, @bitCast(a)) == @as(u4, @bitCast(b));
    }
};

pub const Kind = enum { press, repeat, release };

pub const Event = struct {
    key: Key,
    /// The character the key gives with Shift held, when the path knows it
    /// (kitty's alternate key, an uppercase legacy byte, the console's
    /// UnicodeChar), e.g. `+` for the `=` key. Only meaningful for `.char`.
    shifted: ?u21 = null,
    mods: Mods = .none,
    kind: Kind = .press,

    pub fn char(c: u21) Event {
        return .{ .key = .{ .char = c } };
    }

    pub fn named(n: Named) Event {
        return .{ .key = .{ .named = n } };
    }

    /// The character this event types: the shifted character when Shift
    /// is held and known, else the key's own. Null for named keys.
    pub fn produced(e: Event) ?u21 {
        const c = switch (e.key) {
            .char => |c| c,
            .named => return null,
        };
        if (e.mods.shift) if (e.shifted) |s| return s;
        return c;
    }

    /// Ctrl-C, by key: kitty `CSI 99;5u`, the legacy byte 0x03, or VK `C`
    /// with Ctrl on Windows. Shift and Alt may also be held.
    pub fn isCtrlC(e: Event) bool {
        return isChord(e, 'c');
    }

    /// Whether `e` is Ctrl plus `c` (no Super), matching either the key or
    /// its shifted character, so Ctrl-^ is found both as legacy 0x1e and as
    /// kitty's Ctrl-Shift-6 with alternate key `^`. Letters are matched
    /// case-insensitively.
    pub fn isChord(e: Event, c: u21) bool {
        if (!e.mods.ctrl or e.mods.super) return false;
        const k = switch (e.key) {
            .char => |k| k,
            .named => return false,
        };
        const want = lower(c);
        return k == want or (e.shifted != null and lower(e.shifted.?) == want);
    }

    pub fn eql(a: Event, b: Event) bool {
        return a.key.eql(b.key) and a.shifted == b.shifted and a.mods.eql(b.mods) and a.kind == b.kind;
    }

    pub fn format(e: Event, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (e.mods.ctrl) try w.writeAll("ctrl-");
        if (e.mods.alt) try w.writeAll("alt-");
        if (e.mods.super) try w.writeAll("super-");
        if (e.mods.shift) try w.writeAll("shift-");
        switch (e.key) {
            .char => |c| if (c > 0x20 and c < 0x7f) try w.writeByte(@intCast(c)) else try w.print("U+{X:0>4}", .{c}),
            .named => |n| try w.writeAll(@tagName(n)),
        }
        if (e.kind != .press) try w.print(" ({t})", .{e.kind});
    }
};

/// What an input path delivers: a key, or a focus change (true = gained).
pub const Input = union(enum) {
    key: Event,
    focus: bool,
};

/// ASCII uppercase to lowercase; everything else unchanged.
pub fn lower(c: u21) u21 {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "produced: shifted only with shift" {
    try testing.expectEqual(@as(?u21, '='), (Event{ .key = .{ .char = '=' }, .shifted = '+' }).produced());
    try testing.expectEqual(@as(?u21, '+'), (Event{ .key = .{ .char = '=' }, .shifted = '+', .mods = .{ .shift = true } }).produced());
    try testing.expectEqual(@as(?u21, '+'), Event.char('+').produced());
    try testing.expectEqual(@as(?u21, null), Event.named(.enter).produced());
}

test "isChord and isCtrlC" {
    const ctrl: Mods = .{ .ctrl = true };
    try testing.expect((Event{ .key = .{ .char = 'c' }, .mods = ctrl }).isCtrlC());
    try testing.expect((Event{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true, .shift = true } }).isCtrlC());
    try testing.expect(!Event.char('c').isCtrlC());
    try testing.expect(!(Event{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true, .super = true } }).isCtrlC());
    // Ctrl-^: legacy form and kitty's Ctrl-Shift-6.
    try testing.expect((Event{ .key = .{ .char = '^' }, .mods = ctrl }).isChord('^'));
    try testing.expect((Event{ .key = .{ .char = '6' }, .shifted = '^', .mods = .{ .ctrl = true, .shift = true } }).isChord('^'));
    try testing.expect((Event{ .key = .{ .char = ']' }, .mods = ctrl }).isChord(']'));
    try testing.expect(!(Event{ .key = .{ .named = .escape }, .mods = ctrl }).isChord('['));
}

test "event format" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f} {f} {f}", .{
        Event{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } },
        Event{ .key = .{ .named = .up }, .kind = .release },
        Event.char(' '),
    });
    try testing.expectEqualStrings("ctrl-] up (release) U+0020", w.buffered());
}
