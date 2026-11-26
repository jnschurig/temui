//! Half-block truecolor backend (D7): each cell shows two vertically stacked
//! pixels, `▀` with fg = top and bg = bottom. The frame is area-averaged to
//! the fitted box (cols × 2·rows pixels). Only cells that changed since the
//! last `present` are redrawn; the first frame and any rect, box or cell-size
//! change redraw everything and clear the margin.

const std = @import("std");
const layout = @import("layout.zig");
const sgr = @import("sgr.zig");
const CellPx = @import("../term/caps.zig").CellPx;

const Rect = layout.Rect;
const Frame = layout.Frame;
const Rgb = sgr.Rgb;

const Cell = struct {
    top: Rgb,
    bot: Rgb,

    pub fn eql(a: Cell, b: Cell) bool {
        return std.mem.eql(u8, &a.top, &b.top) and std.mem.eql(u8, &a.bot, &b.bot);
    }
};

pub const HalfBlock = struct {
    gpa: std.mem.Allocator,
    cell_px: CellPx,
    resampler: layout.Resampler,
    /// Sampled pixels, `box.cols × 2·box.rows × 3`.
    pixels: []u8 = &.{},
    cur: []Cell = &.{},
    prev: []Cell = &.{},
    /// The rect, fitted box and occluded cells of the previous `present`;
    /// null forces a full redraw.
    last: ?struct { rect: Rect, box: Rect, occlude: ?Rect } = null,
    pen: sgr.Pen = .{},

    pub fn init(gpa: std.mem.Allocator, cell_px: CellPx) HalfBlock {
        return .{ .gpa = gpa, .cell_px = cell_px, .resampler = .init(gpa) };
    }

    pub fn deinit(hb: *HalfBlock) void {
        hb.resampler.deinit();
        hb.gpa.free(hb.pixels);
        hb.gpa.free(hb.cur);
        hb.gpa.free(hb.prev);
        hb.* = undefined;
    }

    /// Forget what is on screen: the next `present` redraws everything.
    pub fn invalidate(hb: *HalfBlock) void {
        hb.last = null;
    }

    pub fn setCellPx(hb: *HalfBlock, cell_px: CellPx) void {
        hb.cell_px = cell_px;
        hb.invalidate();
    }

    /// Draws `frame` into `rect`, letterboxed to `aspect` (default: the
    /// frame's own width / height). Cells of the box inside `occlude` are
    /// left alone (an overlay is drawn there); cells it covered last time and
    /// no longer does are redrawn even if unchanged. An empty frame or rect
    /// draws nothing.
    pub fn present(hb: *HalfBlock, w: *std.Io.Writer, frame: Frame, rect: Rect, aspect: ?f32, occlude: ?Rect) !void {
        if (frame.isEmpty() or rect.isEmpty()) return;
        const box = layout.fit(rect, hb.cell_px, aspect orelse frame.aspect());
        if (box.isEmpty()) return;

        const last = hb.last;
        // Set again only on success: after any error the next present
        // redraws everything.
        hb.last = null;
        const full = if (last) |l| !std.meta.eql(l.rect, rect) or !std.meta.eql(l.box, box) else true;
        const n = @as(usize, box.cols) * box.rows;
        if (full) try hb.resize(n, box);

        try hb.resampler.sample(frame.rgb, @intCast(frame.width), @intCast(frame.height), hb.pixels, box.cols, box.rows * 2);
        const stride = @as(usize, box.cols) * 3;
        for (0..box.rows) |y| {
            const top = hb.pixels[(2 * y) * stride ..][0..stride];
            const bot = hb.pixels[(2 * y + 1) * stride ..][0..stride];
            for (hb.cur[y * box.cols ..][0..box.cols], 0..) |*c, x| {
                c.* = .{ .top = top[x * 3 ..][0..3].*, .bot = bot[x * 3 ..][0..3].* };
            }
        }

        hb.pen = .{};
        var wrote = full;
        if (full) {
            // The previous rect's cells outside the new one, then the margin.
            if (last) |l| if (!std.meta.eql(l.rect, rect)) try sgr.clearMargin(w, l.rect, rect);
            try sgr.clearMargin(w, rect, box);
        }
        for (0..box.rows) |yi| {
            const y: u32 = @intCast(yi);
            const row = hb.cur[yi * box.cols ..][0..box.cols];
            var runs: sgr.ChangedRuns(Cell) = .{
                .new = row,
                .old = hb.prev[yi * box.cols ..][0..box.cols],
                .force = if (full) .{ 0, box.cols } else sgr.rowSpan(last.?.occlude, box, box.row + y),
                .skip = sgr.rowSpan(occlude, box, box.row + y),
            };
            while (runs.next()) |r| {
                try hb.emitRun(w, box, y, row, r[0], r[1]);
                wrote = true;
            }
        }
        if (wrote) try w.writeAll(sgr.reset);
        std.mem.swap([]Cell, &hb.cur, &hb.prev);
        hb.last = .{ .rect = rect, .box = box, .occlude = occlude };
    }

    fn resize(hb: *HalfBlock, n: usize, box: Rect) !void {
        if (hb.cur.len != n or hb.prev.len != n) {
            hb.gpa.free(hb.cur);
            hb.cur = &.{};
            hb.gpa.free(hb.prev);
            hb.prev = &.{};
            hb.cur = try hb.gpa.alloc(Cell, n);
            hb.prev = try hb.gpa.alloc(Cell, n);
        }
        const px_len = @as(usize, box.cols) * box.rows * 2 * 3;
        if (hb.pixels.len != px_len) {
            hb.gpa.free(hb.pixels);
            hb.pixels = &.{};
            hb.pixels = try hb.gpa.alloc(u8, px_len);
        }
    }

    fn emitRun(hb: *HalfBlock, w: *std.Io.Writer, box: Rect, y: u32, row: []const Cell, a: u32, b: u32) !void {
        try sgr.cup(w, box.row + y, box.col + a);
        for (row[a..b]) |cell| {
            if (std.mem.eql(u8, &cell.top, &cell.bot)) {
                // One colour: a space on the current bg, or a full block on
                // the current fg, or set bg and space.
                if (hb.pen.bgIs(cell.bot)) {
                    try w.writeByte(' ');
                } else if (hb.pen.fgIs(cell.top)) {
                    try w.writeAll("█");
                } else {
                    try hb.pen.set(w, null, cell.bot);
                    try w.writeByte(' ');
                }
                continue;
            }
            try hb.pen.set(w, cell.top, cell.bot);
            try w.writeAll("▀");
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const golden = @import("golden.zig");

fn render(hb: *HalfBlock, frame: Frame, rect: Rect) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try hb.present(&aw.writer, frame, rect, null, null);
    return aw.toOwnedSlice();
}

test "tiny frame: exact bytes, then an unchanged frame writes nothing" {
    const A = [3]u8{ 1, 2, 3 };
    const B = [3]u8{ 40, 50, 60 };
    const C = [3]u8{ 200, 0, 9 };
    // A 2×2 image fills a 2×1 rect of 10×20 px cells exactly (2×2 sub-pixels).
    // Cell 0 = A over C (▀); cell 1 = B over B (one colour: bg + space).
    const px = A ++ B ++ C ++ B;
    var hb: HalfBlock = .init(testing.allocator, .{ .w = 10, .h = 20 });
    defer hb.deinit();
    const frame: Frame = .{ .width = 2, .height = 2, .rgb = &px };
    const out = try render(&hb, frame, .{ .col = 3, .row = 5, .cols = 2, .rows = 1 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[0m\x1b[5;3H\x1b[38;2;1;2;3;48;2;200;0;9m▀\x1b[48;2;40;50;60m \x1b[0m", out);
    const again = try render(&hb, frame, .{ .col = 3, .row = 5, .cols = 2, .rows = 1 });
    defer testing.allocator.free(again);
    try testing.expectEqualStrings("", again);
}

test "golden: test-core frame 60, 80×24 at 10×20 px cells" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    var hb: HalfBlock = .init(testing.allocator, golden.cell_px);
    defer hb.deinit();
    const out = try render(&hb, frame, golden.rect);
    defer testing.allocator.free(out);
    try golden.check("render-halfblock-80x24.bin", out);
}

test "changed cells: a shifted bar redraws one column only" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    var hb: HalfBlock = .init(testing.allocator, golden.cell_px);
    defer hb.deinit();
    testing.allocator.free(try render(&hb, frame, golden.rect));

    // Invert source columns 100–101 on every row. The fitted box is 55
    // cols at col 13; target column 21 covers source x ∈ [97.7, 102.4), so
    // only cell column 13 + 21 = 34 changes, on all 24 rows.
    const moved = try testing.allocator.dupe(u8, frame.rgb);
    defer testing.allocator.free(moved);
    for (0..frame.height) |y| for (100..102) |x| for (0..3) |k| {
        moved[(y * frame.width + x) * 3 + k] ^= 0xff;
    };
    const out = try render(&hb, .{ .width = frame.width, .height = frame.height, .rgb = moved }, golden.rect);
    defer testing.allocator.free(out);
    const g = try golden.scan(out);
    try testing.expectEqual(@as(usize, 24), g.glyphs);
    try testing.expectEqual(@as(usize, 24), g.cups);
    try testing.expectEqual(@as(?u32, 34), g.only_col);
}

test "empty frame or rect writes nothing" {
    var hb: HalfBlock = .init(testing.allocator, golden.cell_px);
    defer hb.deinit();
    const px = [_]u8{ 1, 2, 3 };
    const empty = try render(&hb, .{ .width = 0, .height = 0, .rgb = &.{} }, golden.rect);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
    const no_rect = try render(&hb, .{ .width = 1, .height = 1, .rgb = &px }, .{ .cols = 0, .rows = 5 });
    defer testing.allocator.free(no_rect);
    try testing.expectEqualStrings("", no_rect);
}

test "moving or shrinking the rect erases the old rect's uncovered cells" {
    const px: [12]u8 = @splat(9);
    var hb: HalfBlock = .init(testing.allocator, .{ .w = 10, .h = 20 });
    defer hb.deinit();
    const frame: Frame = .{ .width = 2, .height = 2, .rgb = &px };
    testing.allocator.free(try render(&hb, frame, .{ .col = 3, .row = 5, .cols = 2, .rows = 1 }));
    // One column right: old column 3 is erased.
    const moved = try render(&hb, frame, .{ .col = 4, .row = 5, .cols = 2, .rows = 1 });
    defer testing.allocator.free(moved);
    try testing.expect(std.mem.startsWith(u8, moved, "\x1b[0m\x1b[5;3H\x1b[1X"));
    // One row shorter (room for a status line): old row 24 is erased.
    const g = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(g.rgb);
    testing.allocator.free(try render(&hb, g, golden.rect));
    const short = try render(&hb, g, .{ .col = 1, .row = 1, .cols = 80, .rows = 23 });
    defer testing.allocator.free(short);
    try testing.expect(std.mem.startsWith(u8, short, "\x1b[0m\x1b[24;1H\x1b[80X"));
}

test "a present that runs out of memory leaves a state the next one recovers from" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    const small: Rect = .{ .col = 1, .row = 1, .cols = 20, .rows = 6 };
    for (0..12) |k| {
        var fa: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var hb: HalfBlock = .init(fa.allocator(), golden.cell_px);
        defer hb.deinit();
        testing.allocator.free(try render(&hb, frame, small));
        fa.fail_index = fa.alloc_index + k;
        if (render(&hb, frame, golden.rect)) |out| testing.allocator.free(out) else |err| try testing.expectEqual(error.OutOfMemory, err);
        fa.fail_index = std.math.maxInt(usize);
        testing.allocator.free(try render(&hb, frame, small));
        const again = try render(&hb, frame, small);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings("", again);
    }
}

test "rect change and setCellPx force a full redraw" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    var hb: HalfBlock = .init(testing.allocator, golden.cell_px);
    defer hb.deinit();
    testing.allocator.free(try render(&hb, frame, golden.rect));
    const moved = try render(&hb, frame, .{ .col = 2, .row = 1, .cols = 80, .rows = 24 });
    defer testing.allocator.free(moved);
    try testing.expectEqual(@as(usize, 55 * 24), (try golden.scan(moved)).glyphs);
    hb.setCellPx(golden.cell_px);
    const after = try render(&hb, frame, .{ .col = 2, .row = 1, .cols = 80, .rows = 24 });
    defer testing.allocator.free(after);
    try testing.expectEqual(@as(usize, 55 * 24), (try golden.scan(after)).glyphs);
}
