//! temui's test core (D14): a tiny, deterministic libretro core used by every
//! test that needs a core, so CI never downloads one. MIT, like temui.
//!
//! - Video: 256×224 at 60 fps in the pixel format chosen by the core option
//!   `temui_test_pixel_format` (xrgb8888 | rgb565 | 0rgb1555). Integer math
//!   only, so frames are byte-identical on every target.
//! - Audio: a 440 Hz sine, 48 kHz stereo, 800 frames per video frame.
//! - Input: one indicator box per RetroPad button on port 0.
//! - SRAM: 8 KiB; the frame counter (u32 LE) at 0, the input bitmask (u16 LE) at 4.
//! - Content: required; its CRC32 selects the colour-bar rotation and is shown
//!   as a 32-bit strip.
//!
//! All game state is reset in `retro_init` and `retro_load_game`, never by
//! static initialisers: `dlclose` may not unload the library (macOS), and
//! tests load the core several times in one process.

const std = @import("std");
const c = @import("libretro");

pub const width = 256;
pub const height = 224;
pub const fps = 60;
pub const sample_rate = 48000;
pub const audio_frames = sample_rate / fps; // 800
pub const sram_size = 8192;
pub const option_key = "temui_test_pixel_format";

const tone_hz = 440;
/// Phase step per sample in 2^32 units per cycle.
const phase_step: u32 = @intCast((@as(u64, tone_hz) << 32) / sample_rate);
const sine_table: [256]i16 = blk: {
    var t: [256]i16 = undefined;
    for (&t, 0..) |*s, i| {
        const x = @as(f64, @floatFromInt(i)) * 2.0 * std.math.pi / 256.0;
        s.* = @intFromFloat(@round(@sin(x) * 8192.0));
    }
    break :blk t;
};

const Format = enum { xrgb8888, rgb565, rgb1555 };

// Layout (rows).
const bars_end = 160;
const seed_strip = .{ 160, 176 };
const gradient = .{ 176, 192 };
const boxes = .{ 200, 216 };

/// Callbacks are set by the host through `retro_set_*` before they're used, on
/// every load, so they live outside `Game`.
var cb: struct {
    env: c.retro_environment_t = null,
    video: c.retro_video_refresh_t = null,
    audio_sample: c.retro_audio_sample_t = null,
    audio_batch: c.retro_audio_sample_batch_t = null,
    input_poll: c.retro_input_poll_t = null,
    input_state: c.retro_input_state_t = null,
    log: c.retro_log_printf_t = null,
} = .{};

const Game = struct {
    loaded: bool,
    format: Format,
    seed: u32,
    frame: u32,
    phase: u32,
    sram: [sram_size]u8,
};

var game: Game = undefined;
var video_buf: [width * height * 4]u8 = undefined;
var audio_buf: [audio_frames * 2]i16 = undefined;

const save_version: u8 = 1;
const save_size = 1 + 4 + 4 + 4 + sram_size;

fn resetGame() void {
    game = .{ .loaded = false, .format = .xrgb8888, .seed = 0, .frame = 0, .phase = 0, .sram = @splat(0) };
}

fn env(cmd: c_int, data: ?*anyopaque) bool {
    const f = cb.env orelse return false;
    return f(@intCast(cmd), data);
}

fn log(level: c_int, comptime fmt: [*:0]const u8, args: anytype) void {
    const f = cb.log orelse return;
    @call(.auto, f, .{ @as(c.enum_retro_log_level, @intCast(level)), fmt } ++ args);
}

// ---- libretro API -----------------------------------------------------------

export fn retro_api_version() c_uint {
    return c.RETRO_API_VERSION;
}

export fn retro_set_environment(f: c.retro_environment_t) void {
    cb.env = f;
    cb.log = null;
    const vars = [_]c.struct_retro_variable{
        .{ .key = option_key, .value = "Pixel format; xrgb8888|rgb565|0rgb1555" },
        .{ .key = null, .value = null },
    };
    _ = env(c.RETRO_ENVIRONMENT_SET_VARIABLES, @constCast(@ptrCast(&vars)));
    var log_cb: c.struct_retro_log_callback = .{};
    if (env(c.RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &log_cb)) cb.log = log_cb.log;
}

export fn retro_set_video_refresh(f: c.retro_video_refresh_t) void {
    cb.video = f;
}
export fn retro_set_audio_sample(f: c.retro_audio_sample_t) void {
    cb.audio_sample = f;
}
export fn retro_set_audio_sample_batch(f: c.retro_audio_sample_batch_t) void {
    cb.audio_batch = f;
}
export fn retro_set_input_poll(f: c.retro_input_poll_t) void {
    cb.input_poll = f;
}
export fn retro_set_input_state(f: c.retro_input_state_t) void {
    cb.input_state = f;
}

export fn retro_init() void {
    resetGame();
}

export fn retro_deinit() void {
    resetGame();
}

export fn retro_get_system_info(info: ?*c.struct_retro_system_info) void {
    const i = info orelse return;
    i.* = .{
        .library_name = "temui test core",
        .library_version = "1",
        .valid_extensions = null,
        .need_fullpath = false,
        .block_extract = false,
    };
}

export fn retro_get_system_av_info(info: ?*c.struct_retro_system_av_info) void {
    const i = info orelse return;
    i.* = .{
        .geometry = .{
            .base_width = width,
            .base_height = height,
            .max_width = width,
            .max_height = height,
            .aspect_ratio = 0,
        },
        .timing = .{ .fps = fps, .sample_rate = sample_rate },
    };
}

export fn retro_set_controller_port_device(port: c_uint, device: c_uint) void {
    _ = port;
    _ = device;
}

export fn retro_reset() void {
    game.frame = 0;
    game.phase = 0;
}

export fn retro_load_game(info: ?*const c.struct_retro_game_info) bool {
    resetGame();
    const gi = info orelse {
        log(c.RETRO_LOG_ERROR, "temui test core: content is required\n", .{});
        return false;
    };
    const data_ptr = gi.data orelse {
        log(c.RETRO_LOG_ERROR, "temui test core: content data is required (need_fullpath is false)\n", .{});
        return false;
    };
    const data = @as([*]const u8, @ptrCast(data_ptr))[0..gi.size];
    game.seed = std.hash.Crc32.hash(data);

    var v: c.struct_retro_variable = .{ .key = option_key, .value = null };
    if (env(c.RETRO_ENVIRONMENT_GET_VARIABLE, &v) and v.value != null) {
        const value = std.mem.span(v.value);
        game.format = if (std.mem.eql(u8, value, "rgb565"))
            .rgb565
        else if (std.mem.eql(u8, value, "0rgb1555"))
            .rgb1555
        else
            .xrgb8888;
    }
    // 0RGB1555 is the libretro default, so it is used without asking.
    switch (game.format) {
        .rgb1555 => {},
        .rgb565, .xrgb8888 => {
            var pf: c.enum_retro_pixel_format = if (game.format == .rgb565) c.RETRO_PIXEL_FORMAT_RGB565 else c.RETRO_PIXEL_FORMAT_XRGB8888;
            if (!env(c.RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &pf)) {
                log(c.RETRO_LOG_ERROR, "temui test core: pixel format refused\n", .{});
                return false;
            }
        },
    }
    game.loaded = true;
    log(c.RETRO_LOG_INFO, "temui test core: loaded %u bytes, crc32 %08x, format %s\n", .{
        @as(c_uint, @intCast(data.len)),
        @as(c_uint, game.seed),
        @as([*:0]const u8, @tagName(game.format)),
    });
    return true;
}

export fn retro_load_game_special(game_type: c_uint, info: ?*const c.struct_retro_game_info, num_info: usize) bool {
    _ = game_type;
    _ = info;
    _ = num_info;
    return false;
}

export fn retro_unload_game() void {
    game.loaded = false;
}

export fn retro_get_region() c_uint {
    return c.RETRO_REGION_NTSC;
}

export fn retro_run() void {
    if (!game.loaded) return;
    if (cb.input_poll) |f| f();
    var buttons: u16 = 0;
    if (cb.input_state) |f| {
        for (0..16) |id| {
            if (f(0, c.RETRO_DEVICE_JOYPAD, 0, @intCast(id)) != 0) buttons |= @as(u16, 1) << @intCast(id);
        }
    }

    game.frame +%= 1;
    std.mem.writeInt(u32, game.sram[0..4], game.frame, .little);
    std.mem.writeInt(u16, game.sram[4..6], buttons, .little);

    const pitch = drawFrame(buttons);
    if (cb.video) |f| f(&video_buf, width, height, pitch);

    for (0..audio_frames) |i| {
        const s = sine_table[game.phase >> 24];
        audio_buf[i * 2] = s;
        audio_buf[i * 2 + 1] = s;
        game.phase +%= phase_step;
    }
    if (cb.audio_batch) |f| _ = f(&audio_buf, audio_frames);
}

export fn retro_serialize_size() usize {
    return save_size;
}

export fn retro_serialize(data: ?*anyopaque, size: usize) bool {
    if (size < save_size) return false;
    const out = @as([*]u8, @ptrCast(data orelse return false))[0..save_size];
    out[0] = save_version;
    std.mem.writeInt(u32, out[1..5], game.frame, .little);
    std.mem.writeInt(u32, out[5..9], game.seed, .little);
    std.mem.writeInt(u32, out[9..13], game.phase, .little);
    @memcpy(out[13..], &game.sram);
    return true;
}

export fn retro_unserialize(data: ?*const anyopaque, size: usize) bool {
    if (size != save_size) return false;
    const in = @as([*]const u8, @ptrCast(data orelse return false))[0..save_size];
    if (in[0] != save_version) return false;
    game.frame = std.mem.readInt(u32, in[1..5], .little);
    game.seed = std.mem.readInt(u32, in[5..9], .little);
    game.phase = std.mem.readInt(u32, in[9..13], .little);
    @memcpy(&game.sram, in[13..]);
    return true;
}

export fn retro_cheat_reset() void {}

export fn retro_cheat_set(index: c_uint, enabled: bool, code: [*c]const u8) void {
    _ = index;
    _ = enabled;
    _ = code;
}

export fn retro_get_memory_data(id: c_uint) ?*anyopaque {
    return if (id == c.RETRO_MEMORY_SAVE_RAM) &game.sram else null;
}

export fn retro_get_memory_size(id: c_uint) usize {
    return if (id == c.RETRO_MEMORY_SAVE_RAM) sram_size else 0;
}

// ---- drawing ----------------------------------------------------------------

const Rgb = struct { r: u8, g: u8, b: u8 };

/// SMPTE-like bars: white, yellow, cyan, green, magenta, red, blue, black.
const bar_colors = [8]Rgb{
    .{ .r = 255, .g = 255, .b = 255 }, .{ .r = 255, .g = 255, .b = 0 },
    .{ .r = 0, .g = 255, .b = 255 },   .{ .r = 0, .g = 255, .b = 0 },
    .{ .r = 255, .g = 0, .b = 255 },   .{ .r = 255, .g = 0, .b = 0 },
    .{ .r = 0, .g = 0, .b = 255 },     .{ .r = 0, .g = 0, .b = 0 },
};

fn pixelAt(x: u32, y: u32, buttons: u16) Rgb {
    if (y < bars_end) {
        // The moving bar: column (frame - 1) mod 256, inverted.
        const bar = bar_colors[((x / 32) + game.seed % 8) % 8];
        if (x == (game.frame -% 1) % width) return .{ .r = 255 - bar.r, .g = 255 - bar.g, .b = 255 - bar.b };
        return bar;
    }
    if (y >= seed_strip[0] and y < seed_strip[1]) {
        // 32 cells of 8 px, most significant bit first: white = 1.
        const bit = (game.seed >> @intCast(31 - x / 8)) & 1;
        return if (bit == 1) .{ .r = 255, .g = 255, .b = 255 } else .{ .r = 0, .g = 0, .b = 0 };
    }
    if (y >= gradient[0] and y < gradient[1]) {
        const v: u8 = @intCast(x);
        return .{ .r = v, .g = v, .b = v };
    }
    if (y >= boxes[0] and y < boxes[1]) {
        // 16 boxes, 14 px wide with a 2 px gap.
        if (x % 16 >= 14) return .{ .r = 0, .g = 0, .b = 0 };
        const held = (buttons >> @intCast(x / 16)) & 1 == 1;
        return if (held) .{ .r = 255, .g = 255, .b = 255 } else .{ .r = 48, .g = 48, .b = 48 };
    }
    return .{ .r = 0, .g = 0, .b = 0 };
}

/// Draws the frame into `video_buf` in the current format; returns the pitch.
fn drawFrame(buttons: u16) usize {
    const bpp: usize = if (game.format == .xrgb8888) 4 else 2;
    const pitch = width * bpp;
    for (0..height) |y| {
        for (0..width) |x| {
            const p = pixelAt(@intCast(x), @intCast(y), buttons);
            const off = y * pitch + x * bpp;
            switch (game.format) {
                .xrgb8888 => std.mem.writeInt(u32, video_buf[off..][0..4], (@as(u32, p.r) << 16) | (@as(u32, p.g) << 8) | p.b, .little),
                .rgb565 => std.mem.writeInt(u16, video_buf[off..][0..2], (@as(u16, p.r >> 3) << 11) | (@as(u16, p.g >> 2) << 5) | (p.b >> 3), .little),
                .rgb1555 => std.mem.writeInt(u16, video_buf[off..][0..2], (@as(u16, p.r >> 3) << 10) | (@as(u16, p.g >> 3) << 5) | (p.b >> 3), .little),
            }
        }
    }
    return pitch;
}
