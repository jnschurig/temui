//! The renderer interface (D7): one API over the kitty, half-block and ASCII
//! backends. Output goes to a caller-supplied writer, never straight to fd 1
//! (D13). A frame is drawn letterboxed into a cell rect; the first frame and
//! any rect, fitted-box or cell-size change redraw everything and clear the
//! margin.
//!
//! Lifetime: `init`, any number of `present`/`resize`, then `clear` (removes
//! what this renderer drew: its kitty images and its rect) and `deinit`
//! (frees memory; for kitty also unlinks leftover shm/file objects).

const std = @import("std");
const caps = @import("../term/caps.zig");
const layout = @import("layout.zig");
const sgr = @import("sgr.zig");
const kitty = @import("kitty.zig");
const HalfBlock = @import("halfblock.zig").HalfBlock;
const Ascii = @import("ascii.zig").Ascii;

const Renderer = @This();

pub const Frame = layout.Frame;
pub const Rect = layout.Rect;
pub const Backend = caps.Backend;
pub const CellPx = caps.CellPx;

pub const Options = struct {
    kitty: kitty.Options = .{},
};

pub const PresentOptions = struct {
    /// Display aspect (width / height); default: the frame's own.
    aspect: ?f32 = null,
    /// Cells an overlay occupies. Half-block and ASCII never draw inside it,
    /// and redraw what it uncovers on the next `present` once it shrinks or
    /// goes (even if the pixels there are unchanged). Kitty ignores it: its
    /// image sits below cells with a background (`Choice.kitty_z`).
    occlude: ?Rect = null,
};

impl: union(Backend) {
    kitty: kitty.Kitty,
    halfblock: HalfBlock,
    ascii: Ascii,
},

/// Builds the backend `choice` names, with its cell size, kitty transport
/// order and z-index, and ASCII colour mode.
pub fn init(gpa: std.mem.Allocator, io: std.Io, choice: caps.Choice, opts: Options) !Renderer {
    var kitty_opts = opts.kitty;
    kitty_opts.z = choice.kitty_z;
    return .{ .impl = switch (choice.backend) {
        .kitty => .{ .kitty = try .init(gpa, io, choice.cell_px, choice.transports, kitty_opts) },
        .halfblock => .{ .halfblock = .init(gpa, choice.cell_px) },
        .ascii => .{ .ascii = .init(gpa, choice.cell_px, choice.ascii_color) },
    } };
}

/// Frees memory. Call `clear` first to remove what was drawn.
pub fn deinit(r: *Renderer) void {
    switch (r.impl) {
        inline else => |*b| b.deinit(),
    }
    r.* = undefined;
}

pub fn backend(r: *const Renderer) Backend {
    return r.impl;
}

/// Draws `frame` into `rect`. An empty frame or rect draws nothing.
pub fn present(r: *Renderer, w: *std.Io.Writer, frame: Frame, rect: Rect, opts: PresentOptions) !void {
    switch (r.impl) {
        .kitty => |*k| try k.present(w, frame, rect, opts.aspect),
        inline .halfblock, .ascii => |*b| try b.present(w, frame, rect, opts.aspect, opts.occlude),
    }
}

/// The box `present` would draw `frame` into: `rect` letterboxed to `aspect`
/// (default: the frame's own). Empty when nothing would be drawn.
pub fn fitted(r: *const Renderer, frame: Frame, rect: Rect, aspect: ?f32) Rect {
    if (frame.isEmpty() or rect.isEmpty()) return .{ .col = rect.col, .row = rect.row };
    const cell = switch (r.impl) {
        inline else => |*b| b.cell_px,
    };
    return layout.fit(rect, cell, aspect orelse frame.aspect());
}

/// The terminal's cell size changed (or the screen was otherwise disturbed):
/// the next `present` redraws everything.
pub fn resize(r: *Renderer, cell_px: CellPx) void {
    switch (r.impl) {
        inline else => |*b| b.setCellPx(cell_px),
    }
}

/// Removes everything this renderer drew: kitty deletes its own two images
/// (never other instances'), and the last rect is erased. The next `present`
/// starts from scratch.
pub fn clear(r: *Renderer, w: *std.Io.Writer) !void {
    switch (r.impl) {
        .kitty => |*k| try k.clear(w),
        inline .halfblock, .ascii => |*b| {
            if (b.last) |l| try sgr.clearRect(w, l.rect);
            b.invalidate();
        },
    }
}

/// `host.Frame` (or anything with `width`, `height`, `rgb`) as a render frame.
pub fn frameFrom(f: anytype) Frame {
    return .{ .width = f.width, .height = f.height, .rgb = f.rgb };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const golden = @import("golden.zig");

fn testChoice(b: Backend) caps.Choice {
    return .{
        .backend = b,
        .transports = .init(&.{.zlib}),
        .ascii_color = .truecolor,
        .cell_px = golden.cell_px,
    };
}

fn draw(r: *Renderer, frame: Frame, rect: Rect) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try r.present(&aw.writer, frame, rect, .{});
    return aw.toOwnedSlice();
}

/// Whether `out` contains an ECH (`CSI n X`), i.e. a margin clear.
fn hasEch(out: []const u8) bool {
    var rest = out;
    while (std.mem.indexOf(u8, rest, "\x1b[")) |at| {
        var j = at + 2;
        while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
        if (j < rest.len and j > at + 2 and rest[j] == 'X') return true;
        rest = rest[at + 2 ..];
    }
    return false;
}

fn clearOut(r: *Renderer) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try r.clear(&aw.writer);
    return aw.toOwnedSlice();
}

test "frameFrom converts host.Frame" {
    const host = @import("../libretro/host.zig");
    const px = [_]u8{ 1, 2, 3 };
    const f = frameFrom(host.Frame{ .width = 1, .height = 1, .rgb = &px });
    try testing.expectEqual(@as(usize, 1), f.width);
    try testing.expectEqualSlices(u8, &px, f.rgb);
}

test "golden output through the interface matches the backends'" {
    const gpa = testing.allocator;
    const frame = try golden.loadFrame60(gpa);
    defer gpa.free(frame.rgb);
    const cases = [_]struct { Backend, []const u8 }{
        .{ .halfblock, "render-halfblock-80x24.bin" },
        .{ .ascii, "render-ascii-truecolor-80x24.bin" },
    };
    for (cases) |c| {
        var r: Renderer = try .init(gpa, testing.io, testChoice(c[0]), .{});
        defer r.deinit();
        try testing.expectEqual(c[0], r.backend());
        const out = try draw(&r, frame, golden.rect);
        defer gpa.free(out);
        try golden.check(c[1], out);
    }
}

test "present twice: cell backends write nothing; kitty sends the next id" {
    const gpa = testing.allocator;
    const frame = try golden.loadFrame60(gpa);
    defer gpa.free(frame.rgb);
    for ([_]Backend{ .kitty, .halfblock, .ascii }) |b| {
        var r: Renderer = try .init(gpa, testing.io, testChoice(b), .{ .kitty = .{ .pair = 20 } });
        defer r.deinit();
        gpa.free(try draw(&r, frame, golden.rect));
        const again = try draw(&r, frame, golden.rect);
        defer gpa.free(again);
        switch (b) {
            .kitty => {
                try testing.expect(std.mem.indexOf(u8, again, "a=T,i=42,") != null);
                try testing.expect(std.mem.indexOf(u8, again, "a=d,d=i,i=41,") != null);
                // No margin clear: the rect didn't change.
                try testing.expect(!hasEch(again));
            },
            .halfblock, .ascii => try testing.expectEqualStrings("", again),
        }
    }
}

test "rect change, aspect change and resize force a full redraw with margin clear" {
    const gpa = testing.allocator;
    const frame = try golden.loadFrame60(gpa);
    defer gpa.free(frame.rgb);
    const moved: Rect = .{ .col = 2, .row = 1, .cols = 80, .rows = 24 };
    for ([_]Backend{ .kitty, .halfblock, .ascii }) |b| {
        var r: Renderer = try .init(gpa, testing.io, testChoice(b), .{});
        defer r.deinit();
        gpa.free(try draw(&r, frame, golden.rect));

        // Each of these must clear the margin (ECH) and redraw the box.
        var outs: [3][]u8 = undefined;
        outs[0] = try draw(&r, frame, moved);
        defer gpa.free(outs[0]);
        {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try r.present(&aw.writer, frame, moved, .{ .aspect = 4.0 / 3.0 });
            outs[1] = try aw.toOwnedSlice();
        }
        defer gpa.free(outs[1]);
        r.resize(golden.cell_px);
        {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            errdefer aw.deinit();
            try r.present(&aw.writer, frame, moved, .{ .aspect = 4.0 / 3.0 });
            outs[2] = try aw.toOwnedSlice();
        }
        defer gpa.free(outs[2]);

        for (outs) |out| {
            try testing.expect(std.mem.startsWith(u8, out, sgr.reset) and hasEch(out));
            switch (b) {
                .kitty => try testing.expect(std.mem.indexOf(u8, out, "a=T,") != null),
                // 55×24 at 8:7; 4:3 at 10×20 px cells fits 64×24.
                .halfblock, .ascii => try testing.expect((try golden.scan(out)).glyphs >= 55 * 24),
            }
        }
        // The 4:3 box is wider than the 8:7 one.
        if (b != .kitty) try testing.expectEqual(@as(usize, 64 * 24), (try golden.scan(outs[2])).glyphs);
    }
}

test "clear erases the rect; kitty also deletes its own images" {
    const gpa = testing.allocator;
    const px = [_]u8{ 9, 9, 9 };
    const frame: Frame = .{ .width = 1, .height = 1, .rgb = &px };
    const rect: Rect = .{ .col = 4, .row = 2, .cols = 3, .rows = 1 };
    const cases = [_]struct { Backend, []const u8 }{
        .{ .kitty, "\x1b_Ga=d,d=I,i=61,q=2\x1b\\\x1b[0m\x1b[2;4H\x1b[3X" },
        .{ .halfblock, "\x1b[0m\x1b[2;4H\x1b[3X" },
        .{ .ascii, "\x1b[0m\x1b[2;4H\x1b[3X" },
    };
    for (cases) |c| {
        var r: Renderer = try .init(gpa, testing.io, testChoice(c[0]), .{ .kitty = .{ .pair = 30 } });
        defer r.deinit();
        // Nothing drawn yet: nothing to clear.
        const none = try clearOut(&r);
        defer gpa.free(none);
        try testing.expectEqualStrings("", none);

        gpa.free(try draw(&r, frame, rect));
        const out = try clearOut(&r);
        defer gpa.free(out);
        try testing.expectEqualStrings(c[1], out);

        // After a clear, the next present is a full redraw again.
        const redraw = try draw(&r, frame, rect);
        defer gpa.free(redraw);
        try testing.expect(std.mem.startsWith(u8, redraw, "\x1b[0m"));
    }
}

test "empty frame or rect writes nothing through the interface" {
    const gpa = testing.allocator;
    const px = [_]u8{ 1, 2, 3 };
    for ([_]Backend{ .kitty, .halfblock, .ascii }) |b| {
        var r: Renderer = try .init(gpa, testing.io, testChoice(b), .{});
        defer r.deinit();
        const empty = try draw(&r, .{ .width = 0, .height = 0, .rgb = &.{} }, golden.rect);
        defer gpa.free(empty);
        try testing.expectEqualStrings("", empty);
        const no_rect = try draw(&r, .{ .width = 1, .height = 1, .rgb = &px }, .{ .cols = 0, .rows = 5 });
        defer gpa.free(no_rect);
        try testing.expectEqualStrings("", no_rect);
    }
}

/// The cells of an 80×24 screen that `out` printed a glyph into (CUP moves,
/// each glyph advances one column; other escapes, including ECH, print
/// nothing).
fn glyphCells(out: []const u8) ![24][80]bool {
    var cells: [24][80]bool = @splat(@splat(false));
    var row: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == 0x1b) {
            const start = i + 2;
            i = start;
            while (out[i] < 0x40 or out[i] > 0x7e) i += 1;
            if (out[i] == 'H') {
                const params = out[start..i];
                const semi = std.mem.indexOfScalar(u8, params, ';') orelse return error.BadCup;
                row = try std.fmt.parseInt(u32, params[0..semi], 10);
                col = try std.fmt.parseInt(u32, params[semi + 1 ..], 10);
            }
            i += 1;
            continue;
        }
        i += try std.unicode.utf8ByteSequenceLength(out[i]);
        cells[row - 1][col - 1] = true;
        col += 1;
    }
    return cells;
}

fn countCells(cells: [24][80]bool, in: ?Rect) usize {
    var n: usize = 0;
    for (cells, 1..) |line, r| for (line, 1..) |set, c| {
        if (!set) continue;
        if (in) |o| if (r < o.row or r >= o.row + o.rows or c < o.col or c >= o.col + o.cols) continue;
        n += 1;
    };
    return n;
}

fn drawWith(r: *Renderer, frame: Frame, rect: Rect, occlude: ?Rect) ![24][80]bool {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try r.present(&aw.writer, frame, rect, .{ .occlude = occlude });
    return glyphCells(aw.written());
}

test "fitted is the box present draws into" {
    const gpa = testing.allocator;
    const frame = try golden.loadFrame60(gpa);
    defer gpa.free(frame.rgb);
    for ([_]Backend{ .kitty, .halfblock, .ascii }) |b| {
        var r: Renderer = try .init(gpa, testing.io, testChoice(b), .{});
        defer r.deinit();
        try testing.expectEqual(Rect{ .col = 13, .row = 1, .cols = 55, .rows = 24 }, r.fitted(frame, golden.rect, null));
        try testing.expectEqual(Rect{ .col = 9, .row = 1, .cols = 64, .rows = 24 }, r.fitted(frame, golden.rect, 4.0 / 3.0));
        try testing.expect(r.fitted(.{ .width = 0, .height = 0, .rgb = &.{} }, golden.rect, null).isEmpty());
        try testing.expect(r.fitted(frame, .{ .cols = 0, .rows = 3 }, null).isEmpty());
    }
}

test "occlusion: covered cells are never drawn; uncovered ones are redrawn" {
    const gpa = testing.allocator;
    const frame = try golden.loadFrame60(gpa);
    defer gpa.free(frame.rgb);
    const inverted = try gpa.dupe(u8, frame.rgb);
    defer gpa.free(inverted);
    for (inverted) |*v| v.* ^= 0xff;
    const inv: Frame = .{ .width = frame.width, .height = frame.height, .rgb = inverted };
    // The overlay line: 20 cells at the box's top-left (box is 55×24 at col 13).
    const wide: Rect = .{ .col = 13, .row = 1, .cols = 20, .rows = 1 };
    const narrow: Rect = .{ .col = 13, .row = 1, .cols = 8, .rows = 1 };
    const box_cells = 55 * 24;
    for ([_]Backend{ .halfblock, .ascii }) |b| {
        var r: Renderer = try .init(gpa, testing.io, testChoice(b), .{});
        defer r.deinit();

        // First (full) present: everything but the overlay's cells.
        var cells = try drawWith(&r, frame, golden.rect, wide);
        try testing.expectEqual(box_cells - 20, countCells(cells, null));
        try testing.expectEqual(0, countCells(cells, wide));

        // Same frame and overlay: nothing.
        cells = try drawWith(&r, frame, golden.rect, wide);
        try testing.expectEqual(0, countCells(cells, null));

        // Every pixel changes under the overlay: still not drawn there.
        cells = try drawWith(&r, inv, golden.rect, wide);
        try testing.expectEqual(box_cells - 20, countCells(cells, null));
        try testing.expectEqual(0, countCells(cells, wide));

        // The overlay shrinks with the pixels unchanged: exactly the 12
        // uncovered cells are redrawn.
        cells = try drawWith(&r, inv, golden.rect, narrow);
        try testing.expectEqual(12, countCells(cells, null));
        try testing.expectEqual(12, countCells(cells, .{ .col = 21, .row = 1, .cols = 12, .rows = 1 }));

        // The overlay goes away: its 8 cells come back, nothing else.
        cells = try drawWith(&r, inv, golden.rect, null);
        try testing.expectEqual(8, countCells(cells, null));
        try testing.expectEqual(8, countCells(cells, narrow));
        cells = try drawWith(&r, inv, golden.rect, null);
        try testing.expectEqual(0, countCells(cells, null));
    }
}

test "occlusion outside the box, or overlapping its edge, is clipped" {
    const gpa = testing.allocator;
    const frame = try golden.loadFrame60(gpa);
    defer gpa.free(frame.rgb);
    for ([_]Backend{ .halfblock, .ascii }) |b| {
        var r: Renderer = try .init(gpa, testing.io, testChoice(b), .{});
        defer r.deinit();
        // Cols 1..20 of row 3: only box cols 13..20 (8 cells) are inside.
        const cells = try drawWith(&r, frame, golden.rect, .{ .col = 1, .row = 3, .cols = 20, .rows = 1 });
        try testing.expectEqual(55 * 24 - 8, countCells(cells, null));
    }
}

test "kitty: placements carry the choice's z-index" {
    const gpa = testing.allocator;
    const px = [_]u8{ 1, 2, 3 };
    const frame: Frame = .{ .width = 1, .height = 1, .rgb = &px };
    for ([_]i32{ caps.default_overlay_z, -1, 0 }) |z| {
        var choice = testChoice(.kitty);
        choice.kitty_z = z;
        var r: Renderer = try .init(gpa, testing.io, choice, .{});
        defer r.deinit();
        const out = try draw(&r, frame, .{ .cols = 2, .rows = 1 });
        defer gpa.free(out);
        var buf: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, ",z={d},", .{z});
        try testing.expectEqual(z != 0, std.mem.indexOf(u8, out, key) != null);
        try testing.expectEqual(z != 0, std.mem.indexOf(u8, out, ",z=") != null);
    }
}
