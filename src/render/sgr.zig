//! Small escape-sequence helpers shared by the cell backends: cursor moves,
//! SGR colour with redundant-change elision, and margin clearing.

const std = @import("std");
const Rect = @import("layout.zig").Rect;

pub const Rgb = [3]u8;

pub const reset = "\x1b[0m";

/// CUP: move to 1-based `row`, `col`.
pub fn cup(w: *std.Io.Writer, row: u32, col: u32) !void {
    try w.print("\x1b[{d};{d}H", .{ row, col });
}

/// Truecolor pen: remembers the colours last sent so unchanged ones are
/// skipped. A zeroed pen (`.{}`) knows nothing and sends everything.
pub const Pen = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,

    pub fn fgIs(p: Pen, c: Rgb) bool {
        return p.fg != null and std.mem.eql(u8, &p.fg.?, &c);
    }

    pub fn bgIs(p: Pen, c: Rgb) bool {
        return p.bg != null and std.mem.eql(u8, &p.bg.?, &c);
    }

    /// Sets fg and/or bg (null: leave as is); writes one SGR for whatever
    /// actually changes, or nothing.
    pub fn set(p: *Pen, w: *std.Io.Writer, fg: ?Rgb, bg: ?Rgb) !void {
        const do_fg = if (fg) |c| !p.fgIs(c) else false;
        const do_bg = if (bg) |c| !p.bgIs(c) else false;
        if (!do_fg and !do_bg) return;
        try w.writeAll("\x1b[");
        if (do_fg) {
            const c = fg.?;
            try w.print("38;2;{d};{d};{d}", .{ c[0], c[1], c[2] });
            p.fg = c;
        }
        if (do_bg) {
            const c = bg.?;
            if (do_fg) try w.writeByte(';');
            try w.print("48;2;{d};{d};{d}", .{ c[0], c[1], c[2] });
            p.bg = c;
        }
        try w.writeByte('m');
    }
};

/// Resets SGR, then erases (ECH, default background) every cell of `rect`
/// outside `box`. `box` must lie inside `rect`.
pub fn clearMargin(w: *std.Io.Writer, rect: Rect, box: Rect) !void {
    try w.writeAll(reset);
    const box_end_col = box.col + box.cols;
    const rect_end_col = rect.col + rect.cols;
    for (rect.row..rect.row + rect.rows) |r_usize| {
        const r: u32 = @intCast(r_usize);
        if (r < box.row or r >= box.row + box.rows) {
            try erase(w, r, rect.col, rect.cols);
            continue;
        }
        if (box.col > rect.col) try erase(w, r, rect.col, box.col - rect.col);
        if (rect_end_col > box_end_col) try erase(w, r, box_end_col, rect_end_col - box_end_col);
    }
}

fn erase(w: *std.Io.Writer, row: u32, col: u32, n: u32) !void {
    try cup(w, row, col);
    try w.print("\x1b[{d}X", .{n});
}

test "pen elides unchanged colours" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var p: Pen = .{};
    try p.set(&w, .{ 1, 2, 3 }, .{ 4, 5, 6 });
    try p.set(&w, .{ 1, 2, 3 }, .{ 4, 5, 6 });
    try p.set(&w, .{ 1, 2, 3 }, .{ 7, 8, 9 });
    try p.set(&w, null, null);
    try std.testing.expectEqualStrings("\x1b[38;2;1;2;3;48;2;4;5;6m\x1b[48;2;7;8;9m", w.buffered());
}

test "clearMargin erases around the box" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try clearMargin(&w, .{ .col = 1, .row = 1, .cols = 10, .rows = 3 }, .{ .col = 3, .row = 2, .cols = 5, .rows = 1 });
    try std.testing.expectEqualStrings("\x1b[0m" ++
        "\x1b[1;1H\x1b[10X" ++
        "\x1b[2;1H\x1b[2X\x1b[2;8H\x1b[3X" ++
        "\x1b[3;1H\x1b[10X", w.buffered());
}

test "clearMargin with no margin only resets" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r: Rect = .{ .cols = 4, .rows = 2 };
    try clearMargin(&w, r, r);
    try std.testing.expectEqualStrings("\x1b[0m", w.buffered());
}
