//! Deterministic synthetic game frames. Each scene is a pure function of
//! (frame index, resolution), and loops seamlessly every `loop_frames`
//! frames, so a cell can pre-render one loop and the timed loop only encodes
//! and writes.

const std = @import("std");
const cli = @import("cli.zig");

pub const Format = enum {
    rgb,
    rgba,

    pub fn bpp(f: Format) u32 {
        return switch (f) {
            .rgb => 3,
            .rgba => 4,
        };
    }
};

const tile = 16;
/// The tile map repeats every 8 tiles (128 px) and the scroll moves 1 px per
/// frame, so 128 frames is one seamless loop.
const map_tiles = 8;
pub const loop_frames = tile * map_tiles;

const sprite_size = 32;
/// 6 sprites change ≈10–15% of a 256×224 frame per frame.
const sprite_count = 6;

const Rgb = [3]u8;

/// Mid-range colours: shading adds -45..+45, so channels never saturate and
/// every scrolled pixel actually changes.
const palette = [_]Rgb{
    .{ 70, 120, 180 }, .{ 90, 160, 80 },  .{ 170, 110, 70 }, .{ 120, 90, 160 },
    .{ 180, 170, 90 }, .{ 80, 150, 150 }, .{ 150, 80, 100 }, .{ 110, 110, 110 },
};

const sprite_colors = [_]Rgb{
    .{ 240, 60, 60 }, .{ 60, 220, 90 }, .{ 70, 120, 250 }, .{ 250, 210, 40 }, .{ 230, 90, 230 }, .{ 40, 220, 230 },
};

fn hash(x: u32, y: u32) u32 {
    var h = (x *% 0x9E3779B1) ^ (y *% 0x85EBCA77);
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    return h;
}

/// A bevelled tile map: per-tile colour, diagonal gradient inside the tile.
fn background(x: u32, y: u32) Rgb {
    const base = palette[hash((x / tile) % map_tiles, (y / tile) % map_tiles) % palette.len];
    const shade: i32 = @intCast(((x % tile) + (y % tile)) * 3); // 0..90
    var px: Rgb = undefined;
    for (&px, base) |*o, b| o.* = @intCast(@as(i32, b) - 45 + shade);
    return px;
}

const Pos = struct { x: i32, y: i32 };

/// Lissajous paths with integer frequencies, so each sprite is back where it
/// started after `loop_frames`.
fn spritePos(i: u32, f: u32, w: u32, h: u32) Pos {
    const tau = 2 * std.math.pi;
    const t: f64 = @as(f64, @floatFromInt(f % loop_frames)) / loop_frames;
    const fi: f64 = @floatFromInt(i);
    const kx: f64 = @floatFromInt(1 + i % 2);
    const ky: f64 = @floatFromInt(1 + (i / 2) % 3);
    const ax: f64 = @floatFromInt((w - sprite_size) / 2 - 4);
    const ay: f64 = @floatFromInt((h - sprite_size) / 2 - 4);
    const cx: f64 = @floatFromInt((w - sprite_size) / 2);
    const cy: f64 = @floatFromInt((h - sprite_size) / 2);
    return .{
        .x = @intFromFloat(@round(cx + ax * @cos(tau * kx * t + fi))),
        .y = @intFromFloat(@round(cy + ay * @sin(tau * ky * t + 2 * fi))),
    };
}

/// A striped disc; null outside the disc (transparent).
fn spritePixel(i: u32, dx: u32, dy: u32) ?Rgb {
    const ex: i32 = @as(i32, @intCast(2 * dx)) - (sprite_size - 1);
    const ey: i32 = @as(i32, @intCast(2 * dy)) - (sprite_size - 1);
    if (ex * ex + ey * ey > sprite_size * sprite_size) return null;
    const c = sprite_colors[i % sprite_colors.len];
    if (((dx + dy) / 4) % 2 == 0) return c;
    return .{ c[0] / 2, c[1] / 2, c[2] / 2 };
}

fn put(out: []u8, idx: usize, bpp: u32, px: Rgb) void {
    const o = out[idx * bpp ..];
    o[0] = px[0];
    o[1] = px[1];
    o[2] = px[2];
    if (bpp == 4) o[3] = 255;
}

/// Renders frame `f` of `scene` into `out` (w*h*bpp bytes, row-major).
pub fn render(scene: cli.Scene, w: u32, h: u32, fmt: Format, f: u32, out: []u8) void {
    const bpp = fmt.bpp();
    std.debug.assert(out.len == @as(usize, w) * h * bpp);
    const shift: u32 = if (scene == .scroll) f % loop_frames else 0;
    for (0..h) |y| for (0..w) |x| {
        const px = background(@as(u32, @intCast(x)) + shift, @as(u32, @intCast(y)) + shift);
        put(out, y * w + x, bpp, px);
    };
    if (scene != .sprites) return;
    for (0..sprite_count) |si| {
        const i: u32 = @intCast(si);
        const p = spritePos(i, f, w, h);
        for (0..sprite_size) |dy| for (0..sprite_size) |dx| {
            const x = p.x + @as(i32, @intCast(dx));
            const y = p.y + @as(i32, @intCast(dy));
            if (x < 0 or y < 0 or x >= w or y >= h) continue;
            const px = spritePixel(i, @intCast(dx), @intCast(dy)) orelse continue;
            put(out, @as(usize, @intCast(y)) * w + @as(usize, @intCast(x)), bpp, px);
        };
    }
}

/// One pre-rendered loop of a scene at one resolution and pixel format.
pub const Loop = struct {
    data: []u8,
    frame_len: usize,
    width: u32,
    height: u32,
    fmt: Format,

    pub fn init(gpa: std.mem.Allocator, scene: cli.Scene, res: cli.Res, fmt: Format) !Loop {
        const w = res.width();
        const h = res.height();
        const frame_len = @as(usize, w) * h * fmt.bpp();
        const data = try gpa.alloc(u8, frame_len * loop_frames);
        for (0..loop_frames) |f| render(scene, w, h, fmt, @intCast(f), data[f * frame_len ..][0..frame_len]);
        return .{ .data = data, .frame_len = frame_len, .width = w, .height = h, .fmt = fmt };
    }

    pub fn deinit(l: *Loop, gpa: std.mem.Allocator) void {
        gpa.free(l.data);
        l.* = undefined;
    }

    pub fn frame(l: *const Loop, i: u64) []const u8 {
        return l.data[@intCast((i % loop_frames) * l.frame_len)..][0..l.frame_len];
    }
};

fn changedRatio(a: []const u8, b: []const u8, bpp: u32) f64 {
    var changed: usize = 0;
    var i: usize = 0;
    while (i < a.len) : (i += bpp) {
        if (!std.mem.eql(u8, a[i..][0..bpp], b[i..][0..bpp])) changed += 1;
    }
    return @as(f64, @floatFromInt(changed)) / @as(f64, @floatFromInt(a.len / bpp));
}

test "scenes are deterministic and loop seamlessly" {
    const gpa = std.testing.allocator;
    for ([_]cli.Scene{ .scroll, .sprites }) |scene| {
        var l = try Loop.init(gpa, scene, .@"256x224", .rgb);
        defer l.deinit(gpa);
        const again = try gpa.alloc(u8, l.frame_len);
        defer gpa.free(again);
        render(scene, 256, 224, .rgb, 37, again);
        try std.testing.expectEqualSlices(u8, l.frame(37), again);
        render(scene, 256, 224, .rgb, loop_frames, again);
        try std.testing.expectEqualSlices(u8, l.frame(0), again);
        try std.testing.expectEqualSlices(u8, l.frame(5), l.frame(5 + loop_frames));
    }
}

test "rgba matches rgb with opaque alpha" {
    const gpa = std.testing.allocator;
    var rgb = try Loop.init(gpa, .sprites, .@"320x240", .rgb);
    defer rgb.deinit(gpa);
    var rgba = try Loop.init(gpa, .sprites, .@"320x240", .rgba);
    defer rgba.deinit(gpa);
    const a = rgb.frame(9);
    const b = rgba.frame(9);
    for (0..320 * 240) |p| {
        try std.testing.expectEqualSlices(u8, a[p * 3 ..][0..3], b[p * 4 ..][0..3]);
        try std.testing.expectEqual(@as(u8, 255), b[p * 4 + 3]);
    }
}

test "changed-pixel ratio: scroll ≈100%, sprites ≈10%" {
    const gpa = std.testing.allocator;
    for ([_]cli.Res{ .@"256x224", .@"320x240" }) |res| {
        var scroll = try Loop.init(gpa, .scroll, res, .rgb);
        defer scroll.deinit(gpa);
        var sprites = try Loop.init(gpa, .sprites, res, .rgb);
        defer sprites.deinit(gpa);
        var s_min: f64 = 1;
        var p_min: f64 = 1;
        var p_max: f64 = 0;
        for (0..loop_frames) |f| {
            s_min = @min(s_min, changedRatio(scroll.frame(f), scroll.frame(f + 1), 3));
            const r = changedRatio(sprites.frame(f), sprites.frame(f + 1), 3);
            p_min = @min(p_min, r);
            p_max = @max(p_max, r);
        }
        try std.testing.expect(s_min > 0.95);
        try std.testing.expect(p_min > 0.03 and p_max < 0.2);
    }
}
