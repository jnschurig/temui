//! Solid boxes drawn over the image: the leader menu (anchored at the
//! bottom of the image box) and the centered prompts. Every cell, border
//! and padding included, gets a non-default background, so with kitty
//! graphics a box covers the image through item 05's z-index rule (D7).
//!
//!   ┌──────────────────────────────┐
//!   │ Press Ctrl-C again to quit   │
//!   └──────────────────────────────┘

const std = @import("std");
const Rect = @import("../render/layout.zig").Rect;
const sgr = @import("../render/sgr.zig");
const text = @import("text.zig");

pub const Anchor = enum { center, bottom };

/// Below this, `layout` gives up and the text belongs on the status line.
pub const min_cols = 20;
pub const min_rows = 3;

/// A border cell and a space of padding on each side.
const frame_cols = 4;
const frame_rows = 2;

/// Where a box for `lines` goes within `within`, clipped to it. Null when
/// `within` is narrower than `min_cols` or shorter than `min_rows`, or
/// there are no lines.
pub fn layout(lines: []const []const u8, anchor: Anchor, within: Rect) ?Rect {
    if (lines.len == 0 or within.cols < min_cols or within.rows < min_rows) return null;
    var widest: usize = 0;
    for (lines) |l| widest = @max(widest, text.width(l));
    const cols: u32 = @intCast(@min(widest + frame_cols, within.cols));
    const rows: u32 = @intCast(@min(lines.len + frame_rows, within.rows));
    return .{
        .col = within.col + (within.cols - cols) / 2,
        .row = switch (anchor) {
            .center => within.row + (within.rows - rows) / 2,
            .bottom => within.row + within.rows - rows,
        },
        .cols = cols,
        .rows = rows,
    };
}

/// The box's colours: reverse video on basic-colour terminals, else
/// light grey on dark grey (as item 05's overlay).
pub fn style(basic_color: bool) []const u8 {
    return if (basic_color) "\x1b[0;7m" else "\x1b[0;38;5;252;48;5;236m";
}

/// Draws the box at `rect` (from `layout`): lines past the box are left
/// out and long ones cut. Ends with SGR reset.
pub fn draw(w: *std.Io.Writer, rect: Rect, lines: []const []const u8, basic_color: bool) !void {
    std.debug.assert(rect.cols >= frame_cols and rect.rows >= frame_rows);
    const inner = rect.cols - frame_cols;
    try w.writeAll(style(basic_color));
    for (0..rect.rows) |r| {
        try sgr.cup(w, rect.row + @as(u32, @intCast(r)), rect.col);
        if (r == 0 or r == rect.rows - 1) {
            try w.writeAll(if (r == 0) "┌" else "└");
            for (0..rect.cols - 2) |_| try w.writeAll("─");
            try w.writeAll(if (r == 0) "┐" else "┘");
            continue;
        }
        try w.writeAll("│ ");
        const l = if (r - 1 < lines.len) lines[r - 1] else "";
        var n = try text.writeClean(w, l, inner);
        while (n < inner) : (n += 1) try w.writeByte(' ');
        try w.writeAll(" │");
    }
    try w.writeAll(sgr.reset);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const TestScreen = @import("TestScreen.zig");

const ctrl_c = [_][]const u8{"Press Ctrl-C again to quit"};
const image: Rect = .{ .col = 5, .row = 2, .cols = 60, .rows = 20 };

test "layout: centered and bottom-anchored" {
    try testing.expectEqual(Rect{ .col = 20, .row = 10, .cols = 30, .rows = 3 }, layout(&ctrl_c, .center, image).?);
    try testing.expectEqual(Rect{ .col = 20, .row = 19, .cols = 30, .rows = 3 }, layout(&ctrl_c, .bottom, image).?);
}

test "layout: clipped to the image box" {
    const small: Rect = .{ .col = 3, .row = 4, .cols = 22, .rows = 3 };
    const many = [_][]const u8{ "a", "b", "c", "d" };
    try testing.expectEqual(Rect{ .col = 3, .row = 4, .cols = 22, .rows = 3 }, layout(&ctrl_c, .center, small).?);
    try testing.expectEqual(Rect{ .col = 11, .row = 4, .cols = 5, .rows = 3 }, layout(&many, .center, small).?);
}

test "layout: skipped when the space is too small" {
    try testing.expectEqual(null, layout(&ctrl_c, .center, .{ .cols = 19, .rows = 10 }));
    try testing.expectEqual(null, layout(&ctrl_c, .center, .{ .cols = 80, .rows = 2 }));
    try testing.expectEqual(null, layout(&.{}, .center, image));
    // A box smaller than the minimum is fine when the space isn't.
    try testing.expect(layout(&.{"q  quit"}, .bottom, .{ .cols = 20, .rows = 3 }) != null);
}

fn drawOn(screen: *TestScreen, rect: Rect, lines: []const []const u8, basic: bool) !void {
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try draw(&w, rect, lines, basic);
    try screen.feed(w.buffered());
}

fn expectSolid(screen: *const TestScreen, rect: Rect) !void {
    for (rect.row..rect.row + rect.rows) |r| for (rect.col..rect.col + rect.cols) |c| {
        if (!screen.at(@intCast(r), @intCast(c)).bg) {
            std.debug.print("cell {d},{d} has the default background\n", .{ r, c });
            return error.TestUnexpectedResult;
        }
    };
}

test "drawn solid, border and padding included" {
    for ([_]bool{ false, true }) |basic| {
        var screen: TestScreen = .init(70, 24);
        const lines = [_][]const u8{ "Quit?", "", "Enter to confirm, any other key cancels" };
        const rect = layout(&lines, .center, image).?;
        try drawOn(&screen, rect, &lines, basic);
        try expectSolid(&screen, rect);
        // Nothing outside it.
        try testing.expect(!screen.at(rect.row - 1, rect.col).bg);
        try testing.expect(!screen.at(rect.row, rect.col + rect.cols).bg);
        try testing.expect(!screen.at(rect.row + rect.rows, rect.col).bg);

        var buf: [512]u8 = undefined;
        try testing.expectEqualStrings("┌─────────────────────────────────────────┐", trimmed(screen.line(&buf, rect.row), rect));
        try testing.expectEqualStrings("│ Quit?                                   │", trimmed(screen.line(&buf, rect.row + 1), rect));
        try testing.expectEqualStrings("│                                         │", trimmed(screen.line(&buf, rect.row + 2), rect));
        try testing.expectEqualStrings("│ Enter to confirm, any other key cancels │", trimmed(screen.line(&buf, rect.row + 3), rect));
        try testing.expectEqualStrings("└─────────────────────────────────────────┘", trimmed(screen.line(&buf, rect.row + 4), rect));
    }
}

test "clipped: long lines cut, extra lines dropped, still solid" {
    var screen: TestScreen = .init(30, 10);
    const within: Rect = .{ .col = 2, .row = 2, .cols = 20, .rows = 4 };
    const lines = [_][]const u8{ "a line much longer than the box", "two", "three", "four" };
    const rect = layout(&lines, .center, within).?;
    try testing.expectEqual(Rect{ .col = 2, .row = 2, .cols = 20, .rows = 4 }, rect);
    try drawOn(&screen, rect, &lines, false);
    try expectSolid(&screen, rect);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("│ a line much long │", trimmed(screen.line(&buf, 3), rect));
    try testing.expectEqualStrings("│ two              │", trimmed(screen.line(&buf, 4), rect));
    try testing.expectEqualStrings("└──────────────────┘", trimmed(screen.line(&buf, 5), rect));
}

/// The part of a screen line inside `rect`'s columns.
fn trimmed(line: []const u8, rect: Rect) []const u8 {
    var it: std.unicode.Utf8Iterator = .{ .bytes = line, .i = 0 };
    var c: u32 = 1;
    while (c < rect.col) : (c += 1) _ = it.nextCodepointSlice();
    const start = it.i;
    while (c < rect.col + rect.cols) : (c += 1) _ = it.nextCodepointSlice();
    return line[start..it.i];
}
