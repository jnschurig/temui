//! Terminal-safe text for the status line and boxes: cell widths, and
//! writing text with control characters and bad UTF-8 replaced by `?` so a
//! ROM file name can't inject escape sequences.

const std = @import("std");

/// Cells a code point takes. East Asian wide and emoji ranges are 2, the
/// rest 1 (combining marks too: overestimating only leaves a gap, while
/// underestimating would push text past its cells).
pub fn cpWidth(cp: u21) u2 {
    if (cp < 0x1100) return 1;
    const wide = [_][2]u21{
        .{ 0x1100, 0x115F },   .{ 0x2E80, 0x303E },   .{ 0x3041, 0x33FF },
        .{ 0x3400, 0x4DBF },   .{ 0x4E00, 0x9FFF },   .{ 0xA000, 0xA4CF },
        .{ 0xAC00, 0xD7A3 },   .{ 0xF900, 0xFAFF },   .{ 0xFE30, 0xFE4F },
        .{ 0xFF00, 0xFF60 },   .{ 0xFFE0, 0xFFE6 },   .{ 0x1F300, 0x1F64F },
        .{ 0x1F900, 0x1F9FF }, .{ 0x20000, 0x3FFFD },
    };
    for (wide) |r| if (cp >= r[0] and cp <= r[1]) return 2;
    return 1;
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7f and cp < 0xa0);
}

/// One unit of `s` at `i`: a valid printable code point, or one byte that
/// shows as `?` (invalid UTF-8 or a control character).
const Unit = struct { len: usize, bytes: []const u8, cells: u2 };

fn unitAt(s: []const u8, i: usize) Unit {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return bad;
    if (i + n > s.len) return bad;
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return bad;
    if (isControl(cp)) return .{ .len = n, .bytes = "?", .cells = 1 };
    return .{ .len = n, .bytes = s[i .. i + n], .cells = cpWidth(cp) };
}

const bad: Unit = .{ .len = 1, .bytes = "?", .cells = 1 };

/// The cells `s` takes once cleaned.
pub fn width(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const u = unitAt(s, i);
        i += u.len;
        n += u.cells;
    }
    return n;
}

/// Writes `s` cleaned, at most `max_cells` cells of it (a wide character
/// that doesn't fit is left out). Returns the cells written.
pub fn writeClean(w: *std.Io.Writer, s: []const u8, max_cells: usize) std.Io.Writer.Error!usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const u = unitAt(s, i);
        if (n + u.cells > max_cells) break;
        try w.writeAll(u.bytes);
        i += u.len;
        n += u.cells;
    }
    return n;
}

/// `writeClean` into a fixed writer, stopping (not failing) when it is
/// full, so whatever fits is kept whole.
pub fn writeCleanFit(w: *std.Io.Writer, s: []const u8, max_cells: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const u = unitAt(s, i);
        if (n + u.cells > max_cells or w.unusedCapacityLen() < u.bytes.len) break;
        w.writeAll(u.bytes) catch unreachable; // room checked
        i += u.len;
        n += u.cells;
    }
    return n;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn clean(buf: []u8, s: []const u8, max: usize) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    _ = writeClean(&w, s, max) catch unreachable;
    return w.buffered();
}

test "control characters and bad UTF-8 become ?" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a?[2Jb", clean(&buf, "a\x1b[2Jb", 99));
    try testing.expectEqualStrings("?x?", clean(&buf, "\xffx\xc2", 99));
    // C1 controls (U+009B is a CSI on some terminals).
    try testing.expectEqualStrings("?", clean(&buf, "\u{9b}", 99));
    try testing.expectEqual(6, width("a\x1b[2Jb"));
}

test "wide characters take two cells and are never split" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(6, width("ドラab"));
    try testing.expectEqualStrings("ド", clean(&buf, "ドラ", 3));
    try testing.expectEqualStrings("é·×", clean(&buf, "é·×", 3));
}

test "the plain variant grows an allocating writer" {
    var aw: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 1);
    defer aw.deinit();
    try testing.expectEqual(26, try writeClean(&aw.writer, "Press Ctrl-C again to quit", 99));
    try testing.expectEqualStrings("Press Ctrl-C again to quit", aw.written());
}

test "the fit variant stops when the fixed writer is full" {
    var buf: [6]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectEqual(3, writeCleanFit(&w, "aドラ", 99));
    try testing.expectEqualStrings("aド", w.buffered());
}
