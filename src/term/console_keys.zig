//! Windows console `KEY_EVENT` records → `keys.Event` (item 06). Pure, so
//! it compiles and is tested on every OS; `events.zig` feeds it the records
//! that `ReadConsoleInputW` returns once `ENABLE_VIRTUAL_TERMINAL_INPUT` is
//! off.
//!
//! The key comes from the virtual-key code: letters from VK_A–Z, named keys
//! from their VKs, and digits and punctuation from the layout's unshifted
//! character (`MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR)`, injected so tests use
//! a table), so `;` is found whatever VK the layout gives it. Left and right
//! Shift come from the scan code, right Ctrl and Alt from the enhanced-key
//! flag. A key-down for a key already down is a repeat; a key-up is a
//! release.

const std = @import("std");
const builtin = @import("builtin");
const keys = @import("keys.zig");

const Event = keys.Event;
const Key = keys.Key;
const Mods = keys.Mods;
const Named = keys.Named;

/// `KEY_EVENT_RECORD`, with `BOOL` as its `int`.
pub const KeyEventRecord = extern struct {
    bKeyDown: i32,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    UnicodeChar: u16,
    dwControlKeyState: u32,
};

pub const KEY_EVENT: u16 = 0x0001;
pub const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;
pub const FOCUS_EVENT: u16 = 0x0010;

/// `INPUT_RECORD`.
pub const InputRecord = extern struct {
    EventType: u16,
    Event: extern union {
        key: KeyEventRecord,
        /// `FOCUS_EVENT_RECORD.bSetFocus`.
        focus: i32,
        /// Mouse, window size and menu records; only the type matters.
        other: [16]u8,
    },

    pub fn keyRecord(k: KeyEventRecord) InputRecord {
        return .{ .EventType = KEY_EVENT, .Event = .{ .key = k } };
    }

    pub fn focusRecord(gained: bool) InputRecord {
        return .{ .EventType = FOCUS_EVENT, .Event = .{ .focus = @intFromBool(gained) } };
    }
};

comptime {
    std.debug.assert(@sizeOf(KeyEventRecord) == 16);
    std.debug.assert(@sizeOf(InputRecord) == 20);
}

/// The layout's unshifted character for a virtual-key code, or 0.
pub const VkToChar = *const fn (vk: u16) u21;

/// Which keys are down, by `downIndex`.
pub const DownSet = std.StaticBitSet(256);

pub const RIGHT_ALT_PRESSED: u32 = 0x0001;
pub const LEFT_ALT_PRESSED: u32 = 0x0002;
pub const RIGHT_CTRL_PRESSED: u32 = 0x0004;
pub const LEFT_CTRL_PRESSED: u32 = 0x0008;
pub const SHIFT_PRESSED: u32 = 0x0010;
pub const ENHANCED_KEY: u32 = 0x0100;

pub const VK_BACK = 0x08;
pub const VK_TAB = 0x09;
pub const VK_RETURN = 0x0D;
pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
pub const VK_MENU = 0x12;
pub const VK_CAPITAL = 0x14;
pub const VK_ESCAPE = 0x1B;
pub const VK_SPACE = 0x20;
pub const VK_UP = 0x26;
pub const VK_F1 = 0x70;
pub const VK_OEM_1 = 0xBA;
pub const VK_OEM_PLUS = 0xBB;
pub const VK_OEM_6 = 0xDD;

const scan_right_shift = 0x36;

/// The event for one record, or null for a key temui doesn't model. A
/// record with `wRepeatCount` > 1 stands for that many events: the caller
/// emits the rest as repeats.
pub fn translate(rec: KeyEventRecord, down: *DownSet, vkToChar: VkToChar) ?Event {
    const key = vkKey(rec, vkToChar) orelse return null;
    const st = rec.dwControlKeyState;
    var ev: Event = .{ .key = key, .mods = .{
        .shift = st & SHIFT_PRESSED != 0,
        .alt = st & (LEFT_ALT_PRESSED | RIGHT_ALT_PRESSED) != 0,
        .ctrl = st & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED) != 0,
    } };
    if (key == .char and ev.mods.shift and !ev.mods.ctrl and !ev.mods.alt) {
        const u = rec.UnicodeChar;
        if (u >= 0x20 and u != 0x7f and !std.unicode.utf16IsHighSurrogate(u) and !std.unicode.utf16IsLowSurrogate(u)) {
            ev.shifted = u;
        } else if (key.char >= 'a' and key.char <= 'z') {
            ev.shifted = key.char - ('a' - 'A');
        }
    }
    const i = downIndex(rec);
    if (rec.bKeyDown != 0) {
        ev.kind = if (down.isSet(i)) .repeat else .press;
        down.set(i);
    } else {
        ev.kind = .release;
        down.unset(i);
    }
    return ev;
}

/// The down-set slot: the VK, with the generic Shift/Ctrl/Alt VKs split
/// into left and right (VK_LSHIFT…VK_RMENU).
fn downIndex(rec: KeyEventRecord) usize {
    const enhanced = rec.dwControlKeyState & ENHANCED_KEY != 0;
    return switch (rec.wVirtualKeyCode) {
        VK_SHIFT => if (rec.wVirtualScanCode == scan_right_shift) 0xA1 else 0xA0,
        VK_CONTROL => if (enhanced) 0xA3 else 0xA2,
        VK_MENU => if (enhanced) 0xA5 else 0xA4,
        else => |vk| vk & 0xff,
    };
}

fn vkKey(rec: KeyEventRecord, vkToChar: VkToChar) ?Key {
    const vk = rec.wVirtualKeyCode;
    const enhanced = rec.dwControlKeyState & ENHANCED_KEY != 0;
    const named: ?Named = switch (vk) {
        VK_BACK => .backspace,
        VK_TAB => .tab,
        VK_RETURN => .enter,
        VK_ESCAPE => .escape,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .left,
        VK_UP => .up,
        0x27 => .right,
        0x28 => .down,
        0x2D => .insert,
        0x2E => .delete,
        VK_F1...VK_F1 + 11 => Named.f(@intCast(vk - VK_F1)),
        VK_SHIFT => if (rec.wVirtualScanCode == scan_right_shift) .right_shift else .left_shift,
        VK_CONTROL => if (enhanced) .right_ctrl else .left_ctrl,
        VK_MENU => if (enhanced) .right_alt else .left_alt,
        0xA0 => .left_shift,
        0xA1 => .right_shift,
        0xA2 => .left_ctrl,
        0xA3 => .right_ctrl,
        0xA4 => .left_alt,
        0xA5 => .right_alt,
        0x5B => .left_super,
        0x5C => .right_super,
        VK_CAPITAL => .caps_lock,
        else => null,
    };
    if (named) |n| return .{ .named = n };
    const c: u21 = switch (vk) {
        VK_SPACE => ' ',
        'A'...'Z' => vk + ('a' - 'A'),
        // Numpad.
        0x60...0x69 => '0' + @as(u21, vk - 0x60),
        0x6A => '*',
        0x6B => '+',
        0x6C => ',',
        0x6D => '-',
        0x6E => '.',
        0x6F => '/',
        // Digits and OEM punctuation: the layout decides.
        '0'...'9', 0xBA...0xC0, 0xDB...0xDF, 0xE2 => keys.lower(vkToChar(vk)),
        else => 0,
    };
    if (c == 0) return null;
    return .{ .char = c };
}

/// The production `VkToChar`: `MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR)`. The
/// high bit marks a dead key; its base character is still the key's.
pub const systemVkToChar: VkToChar = if (builtin.os.tag == .windows) &struct {
    extern "user32" fn MapVirtualKeyW(code: u32, map_type: u32) callconv(.winapi) u32;
    fn f(vk: u16) u21 {
        const MAPVK_VK_TO_CHAR = 2;
        const r = MapVirtualKeyW(vk, MAPVK_VK_TO_CHAR) & 0x7fff_ffff;
        return if (r > 0x10ffff) 0 else @intCast(r);
    }
}.f else &usTable;

/// A US layout, for tests (and a fallback off Windows, where nothing calls
/// it).
pub fn usTable(vk: u16) u21 {
    return switch (vk) {
        '0'...'9' => vk,
        0xBA => ';',
        0xBB => '=',
        0xBC => ',',
        0xBD => '-',
        0xBE => '.',
        0xBF => '/',
        0xC0 => '`',
        0xDB => '[',
        0xDC => '\\',
        0xDD => ']',
        0xDE => '\'',
        else => 0,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

pub fn testRecord(down: bool, vk: u16, uc: u16, state: u32) KeyEventRecord {
    return .{
        .bKeyDown = @intFromBool(down),
        .wRepeatCount = 1,
        .wVirtualKeyCode = vk,
        .wVirtualScanCode = 0,
        .UnicodeChar = uc,
        .dwControlKeyState = state,
    };
}

fn expectEvent(want: Event, got: ?Event) !void {
    errdefer std.debug.print("want {f} shifted={?d}, got {?f}\n", .{ want, want.shifted, got });
    try testing.expect(got != null and want.eql(got.?));
}

test "press, repeat, release" {
    var d: DownSet = .empty;
    try expectEvent(.{ .key = .{ .char = 'e' } }, translate(testRecord(true, 'E', 'e', 0), &d, usTable));
    try expectEvent(.{ .key = .{ .char = 'e' }, .kind = .repeat }, translate(testRecord(true, 'E', 'e', 0), &d, usTable));
    try expectEvent(.{ .key = .{ .char = 'e' }, .kind = .release }, translate(testRecord(false, 'E', 'e', 0), &d, usTable));
    try expectEvent(.{ .key = .{ .char = 'e' } }, translate(testRecord(true, 'E', 'e', 0), &d, usTable));
    // A release for a key never seen down is still a release.
    try expectEvent(.{ .key = .{ .char = 'k' }, .kind = .release }, translate(testRecord(false, 'K', 'k', 0), &d, usTable));
}

test "shift, ctrl, alt and layout characters" {
    var d: DownSet = .empty;
    const shift: Mods = .{ .shift = true };
    try expectEvent(.{ .key = .{ .char = 'z' }, .shifted = 'Z', .mods = shift }, translate(testRecord(true, 'Z', 'Z', SHIFT_PRESSED), &d, usTable));
    try expectEvent(.{ .key = .{ .char = '=' }, .shifted = '+', .mods = shift }, translate(testRecord(true, VK_OEM_PLUS, '+', SHIFT_PRESSED), &d, usTable));
    try expectEvent(.{ .key = .{ .char = ';' } }, translate(testRecord(true, VK_OEM_1, ';', 0), &d, usTable));
    try expectEvent(.{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } }, translate(testRecord(true, VK_OEM_6, 0x1d, LEFT_CTRL_PRESSED), &d, usTable));
    try expectEvent(.{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } }, translate(testRecord(true, 'C', 0x03, RIGHT_CTRL_PRESSED), &d, usTable));
    try expectEvent(.{ .key = .{ .char = 'e' }, .mods = .{ .alt = true } }, translate(testRecord(true, 'E', 'e', LEFT_ALT_PRESSED), &d, usTable));
    // A non-US layout: the VK the layout gives `;` is found by its char.
    const de = struct {
        fn f(vk: u16) u21 {
            return if (vk == 0xBC) ';' else 0;
        }
    }.f;
    try expectEvent(.{ .key = .{ .char = ';' } }, translate(testRecord(true, 0xBC, ';', 0), &d, de));
    // A VK the layout has no character for is dropped.
    try testing.expectEqual(@as(?Event, null), translate(testRecord(true, 0xE2, 0, 0), &d, usTable));
}

test "named keys, numpad and modifier keys" {
    var d: DownSet = .empty;
    try expectEvent(.named(.escape), translate(testRecord(true, VK_ESCAPE, 0x1b, 0), &d, usTable));
    try expectEvent(.named(.enter), translate(testRecord(true, VK_RETURN, '\r', 0), &d, usTable));
    try expectEvent(.named(.up), translate(testRecord(true, VK_UP, 0, ENHANCED_KEY), &d, usTable));
    try expectEvent(.named(.f5), translate(testRecord(true, VK_F1 + 4, 0, 0), &d, usTable));
    try expectEvent(.named(.f12), translate(testRecord(true, VK_F1 + 11, 0, 0), &d, usTable));
    try expectEvent(.char('7'), translate(testRecord(true, 0x67, '7', 0), &d, usTable));
    try expectEvent(.char(' '), translate(testRecord(true, VK_SPACE, ' ', 0), &d, usTable));

    // Left and right Shift by scan code, each tracked on its own.
    var l = testRecord(true, VK_SHIFT, 0, SHIFT_PRESSED);
    l.wVirtualScanCode = 0x2A;
    var r = testRecord(true, VK_SHIFT, 0, SHIFT_PRESSED);
    r.wVirtualScanCode = 0x36;
    try expectEvent(.{ .key = .{ .named = .left_shift }, .mods = .{ .shift = true } }, translate(l, &d, usTable));
    try expectEvent(.{ .key = .{ .named = .right_shift }, .mods = .{ .shift = true } }, translate(r, &d, usTable));
    try expectEvent(.{ .key = .{ .named = .left_shift }, .mods = .{ .shift = true }, .kind = .repeat }, translate(l, &d, usTable));
    // Right Ctrl and Alt by the enhanced flag.
    try expectEvent(.{ .key = .{ .named = .right_ctrl }, .mods = .{ .ctrl = true } }, translate(testRecord(true, VK_CONTROL, 0, RIGHT_CTRL_PRESSED | ENHANCED_KEY), &d, usTable));
    try expectEvent(.{ .key = .{ .named = .left_alt }, .mods = .{ .alt = true } }, translate(testRecord(true, VK_MENU, 0, LEFT_ALT_PRESSED), &d, usTable));
    // Unmodelled VKs (e.g. VK_PAUSE) are dropped.
    try testing.expectEqual(@as(?Event, null), translate(testRecord(true, 0x13, 0, 0), &d, usTable));
}

test "every input path gives the same events for the same physical action" {
    const key_decoder = @import("key_decoder.zig");
    const Action = struct {
        name: []const u8,
        kitty: []const u8,
        legacy: []const u8,
        console: []const KeyEventRecord,
    };
    const ctrl = LEFT_CTRL_PRESSED;
    const actions = [_]Action{
        .{ .name = "tap e", .kitty = "\x1b[101u\x1b[101;1:3u", .legacy = "e", .console = &.{ testRecord(true, 'E', 'e', 0), testRecord(false, 'E', 'e', 0) } },
        .{ .name = "hold e", .kitty = "\x1b[101u\x1b[101;1:2u\x1b[101;1:2u\x1b[101;1:3u", .legacy = "eee", .console = &.{ testRecord(true, 'E', 'e', 0), testRecord(true, 'E', 'e', 0), testRecord(true, 'E', 'e', 0), testRecord(false, 'E', 'e', 0) } },
        .{ .name = "shift-z", .kitty = "\x1b[122:90;2u\x1b[122:90;2:3u", .legacy = "Z", .console = &.{ testRecord(true, 'Z', 'Z', SHIFT_PRESSED), testRecord(false, 'Z', 'Z', SHIFT_PRESSED) } },
        .{ .name = "plus", .kitty = "\x1b[61:43;2u", .legacy = "+", .console = &.{testRecord(true, VK_OEM_PLUS, '+', SHIFT_PRESSED)} },
        .{ .name = "semicolon", .kitty = "\x1b[59u", .legacy = ";", .console = &.{testRecord(true, VK_OEM_1, ';', 0)} },
        .{ .name = "ctrl-]", .kitty = "\x1b[93;5u", .legacy = "\x1d", .console = &.{testRecord(true, VK_OEM_6, 0x1d, ctrl)} },
        .{ .name = "ctrl-c", .kitty = "\x1b[99;5u", .legacy = "\x03", .console = &.{testRecord(true, 'C', 0x03, ctrl)} },
        .{ .name = "up", .kitty = "\x1b[A\x1b[1;1:3A", .legacy = "\x1b[A", .console = &.{ testRecord(true, VK_UP, 0, ENHANCED_KEY), testRecord(false, VK_UP, 0, ENHANCED_KEY) } },
        .{ .name = "ctrl-up", .kitty = "\x1b[1;5A", .legacy = "\x1b[1;5A", .console = &.{testRecord(true, VK_UP, 0, ctrl | ENHANCED_KEY)} },
        .{ .name = "enter tab backspace", .kitty = "\x1b[13u\x1b[9u\x1b[127u", .legacy = "\r\t\x7f", .console = &.{ testRecord(true, VK_RETURN, '\r', 0), testRecord(true, VK_TAB, '\t', 0), testRecord(true, VK_BACK, 8, 0) } },
        .{ .name = "f5", .kitty = "\x1b[15~", .legacy = "\x1b[15~", .console = &.{testRecord(true, VK_F1 + 4, 0, 0)} },
        .{ .name = "space", .kitty = "\x1b[32u", .legacy = " ", .console = &.{testRecord(true, VK_SPACE, ' ', 0)} },
        .{ .name = "esc", .kitty = "\x1b[27u", .legacy = "\x1b", .console = &.{testRecord(true, VK_ESCAPE, 0x1b, 0)} },
    };
    for (actions) |a| {
        errdefer std.debug.print("action: {s}\n", .{a.name});
        var kitty_buf: [8]Event = undefined;
        var legacy_buf: [8]Event = undefined;
        var console_buf: [8]Event = undefined;

        var kd: key_decoder.Decoder = .init(.kitty);
        kd.acked = true;
        var kn: usize = 0;
        var kit = kd.feed(a.kitty, 0);
        while (kit.next()) |in| : (kn += 1) kitty_buf[kn] = in.key;
        try testing.expect(!kd.sawLegacyKey());

        var ld: key_decoder.Decoder = .init(.legacy);
        var ln: usize = 0;
        var lit = ld.feed(a.legacy, 0);
        while (lit.next()) |in| : (ln += 1) legacy_buf[ln] = in.key;
        if (ld.expire(key_decoder.stale_ns)) |in| {
            legacy_buf[ln] = in.key;
            ln += 1;
        }

        var down: DownSet = .empty;
        var cn: usize = 0;
        for (a.console) |r| if (translate(r, &down, usTable)) |e| {
            console_buf[cn] = e;
            cn += 1;
        };

        // Kitty and console input see the same thing exactly.
        try testing.expectEqual(kn, cn);
        for (kitty_buf[0..kn], console_buf[0..cn]) |k, c| try expectEvent(k, c);

        // Legacy sees only presses, and can't tell Shift for punctuation:
        // compare what the key types, its chord modifiers and named keys.
        var presses: usize = 0;
        for (kitty_buf[0..kn]) |k| {
            if (k.kind == .release) continue;
            try testing.expect(presses < ln);
            const l = legacy_buf[presses];
            presses += 1;
            try testing.expectEqual(keys.Kind.press, l.kind);
            try testing.expect(std.meta.activeTag(k.key) == std.meta.activeTag(l.key));
            switch (k.key) {
                .char => try testing.expectEqual(k.produced(), l.produced()),
                .named => |n| try testing.expectEqual(n, l.key.named),
            }
            try testing.expectEqual(k.mods.ctrl, l.mods.ctrl);
            try testing.expectEqual(k.mods.alt, l.mods.alt);
        }
        try testing.expectEqual(ln, presses);
    }
}

test "Windows: the system VK-to-char mapping is wired up" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // VK_A is the key giving `a` in every layout; MapVirtualKeyW reports it
    // uppercase, and `vkKey` lowercases.
    try testing.expectEqual(@as(u21, 'A'), systemVkToChar('A'));
}
