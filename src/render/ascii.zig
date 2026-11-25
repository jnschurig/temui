//! ASCII backend (D7): one character per cell, picked from a brightness ramp
//! by the luma of the area-averaged colour, optionally coloured (truecolor or
//! 256-colour fg). The frame is sampled at one pixel per cell of the fitted
//! box; `fit` already accounts for cells being taller than wide. Only cells
//! that changed since the last `present` are redrawn; the first frame and any
//! rect, box or cell-size change redraw everything and clear the margin.

const std = @import("std");
const layout = @import("layout.zig");
const sgr = @import("sgr.zig");
const caps = @import("../term/caps.zig");

const Rect = layout.Rect;
const Frame = layout.Frame;
const Rgb = sgr.Rgb;
const CellPx = caps.CellPx;
pub const Color = caps.AsciiColor;

/// Darkest to brightest, 10 steps.
pub const ramp = " .:-=+*#%@";

const Cell = struct {
    ch: u8,
    /// The fg as sent: `0xRRGGBB` (truecolor), a palette index (256), or 0
    /// (no colour, or a space, whose fg is invisible).
    fg: u32,

    pub fn eql(a: Cell, b: Cell) bool {
        return a.ch == b.ch and a.fg == b.fg;
    }
};

/// Rec. 709 luma, 0–255.
pub fn luma(c: Rgb) u8 {
    const y = 2126 * @as(u32, c[0]) + 7152 * @as(u32, c[1]) + 722 * @as(u32, c[2]);
    return @intCast((y + 5000) / 10000);
}

pub fn rampChar(c: Rgb) u8 {
    return ramp[@as(usize, luma(c)) * ramp.len / 256];
}

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// Nearest xterm 256-colour palette entry: the 6×6×6 cube (16–231) or the
/// grey ramp (232–255), by squared RGB distance; ties go to the cube.
pub fn ansi256(c: Rgb) u8 {
    var cube: [3]u8 = undefined;
    var cube_rgb: Rgb = undefined;
    for (c, 0..) |v, k| {
        const i: u8 = if (v < 48) 0 else if (v < 115) 1 else (v - 35) / 40;
        cube[k] = i;
        cube_rgb[k] = cube_levels[i];
    }
    const avg: u32 = (@as(u32, c[0]) + c[1] + c[2]) / 3;
    const gi: u8 = if (avg < 8) 0 else @intCast(@min(23, (avg - 3) / 10));
    const gv: u8 = 8 + 10 * gi;
    if (dist2(c, .{ gv, gv, gv }) < dist2(c, cube_rgb)) return 232 + gi;
    return 16 + 36 * cube[0] + 6 * cube[1] + cube[2];
}

fn dist2(a: Rgb, b: Rgb) u32 {
    var d: u32 = 0;
    for (a, b) |x, y| {
        const e = @as(i32, x) - y;
        d += @intCast(e * e);
    }
    return d;
}

pub const Ascii = struct {
    gpa: std.mem.Allocator,
    cell_px: CellPx,
    color: Color,
    resampler: layout.Resampler,
    /// Sampled pixels, `box.cols × box.rows × 3`.
    pixels: []u8 = &.{},
    cur: []Cell = &.{},
    prev: []Cell = &.{},
    /// The rect, fitted box and occluded cells of the previous `present`;
    /// null forces a full redraw.
    last: ?struct { rect: Rect, box: Rect, occlude: ?Rect } = null,
    /// The fg last sent in this `present` (as in `Cell.fg`); null: unknown.
    pen: ?u32 = null,

    pub fn init(gpa: std.mem.Allocator, cell_px: CellPx, color: Color) Ascii {
        return .{ .gpa = gpa, .cell_px = cell_px, .color = color, .resampler = .init(gpa) };
    }

    pub fn deinit(a: *Ascii) void {
        a.resampler.deinit();
        a.gpa.free(a.pixels);
        a.gpa.free(a.cur);
        a.gpa.free(a.prev);
        a.* = undefined;
    }

    /// Forget what is on screen: the next `present` redraws everything.
    pub fn invalidate(a: *Ascii) void {
        a.last = null;
    }

    pub fn setCellPx(a: *Ascii, cell_px: CellPx) void {
        a.cell_px = cell_px;
        a.invalidate();
    }

    /// Draws `frame` into `rect`, letterboxed to `aspect` (default: the
    /// frame's own width / height). Cells of the box inside `occlude` are
    /// left alone (an overlay is drawn there); cells it covered last time and
    /// no longer does are redrawn even if unchanged. An empty frame or rect
    /// draws nothing.
    pub fn present(a: *Ascii, w: *std.Io.Writer, frame: Frame, rect: Rect, aspect: ?f32, occlude: ?Rect) !void {
        if (frame.isEmpty() or rect.isEmpty()) return;
        const box = layout.fit(rect, a.cell_px, aspect orelse frame.aspect());
        if (box.isEmpty()) return;

        const last = a.last;
        // Set again only on success: after any error the next present
        // redraws everything.
        a.last = null;
        const full = if (last) |l| !std.meta.eql(l.rect, rect) or !std.meta.eql(l.box, box) else true;
        if (full) try a.resize(box);

        try a.resampler.sample(frame.rgb, @intCast(frame.width), @intCast(frame.height), a.pixels, box.cols, box.rows);
        for (a.cur, 0..) |*c, i| c.* = a.cell(a.pixels[i * 3 ..][0..3].*);

        a.pen = null;
        var wrote = full;
        if (full) {
            // The previous rect's cells outside the new one, then the margin.
            if (last) |l| if (!std.meta.eql(l.rect, rect)) try sgr.clearMargin(w, l.rect, rect);
            try sgr.clearMargin(w, rect, box);
        }
        for (0..box.rows) |yi| {
            const y: u32 = @intCast(yi);
            const row = a.cur[yi * box.cols ..][0..box.cols];
            var runs: sgr.ChangedRuns(Cell) = .{
                .new = row,
                .old = a.prev[yi * box.cols ..][0..box.cols],
                .force = if (full) .{ 0, box.cols } else sgr.rowSpan(last.?.occlude, box, box.row + y),
                .skip = sgr.rowSpan(occlude, box, box.row + y),
            };
            while (runs.next()) |r| {
                try a.emitRun(w, box, y, row, r[0], r[1]);
                wrote = true;
            }
        }
        if (wrote) try w.writeAll(sgr.reset);
        std.mem.swap([]Cell, &a.cur, &a.prev);
        a.last = .{ .rect = rect, .box = box, .occlude = occlude };
    }

    fn cell(a: *const Ascii, c: Rgb) Cell {
        const ch = rampChar(c);
        if (ch == ' ') return .{ .ch = ch, .fg = 0 };
        return .{ .ch = ch, .fg = switch (a.color) {
            .truecolor => @as(u32, c[0]) << 16 | @as(u32, c[1]) << 8 | c[2],
            .ansi256 => ansi256(c),
            .none => 0,
        } };
    }

    fn resize(a: *Ascii, box: Rect) !void {
        const n = @as(usize, box.cols) * box.rows;
        if (a.cur.len != n or a.prev.len != n) {
            a.gpa.free(a.cur);
            a.cur = &.{};
            a.gpa.free(a.prev);
            a.prev = &.{};
            a.cur = try a.gpa.alloc(Cell, n);
            a.prev = try a.gpa.alloc(Cell, n);
        }
        if (a.pixels.len != n * 3) {
            a.gpa.free(a.pixels);
            a.pixels = &.{};
            a.pixels = try a.gpa.alloc(u8, n * 3);
        }
    }

    fn emitRun(a: *Ascii, w: *std.Io.Writer, box: Rect, y: u32, row: []const Cell, from: u32, to: u32) !void {
        try sgr.cup(w, box.row + y, box.col + from);
        for (row[from..to]) |c| {
            if (c.ch != ' ' and a.color != .none and a.pen != c.fg) {
                switch (a.color) {
                    .truecolor => try w.print("\x1b[38;2;{d};{d};{d}m", .{ c.fg >> 16, (c.fg >> 8) & 0xff, c.fg & 0xff }),
                    .ansi256 => try w.print("\x1b[38;5;{d}m", .{c.fg}),
                    .none => unreachable,
                }
                a.pen = c.fg;
            }
            try w.writeByte(c.ch);
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const golden = @import("golden.zig");

fn render(a: *Ascii, frame: Frame, rect: Rect) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try a.present(&aw.writer, frame, rect, null, null);
    return aw.toOwnedSlice();
}

test "luma ramp: black is a space, white is @" {
    try testing.expectEqual(@as(u8, ' '), rampChar(.{ 0, 0, 0 }));
    try testing.expectEqual(@as(u8, '@'), rampChar(.{ 255, 255, 255 }));
    try testing.expectEqual(@as(u8, 255), luma(.{ 255, 255, 255 }));
    // Pure green is far brighter than pure blue.
    try testing.expect(luma(.{ 0, 255, 0 }) > 4 * luma(.{ 0, 0, 255 }));
}

test "ansi256 quantiser" {
    try testing.expectEqual(@as(u8, 16), ansi256(.{ 0, 0, 0 }));
    try testing.expectEqual(@as(u8, 231), ansi256(.{ 255, 255, 255 }));
    try testing.expectEqual(@as(u8, 196), ansi256(.{ 255, 0, 0 }));
    try testing.expectEqual(@as(u8, 21), ansi256(.{ 0, 0, 255 }));
    // Mid grey: grey ramp entry 244 is exactly 128; the cube's nearest is 135.
    try testing.expectEqual(@as(u8, 244), ansi256(.{ 128, 128, 128 }));
    try testing.expectEqual(@as(u8, 232), ansi256(.{ 8, 8, 8 }));
    // An exact cube colour (95, 135, 215) = 16 + 36·1 + 6·2 + 4.
    try testing.expectEqual(@as(u8, 68), ansi256(.{ 95, 135, 215 }));
    // Boundaries between cube levels 0/95 (48) and 95/135 (115), with blue
    // saturated so the grey ramp can't win.
    try testing.expectEqual(@as(u8, 16 + 5), ansi256(.{ 47, 0, 255 }));
    try testing.expectEqual(@as(u8, 16 + 36 + 5), ansi256(.{ 48, 0, 255 }));
    try testing.expectEqual(@as(u8, 16 + 36 + 5), ansi256(.{ 114, 0, 255 }));
    try testing.expectEqual(@as(u8, 16 + 72 + 5), ansi256(.{ 115, 0, 255 }));
    // A dark red is nearer grey 233 (18) than cube red (95, 0, 0).
    try testing.expectEqual(@as(u8, 233), ansi256(.{ 48, 0, 0 }));
}

test "tiny frame: exact bytes per colour mode, then an unchanged frame writes nothing" {
    // 3×1 cells at 10×20 px want a 3:2 image; 3×2 pixels → one sample per
    // cell column: averages of each column's two pixels.
    const px = [_]u8{ 255, 0, 0, 0, 0, 0, 255, 255, 255 } ++ [_]u8{ 255, 0, 0, 0, 0, 0, 255, 255, 255 };
    const frame: Frame = .{ .width = 3, .height = 2, .rgb = &px };
    const rect: Rect = .{ .col = 2, .row = 4, .cols = 3, .rows = 1 };
    const cases = [_]struct { Color, []const u8 }{
        // Red: luma 54 → ':'; black: space (no colour); white: '@'.
        .{ .truecolor, "\x1b[0m\x1b[4;2H\x1b[38;2;255;0;0m: \x1b[38;2;255;255;255m@\x1b[0m" },
        .{ .ansi256, "\x1b[0m\x1b[4;2H\x1b[38;5;196m: \x1b[38;5;231m@\x1b[0m" },
        .{ .none, "\x1b[0m\x1b[4;2H: @\x1b[0m" },
    };
    for (cases) |c| {
        var a: Ascii = .init(testing.allocator, .{ .w = 10, .h = 20 }, c[0]);
        defer a.deinit();
        const out = try render(&a, frame, rect);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c[1], out);
        const again = try render(&a, frame, rect);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings("", again);
    }
}

test "golden: test-core frame 60, 80×24 at 10×20 px cells, each colour mode" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    const cases = [_]struct { Color, []const u8 }{
        .{ .truecolor, "render-ascii-truecolor-80x24.bin" },
        .{ .ansi256, "render-ascii-256-80x24.bin" },
        .{ .none, "render-ascii-mono-80x24.bin" },
    };
    for (cases) |c| {
        var a: Ascii = .init(testing.allocator, golden.cell_px, c[0]);
        defer a.deinit();
        const out = try render(&a, frame, golden.rect);
        defer testing.allocator.free(out);
        try golden.check(c[1], out);
    }
}

test "changed cells: a shifted bar redraws one column only" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    var a: Ascii = .init(testing.allocator, golden.cell_px, .truecolor);
    defer a.deinit();
    testing.allocator.free(try render(&a, frame, golden.rect));

    // As in the half-block test: inverting source columns 100–101 changes
    // only target column 21 of the 55-col box at col 13, i.e. cell column 34.
    const moved = try testing.allocator.dupe(u8, frame.rgb);
    defer testing.allocator.free(moved);
    for (0..frame.height) |y| for (100..102) |x| for (0..3) |k| {
        moved[(y * frame.width + x) * 3 + k] ^= 0xff;
    };
    const out = try render(&a, .{ .width = frame.width, .height = frame.height, .rgb = moved }, golden.rect);
    defer testing.allocator.free(out);
    const g = try golden.scan(out);
    try testing.expect(g.glyphs > 0);
    try testing.expectEqual(g.glyphs, g.cups);
    try testing.expectEqual(@as(?u32, 34), g.only_col);
}

test "empty frame or rect writes nothing" {
    var a: Ascii = .init(testing.allocator, golden.cell_px, .truecolor);
    defer a.deinit();
    const px = [_]u8{ 1, 2, 3 };
    const empty = try render(&a, .{ .width = 0, .height = 0, .rgb = &.{} }, golden.rect);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
    const no_rect = try render(&a, .{ .width = 1, .height = 1, .rgb = &px }, .{ .cols = 0, .rows = 5 });
    defer testing.allocator.free(no_rect);
    try testing.expectEqualStrings("", no_rect);
}

test "rect change and setCellPx force a full redraw" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    var a: Ascii = .init(testing.allocator, golden.cell_px, .none);
    defer a.deinit();
    testing.allocator.free(try render(&a, frame, golden.rect));
    const moved = try render(&a, frame, .{ .col = 2, .row = 1, .cols = 80, .rows = 24 });
    defer testing.allocator.free(moved);
    try testing.expectEqual(@as(usize, 55 * 24), (try golden.scan(moved)).glyphs);
    a.setCellPx(golden.cell_px);
    const after = try render(&a, frame, .{ .col = 2, .row = 1, .cols = 80, .rows = 24 });
    defer testing.allocator.free(after);
    try testing.expectEqual(@as(usize, 55 * 24), (try golden.scan(after)).glyphs);
}

test "a moved rect erases the old rect's uncovered cells" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    var a: Ascii = .init(testing.allocator, golden.cell_px, .none);
    defer a.deinit();
    testing.allocator.free(try render(&a, frame, golden.rect));
    const moved = try render(&a, frame, .{ .col = 2, .row = 1, .cols = 80, .rows = 24 });
    defer testing.allocator.free(moved);
    try testing.expect(std.mem.startsWith(u8, moved, "\x1b[0m\x1b[1;1H\x1b[1X\x1b[2;1H\x1b[1X"));
}

test "a present that runs out of memory leaves a state the next one recovers from" {
    const frame = try golden.loadFrame60(testing.allocator);
    defer testing.allocator.free(frame.rgb);
    const small: Rect = .{ .col = 1, .row = 1, .cols = 20, .rows = 6 };
    for (0..12) |k| {
        var fa: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var a: Ascii = .init(fa.allocator(), golden.cell_px, .truecolor);
        defer a.deinit();
        testing.allocator.free(try render(&a, frame, small));
        fa.fail_index = fa.alloc_index + k;
        if (render(&a, frame, golden.rect)) |out| testing.allocator.free(out) else |err| try testing.expectEqual(error.OutOfMemory, err);
        fa.fail_index = std.math.maxInt(usize);
        testing.allocator.free(try render(&a, frame, small));
        const again = try render(&a, frame, small);
        defer testing.allocator.free(again);
        try testing.expectEqualStrings("", again);
    }
}
