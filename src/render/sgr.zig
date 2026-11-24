//! Small helpers shared by the cell backends: cursor moves, SGR colour with
//! redundant-change elision, changed-run detection, and margin clearing.

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

/// Changed runs separated by at most this many unchanged cells are merged:
/// re-sending a few cells is cheaper than another cursor move.
pub const merge_gap = 2;

/// Iterates the runs `[a, b)` of a row where `new` differs from `old`
/// (`Cell.eql`), merging runs separated by at most `merge_gap` unchanged
/// cells.
pub fn ChangedRuns(comptime Cell: type) type {
    return struct {
        new: []const Cell,
        old: []const Cell,
        x: u32 = 0,

        pub fn next(it: *@This()) ?[2]u32 {
            const n: u32 = @intCast(it.new.len);
            while (it.x < n and it.new[it.x].eql(it.old[it.x])) it.x += 1;
            if (it.x >= n) return null;
            const a = it.x;
            var last = a;
            var j = a + 1;
            // `j - last - 1` unchanged cells lie between `last` and `j`.
            while (j < n and j - last - 1 <= merge_gap) : (j += 1) {
                if (!it.new[j].eql(it.old[j])) last = j;
            }
            it.x = last + 1;
            return .{ a, last + 1 };
        }
    };
}

/// Resets SGR, then erases (ECH, default background) every cell of `rect`
/// outside `box`. `box` may lie partly or wholly outside `rect`.
pub fn clearMargin(w: *std.Io.Writer, rect: Rect, box: Rect) !void {
    try w.writeAll(reset);
    const box_end_col = box.col + box.cols;
    const rect_end_col = rect.col + rect.cols;
    for (rect.row..rect.row + rect.rows) |r_usize| {
        const r: u32 = @intCast(r_usize);
        if (r < box.row or r >= box.row + box.rows or box.cols == 0) {
            try erase(w, r, rect.col, rect.cols);
            continue;
        }
        if (box.col > rect.col) try erase(w, r, rect.col, @min(box.col, rect_end_col) - rect.col);
        if (rect_end_col > box_end_col) {
            const from = @max(box_end_col, rect.col);
            try erase(w, r, from, rect_end_col - from);
        }
    }
}

/// Resets SGR and erases every cell of `rect`.
pub fn clearRect(w: *std.Io.Writer, rect: Rect) !void {
    try clearMargin(w, rect, .{ .col = rect.col, .row = rect.row });
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

test "ChangedRuns merges small gaps" {
    const C = struct {
        v: u8,
        pub fn eql(a: @This(), b: @This()) bool {
            return a.v == b.v;
        }
    };
    const old: [12]C = @splat(.{ .v = 0 });
    var new = old;
    for ([_]usize{ 1, 4, 8, 10 }) |i| new[i].v = 1;
    var it: ChangedRuns(C) = .{ .new = &new, .old = &old };
    // 1 and 4 have 2 unchanged cells between them (merged); 8 has 3 after
    // 4 (new run), and 10 has 1 after 8 (merged).
    try std.testing.expectEqual([2]u32{ 1, 5 }, it.next().?);
    try std.testing.expectEqual([2]u32{ 8, 11 }, it.next().?);
    try std.testing.expectEqual(@as(?[2]u32, null), it.next());
    var none: ChangedRuns(C) = .{ .new = &old, .old = &old };
    try std.testing.expectEqual(@as(?[2]u32, null), none.next());
}

test "clearMargin with no margin only resets" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r: Rect = .{ .cols = 4, .rows = 2 };
    try clearMargin(&w, r, r);
    try std.testing.expectEqualStrings("\x1b[0m", w.buffered());
}
