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

/// A column range `[a, b)` within a row; empty when `a >= b`.
pub const Span = [2]u32;
pub const no_span: Span = .{ 0, 0 };

fn inSpan(s: Span, i: u32) bool {
    return i >= s[0] and i < s[1];
}

/// The most occluding rects a present takes (the leader menu and a
/// centered box, with room to spare).
pub const max_occlusions = 4;

/// Up to `max_occlusions` spans of one row; they may overlap.
pub const SpanSet = struct {
    spans: [max_occlusions]Span = undefined,
    len: u8 = 0,

    pub const empty: SpanSet = .{};

    pub fn one(s: Span) SpanSet {
        var set: SpanSet = .{};
        set.add(s);
        return set;
    }

    /// The columns of `box` row `row` that `rects` cover, relative to
    /// `box.col` (see `rowSpan`).
    pub fn ofRow(rects: []const Rect, box: Rect, row: u32) SpanSet {
        std.debug.assert(rects.len <= max_occlusions);
        var set: SpanSet = .{};
        for (rects) |r| set.add(rowSpan(r, box, row));
        return set;
    }

    /// Adds `s`; empty spans are dropped.
    pub fn add(set: *SpanSet, s: Span) void {
        if (s[0] >= s[1]) return;
        std.debug.assert(set.len < max_occlusions);
        set.spans[set.len] = s;
        set.len += 1;
    }

    pub fn contains(set: *const SpanSet, i: u32) bool {
        for (set.spans[0..set.len]) |s| if (inSpan(s, i)) return true;
        return false;
    }
};

/// A copy of up to `max_occlusions` rects, kept between presents.
pub const Occlusion = struct {
    buf: [max_occlusions]Rect = undefined,
    len: u8 = 0,

    pub fn init(rects: []const Rect) Occlusion {
        std.debug.assert(rects.len <= max_occlusions);
        var o: Occlusion = .{ .len = @intCast(rects.len) };
        @memcpy(o.buf[0..rects.len], rects);
        return o;
    }

    pub fn slice(o: *const Occlusion) []const Rect {
        return o.buf[0..o.len];
    }
};

/// Iterates the runs `[a, b)` of a row where `new` differs from `old`
/// (`Cell.eql`), merging runs separated by at most `merge_gap` unchanged
/// cells. Cells in `force` count as changed (a full redraw forces the whole
/// row); cells in `skip` never do, and no run crosses them (they are under
/// a box the caller draws).
pub fn ChangedRuns(comptime Cell: type) type {
    return struct {
        new: []const Cell,
        old: []const Cell,
        force: SpanSet = .empty,
        skip: SpanSet = .empty,
        x: u32 = 0,

        fn changed(it: *const @This(), i: u32) bool {
            if (it.skip.contains(i)) return false;
            return it.force.contains(i) or !it.new[i].eql(it.old[i]);
        }

        pub fn next(it: *@This()) ?[2]u32 {
            const n: u32 = @intCast(it.new.len);
            while (it.x < n and !it.changed(it.x)) it.x += 1;
            if (it.x >= n) return null;
            const a = it.x;
            var last = a;
            var j = a + 1;
            // `j - last - 1` unchanged cells lie between `last` and `j`.
            while (j < n and j - last - 1 <= merge_gap and !it.skip.contains(j)) : (j += 1) {
                if (it.changed(j)) last = j;
            }
            it.x = last + 1;
            return .{ a, last + 1 };
        }
    };
}

/// The columns of `box` row `row` (absolute, 1-based) that `r` covers, as a
/// span relative to `box.col`; `no_span` when `r` misses the row.
pub fn rowSpan(o: Rect, box: Rect, row: u32) Span {
    if (row < o.row or row >= o.row + o.rows) return no_span;
    const a = @max(o.col, box.col);
    const b = @min(o.col + o.cols, box.col + box.cols);
    if (a >= b) return no_span;
    return .{ a - box.col, b - box.col };
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

test "ChangedRuns: force redraws equal cells, skip is never drawn or bridged" {
    const C = struct {
        v: u8,
        pub fn eql(a: @This(), b: @This()) bool {
            return a.v == b.v;
        }
    };
    const old: [12]C = @splat(.{ .v = 0 });
    var new = old;
    new[5].v = 1;
    new[7].v = 1;
    // A forced whole row with cells 4..6 skipped splits around them.
    var full: ChangedRuns(C) = .{ .new = &new, .old = &old, .force = .one(.{ 0, 12 }), .skip = .one(.{ 4, 6 }) };
    try std.testing.expectEqual([2]u32{ 0, 4 }, full.next().?);
    try std.testing.expectEqual([2]u32{ 6, 12 }, full.next().?);
    try std.testing.expectEqual(@as(?[2]u32, null), full.next());
    // Changed cells 5 and 7 with 6 skipped: 5 is hidden, 7 drawn alone (the
    // gap merge would otherwise bridge 6).
    var skip: ChangedRuns(C) = .{ .new = &new, .old = &old, .skip = .one(.{ 5, 7 }) };
    try std.testing.expectEqual([2]u32{ 7, 8 }, skip.next().?);
    try std.testing.expectEqual(@as(?[2]u32, null), skip.next());
    // Uncovered cells 0..2 forced; merged with changed 5 across the gap.
    var force: ChangedRuns(C) = .{ .new = &new, .old = &old, .force = .one(.{ 0, 2 }) };
    try std.testing.expectEqual([2]u32{ 0, 2 }, force.next().?);
    try std.testing.expectEqual([2]u32{ 5, 8 }, force.next().?);
}

test "ChangedRuns: several skipped and forced spans" {
    const C = struct {
        v: u8,
        pub fn eql(a: @This(), b: @This()) bool {
            return a.v == b.v;
        }
    };
    const old: [16]C = @splat(.{ .v = 0 });
    var new = old;
    for (&new) |*c| c.v = 1;
    // Every cell changed; two disjoint skips split the row in three, and
    // an overlapping pair acts as their union.
    var skip: SpanSet = .{};
    skip.add(.{ 2, 4 });
    skip.add(.{ 9, 11 });
    skip.add(.{ 10, 12 });
    var it: ChangedRuns(C) = .{ .new = &new, .old = &old, .skip = skip };
    try std.testing.expectEqual([2]u32{ 0, 2 }, it.next().?);
    try std.testing.expectEqual([2]u32{ 4, 9 }, it.next().?);
    try std.testing.expectEqual([2]u32{ 12, 16 }, it.next().?);
    try std.testing.expectEqual(@as(?[2]u32, null), it.next());
    // Unchanged row: only the forced spans, each its own run.
    var force: SpanSet = .{};
    force.add(.{ 0, 1 });
    force.add(.{ 8, 10 });
    force.add(.{ 5, 5 }); // empty: dropped
    try std.testing.expectEqual(2, force.len);
    var f: ChangedRuns(C) = .{ .new = &old, .old = &old, .force = force };
    try std.testing.expectEqual([2]u32{ 0, 1 }, f.next().?);
    try std.testing.expectEqual([2]u32{ 8, 10 }, f.next().?);
    try std.testing.expectEqual(@as(?[2]u32, null), f.next());
}

test "SpanSet.ofRow keeps only the rects on the row" {
    const box: Rect = .{ .col = 11, .row = 3, .cols = 20, .rows = 5 };
    const rects = [_]Rect{
        .{ .col = 11, .row = 3, .cols = 4, .rows = 2 },
        .{ .col = 20, .row = 4, .cols = 3, .rows = 1 },
        .{ .col = 40, .row = 3, .cols = 3, .rows = 1 }, // outside the box
    };
    const r3 = SpanSet.ofRow(&rects, box, 3);
    try std.testing.expectEqual(1, r3.len);
    try std.testing.expectEqual(Span{ 0, 4 }, r3.spans[0]);
    const r4 = SpanSet.ofRow(&rects, box, 4);
    try std.testing.expectEqual(2, r4.len);
    try std.testing.expect(r4.contains(0) and r4.contains(9) and !r4.contains(5));
    try std.testing.expectEqual(0, SpanSet.ofRow(&rects, box, 5).len);
    try std.testing.expectEqual(0, SpanSet.ofRow(&.{}, box, 3).len);
}

test "rowSpan clips to the box" {
    const box: Rect = .{ .col = 11, .row = 3, .cols = 20, .rows = 5 };
    const o: Rect = .{ .col = 11, .row = 3, .cols = 8, .rows = 1 };
    try std.testing.expectEqual(Span{ 0, 8 }, rowSpan(o, box, 3));
    try std.testing.expectEqual(no_span, rowSpan(o, box, 4));
    // Partly left of and past the right edge of the box.
    try std.testing.expectEqual(Span{ 0, 4 }, rowSpan(.{ .col = 5, .row = 3, .cols = 10, .rows = 1 }, box, 3));
    try std.testing.expectEqual(Span{ 15, 20 }, rowSpan(.{ .col = 26, .row = 3, .cols = 50, .rows = 1 }, box, 3));
    try std.testing.expectEqual(no_span, rowSpan(.{ .col = 40, .row = 3, .cols = 5, .rows = 1 }, box, 3));
}

test "clearMargin with no margin only resets" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r: Rect = .{ .cols = 4, .rows = 2 };
    try clearMargin(&w, r, r);
    try std.testing.expectEqualStrings("\x1b[0m", w.buffered());
}
