//! `temui run --headless`: load a core, run N frames as fast as possible,
//! optionally dump frames as PPM, print one summary line.

const std = @import("std");
const cli = @import("cli.zig");
const host = @import("libretro/host.zig");
const ppm = @import("ppm.zig");

const log = std.log.scoped(.run);

pub const Error = host.LoadError || error{ DumpFailed, OutOfMemory };

/// Runs `opts`. On error, `diag` holds a one-line reason for the user.
/// stdout gets only the summary line; warnings go to `stderr` and the log.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: *const cli.Run,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    diag: *host.Diagnostic,
) Error!void {
    const rom_dir = std.fs.path.dirname(opts.rom) orelse ".";
    try host.load(gpa, io, .{
        .core_path = opts.core,
        .rom_path = opts.rom,
        .system_dir = opts.system_dir orelse rom_dir,
        .save_dir = opts.save_dir orelse rom_dir,
        .options = opts.options(),
    }, diag);
    defer host.unload();

    for (host.optionWarnings()) |w| {
        log.warn("{s}", .{w});
        stderr.print("temui: warning: {s}\n", .{w}) catch {};
    }
    stderr.flush() catch {};

    var dump_dir: ?std.Io.Dir = if (opts.dump_ppm) |path|
        std.Io.Dir.cwd().createDirPathOpen(io, path, .{}) catch |err| {
            diag.set("cannot create {s}: {t}", .{ path, err });
            return error.DumpFailed;
        }
    else
        null;
    defer if (dump_dir) |*d| d.close(io);

    var i: u64 = 1;
    while (i <= opts.frames) : (i += 1) {
        try host.runFrame();
        // Not played until item 09; draining keeps memory flat.
        _ = host.drainAudio();
        if (dump_dir) |d| {
            if (i % opts.dump_every == 0 or i == opts.frames) try dumpFrame(io, d, opts.dump_ppm.?, i, diag);
        }
    }

    const info = host.systemInfo();
    const f = host.frame();
    log.info("ran {d} frames", .{opts.frames});
    stdout.print("{s} {s}: {d} frames, {d}x{d}, {s}\n", .{
        info.name, info.version, opts.frames, f.width, f.height, host.pixelFormat().name(),
    }) catch {};
}

fn dumpFrame(io: std.Io, dir: std.Io.Dir, dir_path: []const u8, i: u64, diag: *host.Diagnostic) error{DumpFailed}!void {
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "frame-{d:0>6}.ppm", .{i}) catch unreachable;
    writePpm(io, dir, name) catch |err| {
        diag.set("cannot write {s}/{s}: {t}", .{ dir_path, name, err });
        return error.DumpFailed;
    };
}

fn writePpm(io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const f = host.frame();
    ppm.write(&fw.interface, f.width, f.height, f.rgb) catch return fw.err.?;
    fw.interface.flush() catch return fw.err.?;
}

const testing = std.testing;

/// A temp dir under the working directory, addressable by path.
const TmpPath = struct {
    tmp: std.testing.TmpDir,
    buf: [128]u8 = undefined,
    path: []const u8 = "",

    fn init() TmpPath {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn join(t: *TmpPath, sub: []const u8) []const u8 {
        t.path = std.fmt.bufPrint(&t.buf, ".zig-cache/tmp/{s}/{s}", .{ t.tmp.sub_path, sub }) catch unreachable;
        return t.path;
    }
};

fn testRun(frames: u64) cli.Run {
    const o = @import("test_options");
    return .{ .core = o.test_core_path, .rom = o.testcore_rom, .frames = frames };
}

test "run dumps every K-th frame and the last, and prints a summary" {
    var t: TmpPath = .init();
    defer t.tmp.cleanup();
    const out_dir = t.join("dumps/nested");

    var opts = testRun(5);
    opts.dump_ppm = out_dir;
    opts.dump_every = 2;

    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [256]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var diag: host.Diagnostic = .{};
    try run(testing.allocator, testing.io, &opts, &out, &err, &diag);
    try testing.expect(!host.isLoaded());
    try testing.expectEqualStrings("temui test core 1: 5 frames, 256x224, XRGB8888\n", out.buffered());
    try testing.expectEqualStrings("", err.buffered());

    var dir = try t.tmp.dir.openDir(testing.io, "dumps/nested", .{ .iterate = true });
    defer dir.close(testing.io);
    var names: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = dir.iterate();
    var name_store: [8][32]u8 = undefined;
    while (try it.next(testing.io)) |e| {
        @memcpy(name_store[n][0..e.name.len], e.name);
        names[n] = name_store[n][0..e.name.len];
        n += 1;
    }
    std.mem.sort([]const u8, names[0..n], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try testing.expectEqual(3, n);
    try testing.expectEqualStrings("frame-000002.ppm", names[0]);
    try testing.expectEqualStrings("frame-000004.ppm", names[1]);
    try testing.expectEqualStrings("frame-000005.ppm", names[2]);

    const data = try dir.readFileAlloc(testing.io, "frame-000005.ppm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(data);
    const header = "P6\n256 224\n255\n";
    try testing.expectEqual(header.len + 256 * 224 * 3, data.len);
    try testing.expectEqualStrings(header, data[0..header.len]);
}

test "run reports option warnings on stderr and fails cleanly on a bad core" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err_buf: [512]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var diag: host.Diagnostic = .{};

    const prev_level = testing.log_level;
    testing.log_level = .err; // the option warning is expected
    defer testing.log_level = prev_level;
    var opts = testRun(1);
    opts.option_buf[0] = .{ .key = "temui_test_nope", .value = "1" };
    opts.option_len = 1;
    try run(testing.allocator, testing.io, &opts, &out, &err, &diag);
    try testing.expectEqualStrings(
        "temui: warning: option \"temui_test_nope\" is not declared by the core; ignored\n",
        err.buffered(),
    );

    var bad = testRun(1);
    bad.core = bad.rom;
    try testing.expectError(error.CoreOpenFailed, run(testing.allocator, testing.io, &bad, &out, &err, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message(), "cannot load core "));
    try testing.expect(!host.isLoaded());
}

test "frame 60 matches the committed golden for each pixel format" {
    inline for (.{ "xrgb8888", "rgb565", "0rgb1555" }) |format| {
        const golden_path = @field(@import("test_options"), "golden_" ++ format);
        var t: TmpPath = .init();
        defer t.tmp.cleanup();
        var opts = testRun(60);
        opts.dump_ppm = t.join("out");
        opts.dump_every = 60;
        opts.option_buf[0] = .{ .key = "temui_test_pixel_format", .value = format };
        opts.option_len = 1;

        var out_buf: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf);
        var err_buf: [256]u8 = undefined;
        var err: std.Io.Writer = .fixed(&err_buf);
        var diag: host.Diagnostic = .{};
        try run(testing.allocator, testing.io, &opts, &out, &err, &diag);

        const got = try t.tmp.dir.readFileAlloc(testing.io, "out/frame-000060.ppm", testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(got);
        const want = try std.Io.Dir.cwd().readFileAlloc(testing.io, golden_path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(want);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("{s}: frame 60 differs from the golden; see testdata/golden/README.md\n", .{format});
            return error.TestExpectedEqual;
        }
    }
}
