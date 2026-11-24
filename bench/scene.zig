//! Frame sources for the bench: two synthetic scenes ported from spike 02's
//! termbench (`scroll`: every pixel changes each frame; `sprites`: ≈10 %
//! changes), and the in-repo test core (D14). Each is pre-rendered into one
//! loop of RGB24 frames, so the timed loop only encodes and writes.

const std = @import("std");
const temui = @import("temui");
const host = temui.host;

pub const Source = enum { scroll, sprites, testcore };

const tile = 16;
/// The tile map repeats every 8 tiles (128 px) and the scroll moves 1 px per
/// frame, so 128 frames is one seamless loop.
const map_tiles = 8;
pub const loop_frames = tile * map_tiles;

const sprite_size = 32;
/// 6 sprites change ≈10–15 % of a 256×224 frame per frame.
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
    const ax: f64 = @floatFromInt((w -| sprite_size) / 2 -| 4);
    const ay: f64 = @floatFromInt((h -| sprite_size) / 2 -| 4);
    const cx: f64 = @floatFromInt((w -| sprite_size) / 2);
    const cy: f64 = @floatFromInt((h -| sprite_size) / 2);
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

fn put(out: []u8, idx: usize, px: Rgb) void {
    out[idx * 3 ..][0..3].* = px;
}

/// Renders frame `f` of a synthetic scene into `out` (w*h*3 bytes, RGB24).
pub fn render(scene: Source, w: u32, h: u32, f: u32, out: []u8) void {
    std.debug.assert(scene != .testcore);
    std.debug.assert(out.len == @as(usize, w) * h * 3);
    const shift: u32 = if (scene == .scroll) f % loop_frames else 0;
    for (0..h) |y| for (0..w) |x| {
        put(out, y * w + x, background(@as(u32, @intCast(x)) + shift, @as(u32, @intCast(y)) + shift));
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
            put(out, @as(usize, @intCast(y)) * w + @as(usize, @intCast(x)), px);
        };
    }
}

/// Where to find the test core, for `Source.testcore`.
pub const TestCore = struct {
    core_path: []const u8,
    rom_path: []const u8,
    /// Save/system directory handed to the core.
    scratch_dir: []const u8,
};

/// The test core's moving bar crosses its 256-px frame in 256 frames.
pub const testcore_frames = 256;

/// One pre-rendered loop of RGB24 frames.
pub const Loop = struct {
    data: []u8,
    frame_len: usize,
    count: usize,
    width: u32,
    height: u32,

    /// A synthetic scene at `w`×`h`.
    pub fn initScene(gpa: std.mem.Allocator, scene: Source, w: u32, h: u32) !Loop {
        const frame_len = @as(usize, w) * h * 3;
        const data = try gpa.alloc(u8, frame_len * loop_frames);
        for (0..loop_frames) |f| render(scene, w, h, @intCast(f), data[f * frame_len ..][0..frame_len]);
        return .{ .data = data, .frame_len = frame_len, .count = loop_frames, .width = w, .height = h };
    }

    /// Frames 1–256 of the test core (its native 256×224).
    pub fn initTestCore(gpa: std.mem.Allocator, io: std.Io, tc: TestCore) !Loop {
        var diag: host.Diagnostic = .{};
        host.load(gpa, io, .{
            .core_path = tc.core_path,
            .rom_path = tc.rom_path,
            .system_dir = tc.scratch_dir,
            .save_dir = tc.scratch_dir,
        }, &diag) catch |err| {
            std.log.err("test core: {s}", .{if (diag.len > 0) diag.message() else @errorName(err)});
            return err;
        };
        defer host.unload();

        try host.runFrame();
        _ = host.drainAudio();
        const first = host.frame();
        const frame_len = @as(usize, first.width) * first.height * 3;
        if (frame_len == 0) return error.NoVideo;
        const data = try gpa.alloc(u8, frame_len * testcore_frames);
        errdefer gpa.free(data);
        for (0..testcore_frames) |i| {
            if (i > 0) {
                try host.runFrame();
                _ = host.drainAudio();
            }
            const f = host.frame();
            if (f.rgb.len != frame_len) return error.FrameSizeChanged;
            @memcpy(data[i * frame_len ..][0..frame_len], f.rgb);
        }
        return .{ .data = data, .frame_len = frame_len, .count = testcore_frames, .width = @intCast(first.width), .height = @intCast(first.height) };
    }

    pub fn deinit(l: *Loop, gpa: std.mem.Allocator) void {
        gpa.free(l.data);
        l.* = undefined;
    }

    pub fn frame(l: *const Loop, i: u64) temui.render.Renderer.Frame {
        return .{
            .width = l.width,
            .height = l.height,
            .rgb = l.data[@intCast((i % l.count) * l.frame_len)..][0..l.frame_len],
        };
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn changedRatio(a: []const u8, b: []const u8) f64 {
    var changed: usize = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 3) {
        if (!std.mem.eql(u8, a[i..][0..3], b[i..][0..3])) changed += 1;
    }
    return @as(f64, @floatFromInt(changed)) / @as(f64, @floatFromInt(a.len / 3));
}

test "scenes are deterministic and loop seamlessly" {
    const gpa = testing.allocator;
    for ([_]Source{ .scroll, .sprites }) |scene| {
        var l = try Loop.initScene(gpa, scene, 256, 224);
        defer l.deinit(gpa);
        const again = try gpa.alloc(u8, l.frame_len);
        defer gpa.free(again);
        render(scene, 256, 224, 37, again);
        try testing.expectEqualSlices(u8, l.frame(37).rgb, again);
        render(scene, 256, 224, loop_frames, again);
        try testing.expectEqualSlices(u8, l.frame(0).rgb, again);
        try testing.expectEqualSlices(u8, l.frame(5).rgb, l.frame(5 + loop_frames).rgb);
    }
}

test "changed-pixel ratio: scroll ≈100%, sprites ≈10%" {
    const gpa = testing.allocator;
    for ([_][2]u32{ .{ 256, 224 }, .{ 320, 240 } }) |res| {
        var scroll = try Loop.initScene(gpa, .scroll, res[0], res[1]);
        defer scroll.deinit(gpa);
        var sprites = try Loop.initScene(gpa, .sprites, res[0], res[1]);
        defer sprites.deinit(gpa);
        var s_min: f64 = 1;
        var p_min: f64 = 1;
        var p_max: f64 = 0;
        for (0..loop_frames) |f| {
            s_min = @min(s_min, changedRatio(scroll.frame(f).rgb, scroll.frame(f + 1).rgb));
            const r = changedRatio(sprites.frame(f).rgb, sprites.frame(f + 1).rgb);
            p_min = @min(p_min, r);
            p_max = @max(p_max, r);
        }
        try testing.expect(s_min > 0.95);
        try testing.expect(p_min > 0.03 and p_max < 0.2);
    }
}

test "test core loop: 256 frames of 256x224, consecutive frames differ" {
    const opts = @import("bench_options");
    const gpa = testing.allocator;
    var l = try Loop.initTestCore(gpa, testing.io, .{
        .core_path = opts.test_core_path,
        .rom_path = opts.testcore_rom,
        .scratch_dir = temui.render.kitty.defaultTmpDir(),
    });
    defer l.deinit(gpa);
    try testing.expectEqual(@as(u32, 256), l.width);
    try testing.expectEqual(@as(u32, 224), l.height);
    try testing.expectEqual(@as(usize, testcore_frames), l.count);
    try testing.expect(!std.mem.eql(u8, l.frame(0).rgb, l.frame(1).rgb));
}
