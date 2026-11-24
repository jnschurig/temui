//! Half-block truecolor encoder: each cell shows two vertically stacked
//! pixels (`▀` with fg = top, bg = bottom). The frame is downscaled 2:1 by
//! nearest neighbour to a fixed cell area, so bytes and CPU are comparable
//! across terminals. `full` redraws every cell; `diff` redraws only cells
//! that changed since the previous frame.

const std = @import("std");
const cli = @import("cli.zig");

pub const Mode = enum { full, diff };

/// Changed runs separated by at most this many unchanged cells are merged:
/// re-sending a few cells is cheaper than another cursor move.
const merge_gap = 2;

const Rgb = [3]u8;
const Cell = struct {
    top: Rgb,
    bot: Rgb,

    fn eql(a: Cell, b: Cell) bool {
        return std.mem.eql(u8, &a.top, &b.top) and std.mem.eql(u8, &a.bot, &b.bot);
    }
};

/// Cell area for a resolution: 128×56 for 256×224, 160×60 for 320×240.
pub fn cellArea(res: cli.Res) struct { cols: u32, rows: u32 } {
    return .{ .cols = res.width() / 2, .rows = res.height() / 4 };
}

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    cols: u32,
    rows: u32,
    /// 1-based top-left cell of the drawing area.
    col0: u32,
    row0: u32,
    cur: []Cell,
    prev: []Cell,
    have_prev: bool = false,
    out: std.ArrayList(u8) = .empty,
    fg: ?Rgb = null,
    bg: ?Rgb = null,

    pub fn init(gpa: std.mem.Allocator, cols: u32, rows: u32, col0: u32, row0: u32) !Encoder {
        const n = @as(usize, cols) * rows;
        const cur = try gpa.alloc(Cell, n);
        errdefer gpa.free(cur);
        const prev = try gpa.alloc(Cell, n);
        errdefer gpa.free(prev);
        var e: Encoder = .{ .gpa = gpa, .cols = cols, .rows = rows, .col0 = col0, .row0 = row0, .cur = cur, .prev = prev };
        // Worst case: CUP per row plus two full SGRs and a 3-byte glyph per cell.
        try e.out.ensureTotalCapacity(gpa, n * 44 + @as(usize, rows) * 16 + 16);
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        e.gpa.free(e.cur);
        e.gpa.free(e.prev);
        e.out.deinit(e.gpa);
        e.* = undefined;
    }

    /// Forget the previous frame (the next `diff` encode redraws everything).
    pub fn reset(e: *Encoder) void {
        e.have_prev = false;
    }

    /// `pixels` is RGB, w×h. Returns the bytes to write (empty when nothing
    /// changed in diff mode).
    pub fn encode(e: *Encoder, pixels: []const u8, w: u32, h: u32, mode: Mode) ![]const u8 {
        std.debug.assert(pixels.len == @as(usize, w) * h * 3);
        e.sample(pixels, w, h);
        e.out.clearRetainingCapacity();
        e.fg = null;
        e.bg = null;
        const full = mode == .full or !e.have_prev;
        for (0..e.rows) |yi| {
            const y: u32 = @intCast(yi);
            const row = e.cur[yi * e.cols ..][0..e.cols];
            if (full) {
                try e.emitRun(y, 0, e.cols);
                continue;
            }
            const old = e.prev[yi * e.cols ..][0..e.cols];
            var x: u32 = 0;
            while (x < e.cols) {
                if (row[x].eql(old[x])) {
                    x += 1;
                    continue;
                }
                var last = x;
                var j = x + 1;
                while (j < e.cols and j - last <= merge_gap) : (j += 1) {
                    if (!row[j].eql(old[j])) last = j;
                }
                try e.emitRun(y, x, last + 1);
                x = last + 1;
            }
        }
        if (e.out.items.len > 0) try e.out.appendSlice(e.gpa, "\x1b[0m");
        std.mem.swap([]Cell, &e.cur, &e.prev);
        e.have_prev = true;
        return e.out.items;
    }

    fn sample(e: *Encoder, pixels: []const u8, w: u32, h: u32) void {
        for (0..e.rows) |cy| {
            const ty = (2 * cy) * h / (2 * e.rows);
            const by = (2 * cy + 1) * h / (2 * e.rows);
            for (0..e.cols) |cx| {
                const sx = cx * w / e.cols;
                e.cur[cy * e.cols + cx] = .{
                    .top = pixels[(ty * w + sx) * 3 ..][0..3].*,
                    .bot = pixels[(by * w + sx) * 3 ..][0..3].*,
                };
            }
        }
    }

    fn emitRun(e: *Encoder, y: u32, a: u32, b: u32) !void {
        const gpa = e.gpa;
        try e.out.ensureUnusedCapacity(gpa, 16 + @as(usize, b - a) * 44);
        e.out.appendSliceAssumeCapacity("\x1b[");
        appendInt(&e.out, e.row0 + y);
        e.out.appendAssumeCapacity(';');
        appendInt(&e.out, e.col0 + a);
        e.out.appendAssumeCapacity('H');
        for (e.cur[y * e.cols ..][a..b]) |cell| {
            if (std.mem.eql(u8, &cell.top, &cell.bot)) {
                // One colour: a space on bg, or a full block on fg.
                if (e.bg != null and std.mem.eql(u8, &e.bg.?, &cell.bot)) {
                    e.out.appendAssumeCapacity(' ');
                } else if (e.fg != null and std.mem.eql(u8, &e.fg.?, &cell.top)) {
                    e.out.appendSliceAssumeCapacity("█");
                } else {
                    e.sgr(null, cell.bot);
                    e.out.appendAssumeCapacity(' ');
                }
                continue;
            }
            const need_fg = e.fg == null or !std.mem.eql(u8, &e.fg.?, &cell.top);
            const need_bg = e.bg == null or !std.mem.eql(u8, &e.bg.?, &cell.bot);
            e.sgr(if (need_fg) cell.top else null, if (need_bg) cell.bot else null);
            e.out.appendSliceAssumeCapacity("▀");
        }
    }

    fn sgr(e: *Encoder, fg: ?Rgb, bg: ?Rgb) void {
        if (fg == null and bg == null) return;
        e.out.appendSliceAssumeCapacity("\x1b[");
        if (fg) |c| {
            e.out.appendSliceAssumeCapacity("38;2;");
            appendRgb(&e.out, c);
            e.fg = c;
        }
        if (bg) |c| {
            if (fg != null) e.out.appendAssumeCapacity(';');
            e.out.appendSliceAssumeCapacity("48;2;");
            appendRgb(&e.out, c);
            e.bg = c;
        }
        e.out.appendAssumeCapacity('m');
    }
};

fn appendRgb(out: *std.ArrayList(u8), c: Rgb) void {
    appendInt(out, c[0]);
    out.appendAssumeCapacity(';');
    appendInt(out, c[1]);
    out.appendAssumeCapacity(';');
    appendInt(out, c[2]);
}

fn appendInt(out: *std.ArrayList(u8), v: u32) void {
    var buf: [10]u8 = undefined;
    var i: usize = buf.len;
    var n = v;
    while (true) {
        i -= 1;
        buf[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0) break;
    }
    out.appendSliceAssumeCapacity(buf[i..]);
}

// ---- tests ----

const testing = std.testing;

/// Number of glyphs drawn (escape sequences stripped).
fn glyphs(out: []const u8) !usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == 0x1b) {
            i += 2; // ESC [
            while (out[i] < 0x40 or out[i] > 0x7e) i += 1;
            i += 1;
            continue;
        }
        i += try std.unicode.utf8ByteSequenceLength(out[i]);
        n += 1;
    }
    return n;
}

test "full redraw of a tiny frame" {
    const gpa = testing.allocator;
    const A = [3]u8{ 1, 2, 3 };
    const B = [3]u8{ 40, 50, 60 };
    const C = [3]u8{ 200, 0, 9 };
    const X = [3]u8{ 7, 7, 7 }; // odd rows are not sampled
    // 4×4: cells sample rows 0 (top) and 2 (bottom), columns 0 and 2.
    const px = A ++ A ++ B ++ B ++ X ++ X ++ X ++ X ++ C ++ C ++ B ++ B ++ X ++ X ++ X ++ X;
    var e = try Encoder.init(gpa, 2, 1, 3, 5);
    defer e.deinit();
    const out = try e.encode(&px, 4, 4, .full);
    try testing.expectEqualStrings("\x1b[5;3H\x1b[38;2;1;2;3;48;2;200;0;9m▀\x1b[48;2;40;50;60m \x1b[0m", out);
    // Full mode redraws even when nothing changed.
    try testing.expectEqualStrings("\x1b[5;3H\x1b[38;2;1;2;3;48;2;200;0;9m▀\x1b[48;2;40;50;60m \x1b[0m", try e.encode(&px, 4, 4, .full));
}

test "diff: identical frame is empty, one changed pixel touches one cell" {
    const gpa = testing.allocator;
    const scene = @import("scene.zig");
    var l = try scene.Loop.init(gpa, .sprites, .@"256x224", .rgb);
    defer l.deinit(gpa);
    const area = cellArea(.@"256x224");
    try testing.expectEqual(@as(u32, 128), area.cols);
    try testing.expectEqual(@as(u32, 56), area.rows);
    var e = try Encoder.init(gpa, area.cols, area.rows, 1, 1);
    defer e.deinit();

    const first = try e.encode(l.frame(0), 256, 224, .diff);
    try testing.expectEqual(@as(usize, 128 * 56), try glyphs(first));
    try testing.expectEqual(@as(usize, 0), (try e.encode(l.frame(0), 256, 224, .diff)).len);

    const px = try gpa.dupe(u8, l.frame(0));
    defer gpa.free(px);
    // Pixel (10, 40) is cell (5, 10)'s top sample.
    const off = (40 * 256 + 10) * 3;
    px[off] +%= 77;
    const out = try e.encode(px, 256, 224, .diff);
    try testing.expectEqual(@as(usize, 1), try glyphs(out));
    try testing.expect(std.mem.startsWith(u8, out, "\x1b[11;6H"));

    // A moving-sprite frame redraws far fewer cells than a full redraw.
    const moved = try e.encode(l.frame(1), 256, 224, .diff);
    try testing.expect(try glyphs(moved) < 128 * 56 / 3);
}

test "diff on a scrolling scene redraws nearly every cell" {
    const gpa = testing.allocator;
    const scene = @import("scene.zig");
    var l = try scene.Loop.init(gpa, .scroll, .@"320x240", .rgb);
    defer l.deinit(gpa);
    var e = try Encoder.init(gpa, 160, 60, 1, 1);
    defer e.deinit();
    _ = try e.encode(l.frame(0), 320, 240, .diff);
    const out = try e.encode(l.frame(1), 320, 240, .diff);
    // Scroll changes every cell, so diff degenerates to (nearly) full.
    try testing.expect(try glyphs(out) > 160 * 60 * 9 / 10);
}
