//! temui-bench: renderer benchmarks (roadmap item 04).
//!
//!   encode  encodes N frames per backend/transport into memory and reports
//!           ms/frame and bytes/frame; no terminal needed, any OS.
//!   live    draws frames in the real terminal at a paced 60 fps through
//!           the production renderer and measures what the terminal
//!           acknowledges (spike 02's method); POSIX only.
//!
//! Built only by `zig build bench` (ReleaseFast unless -Dbench-optimize).

const std = @import("std");
const builtin = @import("builtin");
const temui = @import("temui");
const bench_options = @import("bench_options");
const scene = @import("scene.zig");
const live = @import("live.zig");

const caps = temui.term.caps;
const Renderer = temui.render.Renderer;
const Io = std.Io;

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = temui.log.logFn,
};

/// Restores the terminal (if `live` has a session) before the default panic.
pub const panic = std.debug.FullPanic(panicRestoring);

fn panicRestoring(msg: []const u8, first_trace_addr: ?usize) noreturn {
    temui.term.session.restore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

const usage_text =
    \\usage: temui-bench encode [options]
    \\       temui-bench live [options]
    \\
    \\common:
    \\  --source <s>        scroll (default), sprites or testcore
    \\  --size <WxH>        synthetic scene size (default 256x224; testcore is 256x224)
    \\  --cells <CxR>       draw into CxR cells (encode default 128x56 at 10x20 px
    \\                      cells; live default: the whole window)
    \\  --out <file>        also write results as JSON lines to <file>
    \\  --log-file <file>   log here instead of temui's log directory
    \\
    \\encode:
    \\  --frames <n>        frames per backend/transport (default 600)
    \\
    \\live:
    \\  --duration <s>      seconds (default 10)
    \\  --fps <n>           pacing; 0 = unpaced (default 60)
    \\  --renderer <name>   kitty, halfblock, ascii or auto (default)
    \\  --transport <t>     kitty: shm, file or zlib first (default: detected order)
    \\  --max-inflight <n>  unacknowledged frames before the writer waits (default 8)
    \\  --term-pid <pid>    terminal process for CPU sampling (repeatable; macOS)
    \\
    \\Ctrl-C or q stops a live run; a second Ctrl-C exits at once.
    \\
;

const Mode = enum { encode, live };

const Options = struct {
    mode: Mode,
    source: scene.Source = .scroll,
    size: [2]u32 = .{ 256, 224 },
    cells: ?[2]u32 = null,
    out: ?[]const u8 = null,
    log_file: ?[]const u8 = null,
    frames: u32 = 600,
    duration_s: f64 = 10,
    fps: f64 = 60,
    renderer: ?caps.Backend = null,
    transport: ?caps.Transport = null,
    max_inflight: u32 = 8,
    term_pids: [8]i32 = undefined,
    term_pid_count: usize = 0,
};

fn parseDims(s: []const u8) ?[2]u32 {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
    const a = std.fmt.parseInt(u32, s[0..x], 10) catch return null;
    const b = std.fmt.parseInt(u32, s[x + 1 ..], 10) catch return null;
    if (a == 0 or b == 0 or a > 8192 or b > 8192) return null;
    return .{ a, b };
}

/// Returns the options, or a message for the user.
fn parse(args: []const [:0]const u8, err_buf: []u8) union(enum) { ok: Options, err: []const u8, help } {
    if (args.len == 0) return .{ .err = "missing mode (encode or live)" };
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) return .help;
    var o: Options = .{ .mode = std.meta.stringToEnum(Mode, args[0]) orelse
        return .{ .err = std.fmt.bufPrint(err_buf, "unknown mode '{s}'", .{args[0]}) catch "unknown mode" } };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;
        if (i + 1 >= args.len) return .{ .err = std.fmt.bufPrint(err_buf, "unknown option or missing value: {s}", .{a}) catch "bad option" };
        const v = args[i + 1];
        i += 1;
        const bad: @TypeOf(parse(args, err_buf)) = .{ .err = std.fmt.bufPrint(err_buf, "invalid value for {s}: {s}", .{ a, v }) catch "invalid value" };
        if (std.mem.eql(u8, a, "--source")) {
            o.source = std.meta.stringToEnum(scene.Source, v) orelse return bad;
        } else if (std.mem.eql(u8, a, "--size")) {
            o.size = parseDims(v) orelse return bad;
        } else if (std.mem.eql(u8, a, "--cells")) {
            o.cells = parseDims(v) orelse return bad;
        } else if (std.mem.eql(u8, a, "--out")) {
            o.out = v;
        } else if (std.mem.eql(u8, a, "--log-file")) {
            o.log_file = v;
        } else if (std.mem.eql(u8, a, "--frames")) {
            o.frames = std.fmt.parseInt(u32, v, 10) catch return bad;
            if (o.frames == 0) return bad;
        } else if (std.mem.eql(u8, a, "--duration")) {
            o.duration_s = std.fmt.parseFloat(f64, v) catch return bad;
            if (!(o.duration_s > 0 and o.duration_s <= 3600)) return bad;
        } else if (std.mem.eql(u8, a, "--fps")) {
            o.fps = std.fmt.parseFloat(f64, v) catch return bad;
            if (!(o.fps >= 0 and o.fps <= 10000)) return bad;
        } else if (std.mem.eql(u8, a, "--renderer")) {
            o.renderer = if (std.mem.eql(u8, v, "auto")) null else std.meta.stringToEnum(caps.Backend, v) orelse return bad;
        } else if (std.mem.eql(u8, a, "--transport")) {
            o.transport = std.meta.stringToEnum(caps.Transport, v) orelse return bad;
        } else if (std.mem.eql(u8, a, "--max-inflight")) {
            o.max_inflight = std.fmt.parseInt(u32, v, 10) catch return bad;
            if (o.max_inflight == 0) return bad;
        } else if (std.mem.eql(u8, a, "--term-pid")) {
            if (o.term_pid_count == o.term_pids.len) return bad;
            o.term_pids[o.term_pid_count] = std.fmt.parseInt(i32, v, 10) catch return bad;
            o.term_pid_count += 1;
        } else return .{ .err = std.fmt.bufPrint(err_buf, "unknown option: {s}", .{a}) catch "unknown option" };
    }
    return .{ .ok = o };
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    var err_buf: [256]u8 = undefined;
    const opts = switch (parse(args[1..], &err_buf)) {
        .ok => |o| o,
        .help => {
            try stdout.writeAll(usage_text);
            try stdout.flush();
            return 0;
        },
        .err => |e| {
            try stderr.print("temui-bench: {s}\n\n{s}", .{ e, usage_text });
            try stderr.flush();
            return 2;
        },
    };

    const log_dir: ?[]const u8 = temui.paths.logDir(arena, builtin.os.tag, temui.paths.envFromProcess(init.environ_map)) catch null;
    temui.log.init(gpa, io, .{ .verbose = true, .log_file = opts.log_file, .log_dir = log_dir }) catch |err| {
        try stderr.print("temui-bench: warning: logging disabled: {t}\n", .{err});
        try stderr.flush();
    };
    defer temui.log.deinit();
    std.log.info("temui-bench ({s}) args: {f}", .{ bench_options.optimize, std.json.fmt(args[1..], .{}) });

    var loop = switch (opts.source) {
        .testcore => scene.Loop.initTestCore(gpa, io, .{
            .core_path = bench_options.test_core_path,
            .rom_path = bench_options.testcore_rom,
            .scratch_dir = temui.render.kitty.defaultTmpDir(),
        }) catch |err| {
            try stderr.print("temui-bench: could not run the test core: {t} (see the log)\n", .{err});
            try stderr.flush();
            return 1;
        },
        else => try scene.Loop.initScene(gpa, opts.source, opts.size[0], opts.size[1]),
    };
    defer loop.deinit(gpa);

    const out_file: ?Io.File = if (opts.out) |path| Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        try stderr.print("temui-bench: could not create {s}: {t}\n", .{ path, err });
        try stderr.flush();
        return 1;
    } else null;
    defer if (out_file) |f| f.close(io);
    var out_buf: [4096]u8 = undefined;
    var out_fw: ?Io.File.Writer = if (out_file) |f| f.writer(io, &out_buf) else null;
    const jw: ?*Io.Writer = if (out_fw) |*fw| &fw.interface else null;

    switch (opts.mode) {
        .encode => {
            try encode(gpa, io, &loop, opts, stdout, jw);
            try stdout.flush();
            if (jw) |w| try w.flush();
            return 0;
        },
        .live => {
            const res = live.run(gpa, arena, io, init.environ_map, .{
                .loop = &loop,
                .source = opts.source,
                .duration_s = opts.duration_s,
                .fps = opts.fps,
                .renderer = opts.renderer,
                .transport = opts.transport,
                .cells = opts.cells,
                .max_inflight = opts.max_inflight,
                .term_pids = opts.term_pids[0..opts.term_pid_count],
            }, bench_options.optimize) catch |err| {
                // anyerror: on Windows `live.run` can only fail one way.
                const e: anyerror = err;
                if (e == error.NotATerminal) {
                    try stderr.writeAll("temui-bench: live needs a terminal on stdin and stdout (POSIX)\n");
                } else try stderr.print("temui-bench: live: {t} (see the log)\n", .{e});
                try stderr.flush();
                return if (e == error.Interrupted) 130 else 1;
            };
            std.log.info("live: {f}", .{std.json.fmt(res, .{})});
            try live.printSummary(stdout, res);
            try stdout.flush();
            if (jw) |w| try writeLine(w, res);
            return switch (res.status) {
                .interrupted => 130,
                .failed => 1,
                .ok => if (res.pass) 0 else 1,
            };
        },
    }
}

fn writeLine(w: *Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, w);
    try w.writeByte('\n');
    try w.flush();
}

// ---------------------------------------------------------------- encode

const EncodeResult = struct {
    type: []const u8 = "encode",
    optimize: []const u8 = bench_options.optimize,
    source: scene.Source,
    frame_w: u32,
    frame_h: u32,
    backend: caps.Backend,
    transport: ?caps.Transport,
    ascii_color: ?caps.AsciiColor,
    rect_cols: u32,
    rect_rows: u32,
    cell_px: caps.CellPx,
    frames: u32,
    ms_per_frame: f64,
    max_ms: f64,
    bytes_per_frame: f64,
    /// Kitty: a runtime error moved it off the requested transport.
    fell_back: bool,
};

const EncodeCase = struct { backend: caps.Backend, transport: ?caps.Transport = null, ascii_color: caps.AsciiColor = .truecolor };

const encode_cases = [_]EncodeCase{
    .{ .backend = .kitty, .transport = .shm },
    .{ .backend = .kitty, .transport = .file },
    .{ .backend = .kitty, .transport = .zlib },
    .{ .backend = .halfblock },
    .{ .backend = .ascii, .ascii_color = .truecolor },
    .{ .backend = .ascii, .ascii_color = .ansi256 },
    .{ .backend = .ascii, .ascii_color = .none },
};

/// Spike 02's encode targets (ms/frame), where there is one.
fn target(c: EncodeCase) ?f64 {
    if (c.backend != .kitty) return null;
    return switch (c.transport.?) {
        .shm => 0.5,
        .zlib => 2.5,
        .file => null,
    };
}

fn nowNs(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn encode(gpa: std.mem.Allocator, io: Io, loop: *const scene.Loop, opts: Options, out: *Io.Writer, jw: ?*Io.Writer) !void {
    const cells = opts.cells orelse .{ 128, 56 };
    const rect: Renderer.Rect = .{ .col = 1, .row = 1, .cols = cells[0], .rows = cells[1] };
    const cell_px: caps.CellPx = .{ .w = 10, .h = 20 };
    try out.print("temui-bench encode ({s}): {t} {d}x{d}, {d} frames into {d}x{d} cells at {d}x{d} px\n\n", .{
        bench_options.optimize, opts.source, loop.width, loop.height, opts.frames, rect.cols, rect.rows, cell_px.w, cell_px.h,
    });
    try out.print("{s:<10} {s:<10} {s:>9} {s:>9} {s:>12}  {s}\n", .{ "backend", "variant", "ms/frame", "max ms", "bytes/frame", "target" });

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (encode_cases) |c| {
        if (c.transport) |t| if (t != .zlib and !temui.render.kitty.posix) continue;
        const choice: caps.Choice = .{
            .backend = c.backend,
            .transports = if (c.transport) |t| (if (t == .zlib) .init(&.{.zlib}) else .init(&.{ t, .zlib })) else .init(&.{.zlib}),
            .ascii_color = c.ascii_color,
            .cell_px = cell_px,
        };
        var r: Renderer = try .init(gpa, io, choice, .{ .kitty = .{ .prefix = "temui-bench" } });
        defer r.deinit();

        // Warm-up: the first frame is a full redraw and sizes the buffers.
        aw.clearRetainingCapacity();
        try r.present(&aw.writer, loop.frame(0), rect, .{});
        reapAll(&r);

        var total_ns: i96 = 0;
        var max_ns: i96 = 0;
        var bytes: u64 = 0;
        for (1..opts.frames + 1) |i| {
            aw.clearRetainingCapacity();
            const t0 = nowNs(io);
            try r.present(&aw.writer, loop.frame(i), rect, .{});
            const dt = nowNs(io) - t0;
            total_ns += dt;
            max_ns = @max(max_ns, dt);
            bytes += aw.written().len;
            // Nothing reads the shm/file objects here; unlink them now
            // (untimed) instead of letting thousands pile up.
            reapAll(&r);
        }
        const fell_back = if (r.impl == .kitty) r.impl.kitty.transport() != c.transport.? else false;

        const n: f64 = @floatFromInt(opts.frames);
        const res: EncodeResult = .{
            .source = opts.source,
            .frame_w = loop.width,
            .frame_h = loop.height,
            .backend = c.backend,
            .transport = c.transport,
            .ascii_color = if (c.backend == .ascii) c.ascii_color else null,
            .rect_cols = rect.cols,
            .rect_rows = rect.rows,
            .cell_px = cell_px,
            .frames = opts.frames,
            .ms_per_frame = @as(f64, @floatFromInt(total_ns)) / n / std.time.ns_per_ms,
            .max_ms = @as(f64, @floatFromInt(max_ns)) / std.time.ns_per_ms,
            .bytes_per_frame = @as(f64, @floatFromInt(bytes)) / n,
            .fell_back = fell_back,
        };
        std.log.info("encode: {f}", .{std.json.fmt(res, .{})});
        if (jw) |w| try writeLine(w, res);

        var tbuf: [32]u8 = undefined;
        const tgt = if (target(c)) |t|
            std.fmt.bufPrint(&tbuf, "<= {d} ms: {s}", .{ t, if (res.ms_per_frame <= t) "ok" else "MISS" }) catch ""
        else
            "-";
        const variant = if (c.transport) |t| @tagName(t) else if (c.backend == .ascii) @tagName(c.ascii_color) else "truecolor";
        try out.print("{s:<10} {s:<10} {d:>9.3} {d:>9.3} {d:>12.0}  {s}{s}\n", .{
            @tagName(c.backend), variant, res.ms_per_frame, res.max_ms, res.bytes_per_frame, tgt, if (fell_back) "  (fell back to zlib)" else "",
        });
    }
}

fn reapAll(r: *Renderer) void {
    if (r.impl == .kitty and temui.render.kitty.posix) r.impl.kitty.reap(std.math.maxInt(i96));
}

// ---------------------------------------------------------------- tests

test {
    _ = scene;
    _ = @import("stats.zig");
    _ = @import("procstat.zig");
    _ = live;
}

const testing = std.testing;

test "parse: modes, options and errors" {
    var buf: [256]u8 = undefined;
    const a = parse(&.{ "encode", "--frames", "10", "--source", "testcore", "--cells", "80x24" }, &buf).ok;
    try testing.expectEqual(Mode.encode, a.mode);
    try testing.expectEqual(@as(u32, 10), a.frames);
    try testing.expectEqual(scene.Source.testcore, a.source);
    try testing.expectEqual([2]u32{ 80, 24 }, a.cells.?);

    const b = parse(&.{ "live", "--renderer", "kitty", "--transport", "shm", "--fps", "0", "--term-pid", "42" }, &buf).ok;
    try testing.expectEqual(caps.Backend.kitty, b.renderer.?);
    try testing.expectEqual(caps.Transport.shm, b.transport.?);
    try testing.expectEqual(@as(f64, 0), b.fps);
    try testing.expectEqualSlices(i32, &.{42}, b.term_pids[0..b.term_pid_count]);
    try testing.expectEqual(@as(?caps.Backend, null), parse(&.{ "live", "--renderer", "auto" }, &buf).ok.renderer);

    try testing.expect(parse(&.{}, &buf) == .err);
    try testing.expect(parse(&.{"draw"}, &buf) == .err);
    try testing.expect(parse(&.{ "encode", "--frames" }, &buf) == .err);
    try testing.expect(parse(&.{ "encode", "--frames", "0" }, &buf) == .err);
    try testing.expect(parse(&.{ "encode", "--size", "256" }, &buf) == .err);
    try testing.expect(parse(&.{ "live", "--bogus", "1" }, &buf) == .err);
    try testing.expect(parse(&.{ "encode", "--help" }, &buf) == .help);
}

test "encode smoke: every case runs and writes bytes" {
    const gpa = testing.allocator;
    var loop = try scene.Loop.initScene(gpa, .sprites, 64, 56);
    defer loop.deinit(gpa);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var jaw: Io.Writer.Allocating = .init(gpa);
    defer jaw.deinit();
    try encode(gpa, testing.io, &loop, .{ .mode = .encode, .frames = 3, .cells = .{ 32, 14 } }, &aw.writer, &jaw.writer);
    var lines = std.mem.tokenizeScalar(u8, jaw.written(), '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        const parsed = try std.json.parseFromSlice(struct { bytes_per_frame: f64, fell_back: bool }, gpa, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try testing.expect(parsed.value.bytes_per_frame > 0);
        try testing.expect(!parsed.value.fell_back);
    }
    try testing.expectEqual(if (temui.render.kitty.posix) encode_cases.len else encode_cases.len - 2, n);
}
