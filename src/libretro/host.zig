//! The libretro host engine (D3). libretro callbacks carry no context pointer,
//! so the host is process-wide: one loaded core per process (D5). Callers
//! drive it through the functions below; the callbacks convert video into
//! packed RGB888 and buffer audio for the caller to drain.

const std = @import("std");
const c = @import("libretro");
const DynLib = @import("DynLib.zig");
const env = @import("env.zig");
const pixels = @import("pixels.zig");
const core_log = @import("core_log.zig");

const log = std.log.scoped(.libretro);

pub const Config = struct {
    core_path: []const u8,
    rom_path: []const u8,
    /// Returned by `GET_SYSTEM_DIRECTORY` (BIOS files etc.).
    system_dir: []const u8,
    /// Returned by `GET_SAVE_DIRECTORY`.
    save_dir: []const u8,
    /// `--option` overrides, applied to the core's declared options.
    options: []const env.Override = &.{},
};

/// The one-line reason a `load` failed.
pub const Diagnostic = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(&d.buf);
        w.print(fmt, args) catch {};
        d.len = w.end;
    }
};

pub const LoadError = error{
    AlreadyLoaded,
    CoreOpenFailed,
    MissingSymbol,
    ApiVersionMismatch,
    RomReadFailed,
    LoadGameFailed,
    OutOfMemory,
};

/// Content larger than this is refused when the core wants it in memory.
const max_rom_bytes = 1 << 30;

/// RetroPad buttons, indexed by `RETRO_DEVICE_ID_JOYPAD_*`.
pub const Buttons = [16]bool;

pub const Frame = struct {
    width: usize,
    height: usize,
    /// Packed RGB888, `width * height * 3` bytes. Valid until the next
    /// `runFrame` or `unload`.
    rgb: []const u8,
};

pub const SystemInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// Every `retro_*` entry point, resolved by name when a core is opened. The
/// types are spelled out rather than taken from the header's `extern fn`
/// declarations: referencing those makes some backends (x86_64 debug) emit
/// relocations against symbols that temui itself never defines.
const Symbols = struct {
    retro_set_environment: *const fn (c.retro_environment_t) callconv(.c) void,
    retro_set_video_refresh: *const fn (c.retro_video_refresh_t) callconv(.c) void,
    retro_set_audio_sample: *const fn (c.retro_audio_sample_t) callconv(.c) void,
    retro_set_audio_sample_batch: *const fn (c.retro_audio_sample_batch_t) callconv(.c) void,
    retro_set_input_poll: *const fn (c.retro_input_poll_t) callconv(.c) void,
    retro_set_input_state: *const fn (c.retro_input_state_t) callconv(.c) void,
    retro_init: *const fn () callconv(.c) void,
    retro_deinit: *const fn () callconv(.c) void,
    retro_api_version: *const fn () callconv(.c) c_uint,
    retro_get_system_info: *const fn (*c.struct_retro_system_info) callconv(.c) void,
    retro_get_system_av_info: *const fn (*c.struct_retro_system_av_info) callconv(.c) void,
    retro_set_controller_port_device: *const fn (c_uint, c_uint) callconv(.c) void,
    retro_reset: *const fn () callconv(.c) void,
    retro_run: *const fn () callconv(.c) void,
    retro_serialize_size: *const fn () callconv(.c) usize,
    retro_serialize: *const fn (?*anyopaque, usize) callconv(.c) bool,
    retro_unserialize: *const fn (?*const anyopaque, usize) callconv(.c) bool,
    retro_cheat_reset: *const fn () callconv(.c) void,
    retro_cheat_set: *const fn (c_uint, bool, [*c]const u8) callconv(.c) void,
    retro_load_game: *const fn (*const c.struct_retro_game_info) callconv(.c) bool,
    retro_load_game_special: *const fn (c_uint, [*c]const c.struct_retro_game_info, usize) callconv(.c) bool,
    retro_unload_game: *const fn () callconv(.c) void,
    retro_get_region: *const fn () callconv(.c) c_uint,
    retro_get_memory_data: *const fn (c_uint) callconv(.c) ?*anyopaque,
    retro_get_memory_size: *const fn (c_uint) callconv(.c) usize,
};

/// Resolves every field of `Symbols` through `lookup`. On a miss, `missing` is
/// set to the symbol's name.
fn resolveSymbols(
    ctx: anytype,
    comptime lookup: fn (@TypeOf(ctx), [:0]const u8) ?*anyopaque,
    missing: *[]const u8,
) error{MissingSymbol}!Symbols {
    var s: Symbols = undefined;
    inline for (@typeInfo(Symbols).@"struct".field_names) |name| {
        const p = lookup(ctx, name) orelse {
            missing.* = name;
            return error.MissingSymbol;
        };
        @field(s, name) = @ptrCast(@alignCast(p));
    }
    return s;
}

fn lookupLib(lib: *const DynLib, name: [:0]const u8) ?*anyopaque {
    return lib.lookup(name);
}

const State = struct {
    gpa: std.mem.Allocator,
    lib: DynLib,
    sym: Symbols,
    options: env.Options,
    seen: env.SeenSet = .{},
    system_dir: [:0]const u8,
    save_dir: [:0]const u8,
    rom_path: [:0]const u8,
    /// Kept until unload: some cores read the content after `retro_load_game`.
    rom_data: ?[]u8,
    info: c.struct_retro_system_info,
    av: c.struct_retro_system_av_info = .{},
    /// The libretro default until the core asks for another.
    format: pixels.Format = .rgb1555,
    support_no_game: bool = false,
    rgb: std.ArrayList(u8) = .empty,
    frame_w: usize = 0,
    frame_h: usize = 0,
    audio: std.ArrayList(i16) = .empty,
    buttons: Buttons = @splat(false),
    /// Set by a callback that could not allocate; returned by `runFrame`.
    oom: bool = false,

    fn deinit(s: *State) void {
        const gpa = s.gpa;
        s.options.deinit();
        gpa.free(s.system_dir);
        gpa.free(s.save_dir);
        gpa.free(s.rom_path);
        if (s.rom_data) |d| gpa.free(d);
        s.rgb.deinit(gpa);
        s.audio.deinit(gpa);
    }
};

var state: ?State = null;

/// Opens the core at `config.core_path` and loads `config.rom_path` into it.
/// On failure, everything done so far is undone and `diag` holds a one-line
/// reason.
pub fn load(gpa: std.mem.Allocator, io: std.Io, config: Config, diag: *Diagnostic) LoadError!void {
    if (state != null) {
        diag.set("a core is already loaded", .{});
        return error.AlreadyLoaded;
    }

    var reason_buf: [768]u8 = undefined;
    var reason: std.Io.Writer = .fixed(&reason_buf);
    var lib = DynLib.open(gpa, config.core_path, &reason) catch |err| switch (err) {
        error.OpenFailed => {
            diag.set("cannot load core {s}: {s}", .{ config.core_path, reason.buffered() });
            return error.CoreOpenFailed;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer lib.close();

    var missing: []const u8 = "";
    const sym = resolveSymbols(&lib, lookupLib, &missing) catch {
        diag.set("{s} is not a libretro core: missing symbol {s}", .{ config.core_path, missing });
        return error.MissingSymbol;
    };
    const api = sym.retro_api_version();
    if (api != c.RETRO_API_VERSION) {
        diag.set("{s}: libretro API version {d}, expected {d}", .{ config.core_path, api, c.RETRO_API_VERSION });
        return error.ApiVersionMismatch;
    }

    // Allowed before retro_init, and tells us how the core wants the content.
    var info: c.struct_retro_system_info = .{};
    sym.retro_get_system_info(&info);

    // Callbacks need the state from here on: retro_set_environment calls back
    // straight away (SET_VARIABLES, GET_LOG_INTERFACE).
    state = try initState(gpa, io, config, lib, sym, info, diag);
    errdefer {
        state.?.deinit();
        state = null;
    }
    const s = &state.?;
    const rom_path = s.rom_path;
    const rom_data = s.rom_data;

    sym.retro_set_environment(&environment);
    sym.retro_set_video_refresh(&videoRefresh);
    sym.retro_set_audio_sample(&audioSample);
    sym.retro_set_audio_sample_batch(&audioSampleBatch);
    sym.retro_set_input_poll(&inputPoll);
    sym.retro_set_input_state(&inputState);
    sym.retro_init();
    errdefer sym.retro_deinit();

    const game: c.struct_retro_game_info = .{
        .path = rom_path.ptr,
        .data = if (rom_data) |d| d.ptr else null,
        .size = if (rom_data) |d| d.len else 0,
        .meta = null,
    };
    if (!sym.retro_load_game(&game)) {
        diag.set("{s} could not load {s} (see the log)", .{ config.core_path, config.rom_path });
        return error.LoadGameFailed;
    }
    errdefer sym.retro_unload_game();

    sym.retro_get_system_av_info(&s.av);
    try s.options.validate();
    log.info("loaded {s} {s} with {s}: {d}x{d} at {d:.3} fps, {d} Hz, {s}", .{
        cstr(info.library_name),
        cstr(info.library_version),
        config.rom_path,
        s.av.geometry.base_width,
        s.av.geometry.base_height,
        s.av.timing.fps,
        s.av.timing.sample_rate,
        s.format.name(),
    });
}

/// Everything `State` owns, allocated with nothing left behind on failure.
fn initState(
    gpa: std.mem.Allocator,
    io: std.Io,
    config: Config,
    lib: DynLib,
    sym: Symbols,
    info: c.struct_retro_system_info,
    diag: *Diagnostic,
) LoadError!State {
    const rom_data: ?[]u8 = if (info.need_fullpath) null else std.Io.Dir.cwd().readFileAlloc(
        io,
        config.rom_path,
        gpa,
        .limited(max_rom_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.set("cannot read {s}: {t}", .{ config.rom_path, err });
            return error.RomReadFailed;
        },
    };
    errdefer if (rom_data) |d| gpa.free(d);
    var options: env.Options = try .init(gpa, config.options);
    errdefer options.deinit();
    const system_dir = try gpa.dupeSentinel(u8, config.system_dir, 0);
    errdefer gpa.free(system_dir);
    const save_dir = try gpa.dupeSentinel(u8, config.save_dir, 0);
    errdefer gpa.free(save_dir);
    const rom_path = try gpa.dupeSentinel(u8, config.rom_path, 0);
    return .{
        .gpa = gpa,
        .lib = lib,
        .sym = sym,
        .options = options,
        .system_dir = system_dir,
        .save_dir = save_dir,
        .rom_path = rom_path,
        .rom_data = rom_data,
        .info = info,
    };
}

/// Unloads the game and the core, in libretro order. Does nothing if no core
/// is loaded.
pub fn unload() void {
    const s = &(state orelse return);
    s.sym.retro_unload_game();
    s.sym.retro_deinit();
    s.lib.close();
    s.deinit();
    state = null;
}

pub fn isLoaded() bool {
    return state != null;
}

/// Runs one frame. The frame's video and audio are available afterwards.
pub fn runFrame() error{OutOfMemory}!void {
    const s = loaded();
    s.sym.retro_run();
    if (s.oom) {
        s.oom = false;
        return error.OutOfMemory;
    }
}

/// The latest frame the core presented (0×0 before the first).
pub fn frame() Frame {
    const s = loaded();
    return .{ .width = s.frame_w, .height = s.frame_h, .rgb = s.rgb.items };
}

/// Interleaved stereo samples produced since the last drain. The slice is
/// valid until the next `runFrame`.
pub fn drainAudio() []const i16 {
    const s = loaded();
    const out = s.audio.items;
    s.audio.items.len = 0;
    return out;
}

/// Sets the RetroPad state the core reads on port 0.
pub fn setInput(buttons: Buttons) void {
    loaded().buttons = buttons;
}

/// A core memory region (`RETRO_MEMORY_*`), or null if the core has none.
pub fn memory(id: c_uint) ?[]u8 {
    const s = loaded();
    const size = s.sym.retro_get_memory_size(id);
    const ptr = s.sym.retro_get_memory_data(id) orelse return null;
    if (size == 0) return null;
    return @as([*]u8, @ptrCast(ptr))[0..size];
}

pub fn serializeSize() usize {
    return loaded().sym.retro_serialize_size();
}

pub fn serialize(buf: []u8) error{SerializeFailed}!void {
    if (!loaded().sym.retro_serialize(buf.ptr, buf.len)) return error.SerializeFailed;
}

pub fn unserialize(buf: []const u8) error{UnserializeFailed}!void {
    if (!loaded().sym.retro_unserialize(buf.ptr, buf.len)) return error.UnserializeFailed;
}

pub fn systemInfo() SystemInfo {
    const s = loaded();
    return .{ .name = cstr(s.info.library_name), .version = cstr(s.info.library_version) };
}

pub fn avInfo() c.struct_retro_system_av_info {
    return loaded().av;
}

pub fn pixelFormat() pixels.Format {
    return loaded().format;
}

/// Problems with `--option` overrides found at load, for the caller to report.
pub fn optionWarnings() []const []const u8 {
    return loaded().options.warnings.items;
}

fn loaded() *State {
    return &(state orelse unreachable);
}

fn cstr(p: [*c]const u8) []const u8 {
    return if (p == null) "" else std.mem.span(p);
}

// ---- callbacks --------------------------------------------------------------

const CmdName = struct {
    cmd: c_uint,
    pub fn format(self: CmdName, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (env.name(self.cmd)) |n| try w.print("{s} ({d})", .{ n, self.cmd }) else try w.print("{d}", .{self.cmd});
    }
};

fn environment(cmd: c_uint, data: ?*anyopaque) callconv(.c) bool {
    const s = &(state orelse return false);
    log.debug("environment {f}", .{CmdName{ .cmd = cmd }});
    return handleEnvironment(s, cmd, data) catch |err| switch (err) {
        error.OutOfMemory => {
            s.oom = true;
            return false;
        },
    };
}

fn handleEnvironment(s: *State, cmd: c_uint, data: ?*anyopaque) error{OutOfMemory}!bool {
    switch (cmd) {
        c.RETRO_ENVIRONMENT_SET_PIXEL_FORMAT => {
            const p: *const c.enum_retro_pixel_format = @ptrCast(@alignCast(data orelse return false));
            const f = pixels.Format.fromRetro(@intCast(p.*)) orelse {
                log.warn("core asked for unsupported pixel format {d}", .{p.*});
                return false;
            };
            s.format = f;
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_LOG_INTERFACE => {
            const cb: *c.struct_retro_log_callback = @ptrCast(@alignCast(data orelse return false));
            cb.log = @ptrCast(&core_log.temui_core_log);
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY => {
            const out: *[*c]const u8 = @ptrCast(@alignCast(data orelse return false));
            out.* = s.system_dir.ptr;
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY => {
            const out: *[*c]const u8 = @ptrCast(@alignCast(data orelse return false));
            out.* = s.save_dir.ptr;
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION => {
            // 0: cores fall back to the legacy SET_VARIABLES format.
            const out: *c_uint = @ptrCast(@alignCast(data orelse return false));
            out.* = 0;
            return true;
        },
        c.RETRO_ENVIRONMENT_SET_VARIABLES => {
            const list: [*c]const c.struct_retro_variable = @ptrCast(@alignCast(data));
            try s.options.setVariables(list);
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_VARIABLE => {
            const v: *c.struct_retro_variable = @ptrCast(@alignCast(data orelse return false));
            if (v.key == null) return false;
            v.value = s.options.get(std.mem.span(v.key)) orelse {
                v.value = null;
                return false;
            };
            return true;
        },
        c.RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE => {
            // Options are fixed before load, so they never change.
            const out: *bool = @ptrCast(@alignCast(data orelse return false));
            out.* = false;
            return true;
        },
        c.RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS => return true,
        c.RETRO_ENVIRONMENT_GET_CAN_DUPE => {
            const out: *bool = @ptrCast(@alignCast(data orelse return false));
            out.* = true;
            return true;
        },
        c.RETRO_ENVIRONMENT_SET_GEOMETRY => {
            const g: *const c.struct_retro_game_geometry = @ptrCast(@alignCast(data orelse return false));
            // The max size stays as set by retro_get_system_av_info.
            s.av.geometry.base_width = g.base_width;
            s.av.geometry.base_height = g.base_height;
            s.av.geometry.aspect_ratio = g.aspect_ratio;
            return true;
        },
        c.RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO => {
            const av: *const c.struct_retro_system_av_info = @ptrCast(@alignCast(data orelse return false));
            s.av = av.*;
            log.info("core changed AV info: {d}x{d} at {d:.3} fps, {d} Hz", .{
                av.geometry.base_width, av.geometry.base_height, av.timing.fps, av.timing.sample_rate,
            });
            return true;
        },
        c.RETRO_ENVIRONMENT_SET_HW_RENDER => {
            log.warn("core asked for hardware rendering, which temui does not support (D3)", .{});
            return false;
        },
        c.RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME => {
            const p: *const bool = @ptrCast(@alignCast(data orelse return false));
            s.support_no_game = p.*;
            return true;
        },
        else => {
            if (s.seen.firstTime(cmd)) log.warn("unsupported environment command {f}", .{CmdName{ .cmd = cmd }});
            return false;
        },
    }
}

fn videoRefresh(data: ?*const anyopaque, width: c_uint, height: c_uint, pitch: usize) callconv(.c) void {
    const s = &(state orelse return);
    // NULL is a dupe: the previous frame stays.
    const src_ptr = data orelse return;
    const w: usize = width;
    const h: usize = height;
    const bpp = s.format.bytesPerPixel();
    if (pitch < w * bpp) {
        if (s.seen.firstTime(bad_pitch_key)) log.err("core sent a frame with pitch {d} < {d}×{d}; dropped", .{ pitch, w, bpp });
        return;
    }
    s.rgb.resize(s.gpa, w * h * pixels.rgb_bytes) catch {
        s.oom = true;
        return;
    };
    const src_len = if (h == 0) 0 else (h - 1) * pitch + w * bpp;
    pixels.convert(s.format, @as([*]const u8, @ptrCast(src_ptr))[0..src_len], w, h, pitch, s.rgb.items);
    s.frame_w = w;
    s.frame_h = h;
}

/// A `SeenSet` key no environment command uses, for the bad-pitch warning.
const bad_pitch_key: c_uint = 0xffff_ffff;

fn audioSample(left: i16, right: i16) callconv(.c) void {
    const s = &(state orelse return);
    s.audio.appendSlice(s.gpa, &.{ left, right }) catch {
        s.oom = true;
    };
}

fn audioSampleBatch(data: [*c]const i16, frames: usize) callconv(.c) usize {
    const s = &(state orelse return 0);
    if (data == null) return 0;
    s.audio.appendSlice(s.gpa, data[0 .. frames * 2]) catch {
        s.oom = true;
        return 0;
    };
    return frames;
}

fn inputPoll() callconv(.c) void {}

fn inputState(port: c_uint, device: c_uint, index: c_uint, id: c_uint) callconv(.c) i16 {
    _ = index;
    const s = &(state orelse return 0);
    if (port != 0 or (device & c.RETRO_DEVICE_MASK) != c.RETRO_DEVICE_JOYPAD or id >= s.buttons.len) return 0;
    return @intFromBool(s.buttons[id]);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;
const testcore = struct {
    const width = 256;
    const height = 224;
    const audio_frames = 800;
};

fn testConfig(options: []const env.Override) Config {
    const opts = @import("test_options");
    const dir = std.fs.path.dirname(opts.testcore_rom) orelse ".";
    return .{
        .core_path = opts.test_core_path,
        .rom_path = opts.testcore_rom,
        .system_dir = dir,
        .save_dir = dir,
        .options = options,
    };
}

fn loadTestCore(options: []const env.Override) !void {
    var diag: Diagnostic = .{};
    load(testing.allocator, testing.io, testConfig(options), &diag) catch |err| {
        std.debug.print("load failed: {s}\n", .{diag.message()});
        return err;
    };
}

const Trace = struct {
    video: [60]u64,
    audio: [60]u64,
};

/// Runs frames `from`..`to` (1-based, inclusive) and hashes each frame's
/// video and audio into `t`.
fn runAndHash(t: *Trace, from: usize, to: usize) !void {
    for (from..to + 1) |i| {
        try runFrame();
        const f = frame();
        try testing.expectEqual(testcore.width, f.width);
        try testing.expectEqual(testcore.height, f.height);
        t.video[i - 1] = std.hash.Wyhash.hash(0, f.rgb);
        const a = drainAudio();
        try testing.expectEqual(testcore.audio_frames * 2, a.len);
        t.audio[i - 1] = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(a));
    }
}

fn pixel(f: Frame, x: usize, y: usize) [3]u8 {
    return f.rgb[(y * f.width + x) * 3 ..][0..3].*;
}

test "load errors: missing file, not a library, missing symbol" {
    var diag: Diagnostic = .{};
    var cfg = testConfig(&.{});

    cfg.core_path = "does-not-exist/temui_nope_libretro.so";
    try testing.expectError(error.CoreOpenFailed, load(testing.allocator, testing.io, cfg, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "cannot load core does-not-exist/"));
    try testing.expect(std.mem.indexOfScalar(u8, diag.message(), '\n') == null);
    try testing.expect(!isLoaded());

    cfg.core_path = cfg.rom_path;
    try testing.expectError(error.CoreOpenFailed, load(testing.allocator, testing.io, cfg, &diag));
    try testing.expect(!isLoaded());

    // A library missing one symbol (a fake lookup that lacks retro_serialize).
    const Fake = struct {
        fn dummy() callconv(.c) void {}
        fn lookup(_: void, name: [:0]const u8) ?*anyopaque {
            if (std.mem.eql(u8, name, "retro_serialize")) return null;
            return @ptrCast(@constCast(&dummy));
        }
    };
    var missing: []const u8 = "";
    try testing.expectError(error.MissingSymbol, resolveSymbols({}, Fake.lookup, &missing));
    try testing.expectEqualStrings("retro_serialize", missing);
}

test "the test core resolves and loads; system info" {
    try loadTestCore(&.{});
    defer unload();
    try testing.expectEqualStrings("temui test core", systemInfo().name);
    try testing.expectEqual(pixels.Format.xrgb8888, pixelFormat());
    try testing.expectEqual(0, optionWarnings().len);
    try testing.expectEqual(@as(f64, 60), avInfo().timing.fps);
    var diag: Diagnostic = .{};
    try testing.expectError(error.AlreadyLoaded, load(testing.allocator, testing.io, testConfig(&.{}), &diag));
}

test "60 frames twice from a fresh load are identical" {
    var a: Trace = undefined;
    var b: Trace = undefined;
    try loadTestCore(&.{});
    try runAndHash(&a, 1, 60);
    unload();
    try loadTestCore(&.{});
    try runAndHash(&b, 1, 60);
    unload();
    try testing.expectEqualSlices(u64, &a.video, &b.video);
    try testing.expectEqualSlices(u64, &a.audio, &b.audio);
    // Frames differ from each other (the moving bar), so this isn't vacuous.
    try testing.expect(a.video[0] != a.video[1]);
}

test "save at 30, restore: frames 31-60 match" {
    try loadTestCore(&.{});
    defer unload();
    var first: Trace = undefined;
    var second: Trace = undefined;
    try runAndHash(&first, 1, 30);
    const buf = try testing.allocator.alloc(u8, serializeSize());
    defer testing.allocator.free(buf);
    try serialize(buf);
    try runAndHash(&first, 31, 60);
    try unserialize(buf);
    try runAndHash(&second, 31, 60);
    try testing.expectEqualSlices(u64, first.video[30..], second.video[30..]);
    try testing.expectEqualSlices(u64, first.audio[30..], second.audio[30..]);
    try testing.expectError(error.UnserializeFailed, unserialize(buf[1..]));
}

test "held button lights its box and appears in SRAM" {
    try loadTestCore(&.{});
    defer unload();
    var buttons: Buttons = @splat(false);
    buttons[c.RETRO_DEVICE_ID_JOYPAD_A] = true;
    setInput(buttons);
    try runFrame();
    _ = drainAudio();

    const f = frame();
    const box_y = 208;
    const a: usize = c.RETRO_DEVICE_ID_JOYPAD_A;
    try testing.expectEqual([3]u8{ 255, 255, 255 }, pixel(f, a * 16 + 5, box_y));
    try testing.expectEqual([3]u8{ 48, 48, 48 }, pixel(f, (a + 1) * 16 + 5, box_y));

    const sram = memory(c.RETRO_MEMORY_SAVE_RAM).?;
    try testing.expectEqual(8192, sram.len);
    try testing.expectEqual(1, std.mem.readInt(u32, sram[0..4], .little));
    try testing.expectEqual(@as(u16, 1) << @intCast(a), std.mem.readInt(u16, sram[4..6], .little));
    try testing.expectEqual(null, memory(c.RETRO_MEMORY_SYSTEM_RAM));

    setInput(@splat(false));
    try runFrame();
    try testing.expectEqual([3]u8{ 48, 48, 48 }, pixel(frame(), a * 16 + 5, box_y));
    try testing.expectEqual(0, std.mem.readInt(u16, sram[4..6], .little));
}

test "pixel formats via the option, including the 0RGB1555 default" {
    const cases = [_]struct { value: []const u8, format: pixels.Format, grey128: [3]u8 }{
        .{ .value = "xrgb8888", .format = .xrgb8888, .grey128 = .{ 128, 128, 128 } },
        // 128 → 5 bits 16 → 132; 6 bits 32 → 130.
        .{ .value = "rgb565", .format = .rgb565, .grey128 = .{ 132, 130, 132 } },
        .{ .value = "0rgb1555", .format = .rgb1555, .grey128 = .{ 132, 132, 132 } },
    };
    for (cases) |case| {
        try loadTestCore(&.{.{ .key = "temui_test_pixel_format", .value = case.value }});
        defer unload();
        try testing.expectEqual(case.format, pixelFormat());
        try runFrame();
        _ = drainAudio();
        // The grey gradient row: value = x.
        try testing.expectEqual(case.grey128, pixel(frame(), 128, 180));
        try testing.expectEqual([3]u8{ 255, 255, 255 }, pixel(frame(), 255, 180));
    }
}

test "option warnings are collected at load" {
    try loadTestCore(&.{
        .{ .key = "temui_test_pixel_format", .value = "cmyk" },
        .{ .key = "temui_test_nope", .value = "1" },
    });
    defer unload();
    try testing.expectEqual(pixels.Format.xrgb8888, pixelFormat());
    try testing.expectEqual(2, optionWarnings().len);
}

test "core log lines reach the sink with their level" {
    const Capture = struct {
        var line: [256]u8 = undefined;
        var len: usize = 0;
        var level: std.log.Level = .debug;
        fn record(l: std.log.Level, msg: []const u8) void {
            const n = @min(msg.len, line.len);
            @memcpy(line[0..n], msg[0..n]);
            len = n;
            level = l;
        }
    };
    const prev = core_log.sink;
    core_log.sink = &Capture.record;
    defer core_log.sink = prev;
    try loadTestCore(&.{});
    defer unload();
    const text = Capture.line[0..Capture.len];
    try testing.expect(std.mem.startsWith(u8, text, "temui test core: loaded "));
    try testing.expect(std.mem.endsWith(u8, text, ", format xrgb8888"));
    try testing.expectEqual(std.log.Level.info, Capture.level);
}

test "unknown environment command: false, logged once; SET_HW_RENDER refused" {
    try loadTestCore(&.{});
    defer unload();
    const prev_level = testing.log_level;
    testing.log_level = .err; // the warnings below are expected
    defer testing.log_level = prev_level;

    const s = &state.?;
    const before = s.seen.len;
    try testing.expect(!environment(9999, null));
    try testing.expectEqual(before + 1, s.seen.len);
    try testing.expect(!environment(9999, null));
    try testing.expectEqual(before + 1, s.seen.len);

    var hw: c.struct_retro_hw_render_callback = std.mem.zeroes(c.struct_retro_hw_render_callback);
    try testing.expect(!environment(c.RETRO_ENVIRONMENT_SET_HW_RENDER, &hw));

    // A few of the implemented ones, through the same entry point.
    var dupe = false;
    try testing.expect(environment(c.RETRO_ENVIRONMENT_GET_CAN_DUPE, &dupe));
    try testing.expect(dupe);
    var dir: [*c]const u8 = null;
    try testing.expect(environment(c.RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY, @ptrCast(&dir)));
    try testing.expectEqualStrings(testConfig(&.{}).save_dir, std.mem.span(dir));
    var version: c_uint = 99;
    try testing.expect(environment(c.RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION, &version));
    try testing.expectEqual(0, version);
    var bad_format: c.enum_retro_pixel_format = 7;
    try testing.expect(!environment(c.RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &bad_format));
}

test "a NULL frame keeps the previous one" {
    try loadTestCore(&.{});
    defer unload();
    try runFrame();
    _ = drainAudio();
    const before = std.hash.Wyhash.hash(0, frame().rgb);
    videoRefresh(null, testcore.width, testcore.height, 0);
    try testing.expectEqual(before, std.hash.Wyhash.hash(0, frame().rgb));
}
