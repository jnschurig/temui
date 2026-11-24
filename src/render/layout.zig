//! Cell-rectangle layout and area-average resampling, shared by the
//! backends.

const std = @import("std");
const CellPx = @import("../term/caps.zig").CellPx;

/// A rectangle of character cells; `col`/`row` are 1-based like CUP.
pub const Rect = struct {
    col: u32 = 1,
    row: u32 = 1,
    cols: u32 = 0,
    rows: u32 = 0,

    pub fn isEmpty(r: Rect) bool {
        return r.cols == 0 or r.rows == 0;
    }
};

/// The largest box with display aspect `aspect` (width / height) that fits in
/// `rect`, in whole cells, centred. Empty when `rect` is empty or the aspect
/// is not a positive finite number.
pub fn fit(rect: Rect, cell: CellPx, aspect: f32) Rect {
    if (rect.isEmpty() or cell.w == 0 or cell.h == 0) return .{ .col = rect.col, .row = rect.row };
    if (!(aspect > 0) or !std.math.isFinite(aspect)) return .{ .col = rect.col, .row = rect.row };

    const cw: f64 = @floatFromInt(cell.w);
    const ch: f64 = @floatFromInt(cell.h);
    const box_w = @as(f64, @floatFromInt(rect.cols)) * cw;
    const box_h = @as(f64, @floatFromInt(rect.rows)) * ch;
    const a: f64 = aspect;

    var cols = rect.cols;
    var rows = rect.rows;
    if (box_w / box_h > a) {
        cols = roundCells(box_h * a / cw, rect.cols);
    } else {
        rows = roundCells(box_w / a / ch, rect.rows);
    }
    return .{
        .col = rect.col + (rect.cols - cols) / 2,
        .row = rect.row + (rect.rows - rows) / 2,
        .cols = cols,
        .rows = rows,
    };
}

fn roundCells(v: f64, max: u32) u32 {
    const r = @round(v);
    if (r < 1) return 1;
    if (r >= @as(f64, @floatFromInt(max))) return max;
    return @intFromFloat(r);
}

/// Per-axis box-filter weights. Target pixel `i` covers the source interval
/// `[i·src/dst, (i+1)·src/dst)`; measured in units of `1/dst` source pixels,
/// each overlap is an integer and a target's weights sum to `src`.
const Axis = struct {
    /// `first[i]` is the first source index for target `i`; its weights are
    /// `weights[offset[i]..offset[i + 1]]`.
    first: []u32,
    offset: []u32,
    weights: []u32,

    fn init(gpa: std.mem.Allocator, src: u32, dst: u32) !Axis {
        const first = try gpa.alloc(u32, dst);
        errdefer gpa.free(first);
        const offset = try gpa.alloc(u32, dst + 1);
        errdefer gpa.free(offset);
        // Each target touches at most ceil(src/dst) + 1 sources.
        const weights = try gpa.alloc(u32, dst * (src / dst + 2));
        errdefer gpa.free(weights);

        var n: u32 = 0;
        for (0..dst) |i_usize| {
            const i: u64 = i_usize;
            const lo = i * src;
            const hi = (i + 1) * src;
            const a = lo / dst;
            const b = (hi - 1) / dst;
            first[i_usize] = @intCast(a);
            offset[i_usize] = n;
            var s = a;
            while (s <= b) : (s += 1) {
                weights[n] = @intCast(@min(hi, (s + 1) * dst) - @max(lo, s * dst));
                n += 1;
            }
        }
        offset[dst] = n;
        return .{ .first = first, .offset = offset, .weights = weights };
    }

    fn deinit(a: Axis, gpa: std.mem.Allocator) void {
        gpa.free(a.first);
        gpa.free(a.offset);
        gpa.free(a.weights);
    }

    fn span(a: Axis, i: usize) struct { first: u32, weights: []const u32 } {
        return .{ .first = a.first[i], .weights = a.weights[a.offset[i]..a.offset[i + 1]] };
    }
};

/// Area-averaging RGB24 resampler: each output pixel is the mean of the
/// source area it covers (box filter, exact integer weights, rounded).
/// Weights are rebuilt only when the source or target size changes.
pub const Resampler = struct {
    gpa: std.mem.Allocator,
    src_w: u32 = 0,
    src_h: u32 = 0,
    dst_w: u32 = 0,
    dst_h: u32 = 0,
    xs: ?Axis = null,
    ys: ?Axis = null,
    /// Horizontal pass: `src_h × dst_w × 3` sums, each with denominator `src_w`.
    tmp: []u32 = &.{},

    pub fn init(gpa: std.mem.Allocator) Resampler {
        return .{ .gpa = gpa };
    }

    pub fn deinit(r: *Resampler) void {
        r.release();
        r.* = undefined;
    }

    fn release(r: *Resampler) void {
        if (r.xs) |a| a.deinit(r.gpa);
        if (r.ys) |a| a.deinit(r.gpa);
        r.gpa.free(r.tmp);
        r.xs = null;
        r.ys = null;
        r.tmp = &.{};
    }

    /// Resamples `rgb` (`src_w × src_h`, packed RGB24) into `out`
    /// (`dst_w × dst_h × 3` bytes). All sizes must be non-zero.
    pub fn sample(r: *Resampler, rgb: []const u8, src_w: u32, src_h: u32, out: []u8, dst_w: u32, dst_h: u32) !void {
        std.debug.assert(src_w > 0 and src_h > 0 and dst_w > 0 and dst_h > 0);
        std.debug.assert(rgb.len >= @as(usize, src_w) * src_h * 3);
        std.debug.assert(out.len >= @as(usize, dst_w) * dst_h * 3);
        if (r.xs == null or src_w != r.src_w or src_h != r.src_h or dst_w != r.dst_w or dst_h != r.dst_h) {
            r.release();
            r.xs = try Axis.init(r.gpa, src_w, dst_w);
            r.ys = try Axis.init(r.gpa, src_h, dst_h);
            r.tmp = try r.gpa.alloc(u32, @as(usize, src_h) * dst_w * 3);
            r.src_w = src_w;
            r.src_h = src_h;
            r.dst_w = dst_w;
            r.dst_h = dst_h;
        }
        const xs = r.xs.?;
        const ys = r.ys.?;

        // Horizontal: tmp[y][x] = Σ wx · src[y][s]   (denominator src_w).
        for (0..src_h) |y| {
            const row = rgb[y * src_w * 3 ..][0 .. src_w * 3];
            const trow = r.tmp[y * dst_w * 3 ..][0 .. dst_w * 3];
            for (0..dst_w) |x| {
                const sp = xs.span(x);
                var acc = [3]u32{ 0, 0, 0 };
                for (sp.weights, sp.first..) |w, s| {
                    inline for (0..3) |k| acc[k] += w * row[s * 3 + k];
                }
                trow[x * 3 ..][0..3].* = acc;
            }
        }

        // Vertical: out[y][x] = Σ wy · tmp[s][x] / (src_w · src_h).
        const denom: u64 = @as(u64, src_w) * src_h;
        for (0..dst_h) |y| {
            const sp = ys.span(y);
            const orow = out[y * dst_w * 3 ..][0 .. dst_w * 3];
            for (0..dst_w * 3) |i| {
                var acc: u64 = 0;
                for (sp.weights, sp.first..) |w, s| acc += @as(u64, w) * r.tmp[s * dst_w * 3 + i];
                orow[i] = @intCast((acc + denom / 2) / denom);
            }
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const c10x20: CellPx = .{ .w = 10, .h = 20 };

test "fit: wide rect letterboxes left/right" {
    // 80×24 cells at 10×20 px = 800×480 px; 8:7 → 548.6 px wide → 55 cells.
    const f = fit(.{ .cols = 80, .rows = 24 }, c10x20, 256.0 / 224.0);
    try testing.expectEqual(Rect{ .col = 13, .row = 1, .cols = 55, .rows = 24 }, f);
}

test "fit: tall rect letterboxes top/bottom" {
    // 20×40 cells = 200×800 px; 16:9 → 112.5 px tall → 5.6 → 6 rows.
    const f = fit(.{ .col = 5, .row = 3, .cols = 20, .rows = 40 }, c10x20, 16.0 / 9.0);
    try testing.expectEqual(Rect{ .col = 5, .row = 3 + 17, .cols = 20, .rows = 6 }, f);
}

test "fit: exact aspect fills the rect" {
    try testing.expectEqual(Rect{ .cols = 40, .rows = 10 }, fit(.{ .cols = 40, .rows = 10 }, c10x20, 2.0));
}

test "fit: odd aspect and a one-cell rect" {
    try testing.expectEqual(Rect{ .col = 7, .row = 9, .cols = 1, .rows = 1 }, fit(.{ .col = 7, .row = 9, .cols = 1, .rows = 1 }, c10x20, 0.01));
    // Extremely wide image in a tall rect still gets at least one row.
    try testing.expectEqual(@as(u32, 1), fit(.{ .cols = 3, .rows = 50 }, c10x20, 1000).rows);
}

test "fit: degenerate input gives an empty rect" {
    try testing.expect(fit(.{ .cols = 0, .rows = 10 }, c10x20, 1).isEmpty());
    try testing.expect(fit(.{ .cols = 10, .rows = 0 }, c10x20, 1).isEmpty());
    try testing.expect(fit(.{ .cols = 10, .rows = 10 }, c10x20, 0).isEmpty());
    try testing.expect(fit(.{ .cols = 10, .rows = 10 }, c10x20, std.math.nan(f32)).isEmpty());
    try testing.expect(fit(.{ .cols = 10, .rows = 10 }, c10x20, std.math.inf(f32)).isEmpty());
}

test "resampler: identity at 1:1" {
    var r: Resampler = .init(testing.allocator);
    defer r.deinit();
    var src: [4 * 3 * 3]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i * 7 % 256);
    var out: [src.len]u8 = undefined;
    try r.sample(&src, 4, 3, &out, 4, 3);
    try testing.expectEqualSlices(u8, &src, &out);
}

test "resampler: exact 2:1 averages" {
    var r: Resampler = .init(testing.allocator);
    defer r.deinit();
    // 2×2 → 1×1: mean of four pixels per channel.
    const src = [_]u8{ 0, 10, 255, 100, 20, 255, 50, 30, 0, 150, 40, 0 };
    var out: [3]u8 = undefined;
    try r.sample(&src, 2, 2, &out, 1, 1);
    try testing.expectEqualSlices(u8, &.{ 75, 25, 128 }, &out); // 510/4 = 127.5 → 128
}

test "resampler: fractional ratio, hand-computed" {
    var r: Resampler = .init(testing.allocator);
    defer r.deinit();
    // 3 grey pixels 0, 90, 210 → 2: target 0 covers [0, 1.5): (0 + 0.5·90)/1.5 = 30;
    // target 1 covers [1.5, 3): (0.5·90 + 210)/1.5 = 170.
    const src = [_]u8{ 0, 0, 0, 90, 90, 90, 210, 210, 210 };
    var out: [6]u8 = undefined;
    try r.sample(&src, 3, 1, &out, 2, 1);
    try testing.expectEqualSlices(u8, &.{ 30, 30, 30, 170, 170, 170 }, &out);
}

test "resampler: constant image stays constant, up and down, and rebuilds on size change" {
    var r: Resampler = .init(testing.allocator);
    defer r.deinit();
    var src: [7 * 5 * 3]u8 = undefined;
    for (0..src.len / 3) |i| src[i * 3 ..][0..3].* = .{ 12, 200, 99 };
    for ([_][2]u32{ .{ 3, 2 }, .{ 13, 11 }, .{ 7, 5 }, .{ 1, 1 } }) |d| {
        const out = try testing.allocator.alloc(u8, d[0] * d[1] * 3);
        defer testing.allocator.free(out);
        try r.sample(&src, 7, 5, out, d[0], d[1]);
        for (0..out.len / 3) |i| try testing.expectEqualSlices(u8, &.{ 12, 200, 99 }, out[i * 3 ..][0..3]);
    }
}
