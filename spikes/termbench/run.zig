//! The benchmark matrix: for each (resolution, scene, transport) cell, a
//! title card, then an unpaced (or `--fps`-capped) loop that encodes and
//! writes frames, each followed by `CSI 5 n`. The reader thread timestamps
//! the replies; the writer only blocks when `--max-inflight` frames are
//! unacknowledged. Results go to a JSON-lines file, flushed per cell, and a
//! summary table is printed after the terminal is restored.

const std = @import("std");
const c = std.c;
const Io = std.Io;
const build_options = @import("build_options");
const cli = @import("cli.zig");
const term = @import("term.zig");
const detect = @import("detect.zig");
const reader_mod = @import("reader.zig");
const scene = @import("scene.zig");
const stats = @import("stats.zig");
const kitty = @import("kitty.zig");
const halfblock = @import("halfblock.zig");
const procstat = @import("procstat.zig");
const util = @import("util.zig");

const ms = std.time.ns_per_ms;
const tick_ns = 250 * ms;
const drain_ns = 5 * std.time.ns_per_s;
const status_rows = 1;
const delete_images = "\x1b_Ga=d,d=A,q=2\x1b\\";

const Cell = struct { res: cli.Res, scene: cli.Scene, transport: cli.Transport };

pub const Status = enum { ok, failed, interrupted };

pub const CellResult = struct {
    type: []const u8 = "cell",
    index: usize,
    transport: cli.Transport,
    res: cli.Res,
    scene: cli.Scene,
    /// Pixel format sent (kitty), or "halfblock".
    format: []const u8,
    /// Cells covered: the kitty placement box or the half-block area.
    area_cols: u32,
    area_rows: u32,
    status: Status,
    reason: ?[]const u8 = null,
    frames_sent: u64,
    /// Every outstanding ack arrived after the cell ended (within 5 s).
    drained: bool,
    stats: stats.Stats,
    /// status ok and every full 1-s window ≥ 60 fps.
    pass: bool,
};

const Header = struct {
    type: []const u8 = "header",
    termbench_optimize: []const u8 = build_options.optimize,
    date: []const u8,
    machine: struct { model: ?[]const u8, cpu: ?[]const u8, macos: ?[]const u8 },
    terminal: []const u8,
    winsize: term.Size,
    cell_px: ?[2]f64,
    term_procs: procstat.Discovery,
    options: struct {
        duration_s: f64,
        fps: f64,
        max_inflight: u32,
        ack_timeout_s: f64,
        overlay: bool,
        double_buffer: bool,
    },
    detect: detect.Result,
};

const Sample = struct { t: u64, acks: u64, self_cpu: u64, term_cpu: u64, bytes: u64 };

const Runner = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    opts: cli.Options,
    reader: *reader_mod.Reader,
    procs: []const procstat.Proc,
    size: term.Size,
    tmpdir: []const u8,
    cells_total: usize,
    /// Status-bar history (≈1 s at 4 Hz).
    samples: [5]Sample = undefined,
    sample_count: usize = 0,
    line: [512]u8 = undefined,

    fn termCpu(r: *const Runner) u64 {
        return procstat.cpuNs(r.procs);
    }

    /// Clears the screen and any kitty images, then shows the cell's mode
    /// for ~1 s.
    fn titleCard(r: *Runner, index: usize, cell: Cell) void {
        const text = std.fmt.bufPrint(&r.line, "cell {d}/{d}:  {t}  {t}  {t}", .{ index + 1, r.cells_total, cell.transport, cell.res, cell.scene }) catch "";
        const row = r.size.rows / 2;
        const col = 1 + (r.size.cols -| @as(u16, @intCast(text.len))) / 2;
        var buf: [640]u8 = undefined;
        _ = term.writeWatched(std.fmt.bufPrint(&buf, "{s}\x1b[0m\x1b[2J\x1b[{d};{d}H\x1b[1m{s}\x1b[0m\x1b[{d};{d}HCtrl-C to stop", .{
            delete_images, row, col, text, row + 2, 1 + (r.size.cols -| 14) / 2,
        }) catch "");
        const end = term.nowNs() + std.time.ns_per_s;
        while (term.nowNs() < end and !term.interrupted.load(.acquire)) term.sleepNs(50 * ms);
        _ = term.writeWatched("\x1b[2J");
    }

    /// Waits for every reply to earlier requests: replies come in order, so
    /// once a fresh DA1 is answered nothing stale can arrive later.
    fn resync(r: *Runner) !void {
        const want = r.reader.da1s.load(.acquire) + 1;
        _ = term.writeWatched("\x1b[c");
        if (r.reader.waitDa1(want, term.nowNs() + drain_ns) < want) {
            if (term.interrupted.load(.acquire)) return error.Interrupted;
            return error.TerminalNotResponding;
        }
    }

    /// Draws the status bar; returns the bytes written.
    fn statusBar(r: *Runner, cell: Cell, index: usize, elapsed_ns: u64, s: Sample) u64 {
        // Rates over the oldest sample still in the ring (≈1 s ago).
        const len = r.samples.len;
        const oldest = if (r.sample_count == 0) s else if (r.sample_count < len) r.samples[0] else r.samples[r.sample_count % len];
        r.samples[r.sample_count % len] = s;
        r.sample_count += 1;
        const dt = @as(f64, @floatFromInt(@max(s.t -| oldest.t, 1))) / std.time.ns_per_s;
        const fps = @as(f64, @floatFromInt(s.acks - oldest.acks)) / dt;
        const self_pct = @as(f64, @floatFromInt(s.self_cpu - oldest.self_cpu)) / dt / 1e7;
        const term_pct = @as(f64, @floatFromInt(s.term_cpu -| oldest.term_cpu)) / dt / 1e7;
        const mbs = @as(f64, @floatFromInt(s.bytes - oldest.bytes)) / dt / 1e6;
        var tb: [16]u8 = undefined;
        const term_txt = if (r.procs.len == 0) "-" else std.fmt.bufPrint(&tb, "{d:.0}%", .{term_pct}) catch "?";
        var text_buf: [256]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, " {d}/{d} {t} {t} {t} | {d:.1}/{d:.0} s | {d:.0} fps | termbench {d:.0}% | terminal {s} | {d:.1} MB/s", .{
            index + 1,                                                       r.cells_total, cell.transport, cell.res, cell.scene,
            @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s, r.opts.duration_s, fps, self_pct, term_txt, mbs,
        }) catch text_buf[0..0];
        const width: usize = r.size.cols;
        const shown = text[0..@min(text.len, width)];
        const line = std.fmt.bufPrint(&r.line, "\x1b[{d};1H\x1b[0;7m{s}{s}\x1b[0m", .{ r.size.rows, shown, spaces[0..@min(width - shown.len, spaces.len)] }) catch return 0;
        _ = term.writeWatched(line);
        return line.len;
    }

    fn runCell(r: *Runner, index: usize, cell: Cell) !CellResult {
        const gpa = r.gpa;
        const opts = r.opts;
        const w = cell.res.width();
        const h = cell.res.height();
        const kind = kitty.kind(cell.transport);
        const fmt: scene.Format = if (kind) |k| kitty.format(k) else .rgb;

        var loop = try scene.Loop.init(gpa, cell.scene, cell.res, fmt);
        defer loop.deinit(gpa);

        var kenc: ?kitty.Encoder = null;
        var henc: ?halfblock.Encoder = null;
        defer if (kenc) |*e| e.deinit();
        defer if (henc) |*e| e.deinit();
        var placement: kitty.Placement = undefined;
        var area_cols: u32 = 0;
        var area_rows: u32 = 0;
        if (kind) |k| {
            kenc = try kitty.Encoder.init(gpa, k, loop.frame_len, r.tmpdir);
            kenc.?.double_buffer = opts.double_buffer;
            placement = kitty.place(r.size, w, h, status_rows);
            area_cols = placement.cols;
            area_rows = placement.rows;
        } else {
            const a = halfblock.cellArea(cell.res);
            area_cols = a.cols;
            area_rows = a.rows;
            henc = try halfblock.Encoder.init(gpa, a.cols, a.rows, 1 + (r.size.cols - a.cols) / 2, 1);
        }
        const mode: halfblock.Mode = if (cell.transport == .@"half-diff") .diff else .full;

        r.titleCard(index, cell);
        if (term.interrupted.load(.acquire)) return error.Interrupted;
        try r.resync();

        const reader = r.reader;
        const base = reader.acks.load(.acquire);
        const kitty_errors0 = reader.kitty_errors.load(.acquire);
        const dur_ns: u64 = @intFromFloat(opts.duration_s * std.time.ns_per_s);
        const timeout_ns: u64 = @intFromFloat(opts.ack_timeout_s * std.time.ns_per_s);
        const period_ns: u64 = if (opts.fps > 0) @intFromFloat(std.time.ns_per_s / opts.fps) else 0;

        r.sample_count = 0;
        const start = term.nowNs();
        const deadline = start + dur_ns;
        const self0 = procstat.selfCpuNs();
        const term0 = r.termCpu();
        var sent: u64 = 0;
        var bytes: u64 = 0;
        var last_acks = base;
        var last_progress = start;
        var next_tick = start;
        // Paced: when the next frame is due. Missed slots are dropped, not
        // caught up in a burst, so stutter shows up in min fps.
        var due = start;
        var status: Status = .ok;
        var reason: ?[]const u8 = null;

        while (true) {
            var now = term.nowNs();
            if (now >= deadline) break;
            if (term.interrupted.load(.acquire)) {
                status = .interrupted;
                break;
            }
            if (reader.kitty_errors.load(.acquire) != kitty_errors0) {
                status = .failed;
                reason = try std.fmt.allocPrint(r.arena, "kitty error: {s}", .{reader.lastKittyError()});
                break;
            }
            const acks = reader.acks.load(.acquire);
            if (acks != last_acks) {
                last_acks = acks;
                last_progress = now;
            } else if (base + sent > acks and now - last_progress > timeout_ns) {
                status = .failed;
                reason = try std.fmt.allocPrint(r.arena, "no ack for {d} s", .{opts.ack_timeout_s});
                break;
            }

            if (now >= next_tick) {
                next_tick = now + tick_ns;
                if (kenc) |*e| e.release(acks - base);
                if (opts.overlay) bytes += r.statusBar(cell, index, now - start, .{
                    .t = now,
                    .acks = acks - base,
                    .self_cpu = procstat.selfCpuNs() - self0,
                    .term_cpu = r.termCpu() -| term0,
                    .bytes = bytes,
                });
            }

            // Backpressure: wait while max_inflight frames are unacknowledged.
            if (base + sent - acks >= opts.max_inflight) {
                _ = reader.waitAcks(base + sent - opts.max_inflight + 1, @min(deadline, last_progress + timeout_ns + 1, next_tick));
                continue;
            }
            if (period_ns > 0) {
                if (now < due) {
                    term.sleepNs(@min(due - now, next_tick -| now + 1));
                    continue;
                }
            }

            // The ack ring holds ring_len timestamps; stop before it wraps.
            if (sent >= reader_mod.ring_len) {
                std.log.warn("cell {d}: {d} frames, ack ring full; cell cut short", .{ index, sent });
                break;
            }
            // Nothing outstanding: the ack timeout starts with this frame,
            // not at the last ack (a pacing sleep may be longer than it).
            if (base + sent == acks) last_progress = now;
            if (period_ns > 0) due = @max(due, now) + period_ns;

            const frame = loop.frame(sent);
            const out = if (kenc) |*e| try e.encode(frame, w, h, placement) else try henc.?.encode(frame, w, h, mode);
            var wr = term.writeWatched(out);
            if (wr == .ok) wr = term.writeWatched("\x1b[5n");
            switch (wr) {
                .ok => {},
                .interrupted => {
                    status = .interrupted;
                    break;
                },
                .stalled => {
                    status = .failed;
                    reason = try std.fmt.allocPrint(r.arena, "write blocked for {d} s", .{opts.ack_timeout_s});
                    break;
                },
                .failed => return error.WriteFailed,
            }
            sent += 1;
            bytes += out.len + 4;
            now = term.nowNs();
        }

        const end = @min(term.nowNs(), deadline);
        const self_cpu = procstat.selfCpuNs() - self0;
        const term_cpu: ?u64 = if (r.procs.len > 0) r.termCpu() -| term0 else null;

        // Drain outstanding acks so file/shm objects are consumed before
        // they're unlinked, and so the next cell starts clean.
        const drained = status != .interrupted and reader.waitAcks(base + sent, term.nowNs() + drain_ns) >= base + sent;
        if (kenc) |*e| e.release(e.frames);
        _ = term.writeWatched(delete_images ++ "\x1b[0m\x1b[2J");

        const acked: usize = @intCast(@min(reader.acks.load(.acquire) - base, sent));
        const ack_times = try gpa.alloc(u64, acked);
        defer gpa.free(ack_times);
        const scratch = try gpa.alloc(u64, acked);
        defer gpa.free(scratch);
        var n: usize = 0;
        for (0..acked) |i| {
            const t = reader.ackTime(base + i);
            if (t >= end) break;
            ack_times[n] = t;
            n += 1;
        }
        const st = stats.compute(.{
            .start_ns = start,
            .end_ns = end,
            .acks = ack_times[0..n],
            .bytes = bytes,
            .self_cpu_ns = self_cpu,
            .term_cpu_ns = term_cpu,
        }, scratch);

        return .{
            .index = index,
            .transport = cell.transport,
            .res = cell.res,
            .scene = cell.scene,
            .format = if (kind == null) "halfblock" else if (fmt == .rgb) "rgb24" else "rgba32",
            .area_cols = area_cols,
            .area_rows = area_rows,
            .status = status,
            .reason = reason,
            .frames_sent = sent,
            .drained = drained,
            .stats = st,
            .pass = status == .ok and st.pass,
        };
    }
};

const spaces: [512]u8 = @splat(' ');

pub fn main(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, env: *const std.process.Environ.Map, opts: cli.Options, out: *Io.Writer) !u8 {
    const size = try term.size();

    // Preflight: half-block needs its fixed cell area plus the status row.
    var need_cols: u32 = 0;
    var need_rows: u32 = 0;
    if (opts.transport.contains(.@"half-full") or opts.transport.contains(.@"half-diff")) {
        var it = opts.res.iterator();
        while (it.next()) |res| {
            const a = halfblock.cellArea(res);
            need_cols = @max(need_cols, a.cols);
            need_rows = @max(need_rows, a.rows + status_rows);
        }
    }
    if (size.cols < need_cols or size.rows < need_rows) {
        term.restore();
        try out.print("termbench: window is {d}x{d} cells; half-block cells need at least {d}x{d}. Enlarge the window (or drop half-* transports).\n", .{ size.cols, size.rows, need_cols, need_rows });
        try out.flush();
        return 1;
    }

    const det = detect.probe(arena, env) catch |err| {
        term.restore();
        try out.print("termbench: capability probe failed: {t}\n", .{err});
        try out.flush();
        return 1;
    };
    const disc = try procstat.discover(arena, opts.term_pids[0..opts.term_pid_count]);
    std.log.info("terminal processes: {f}", .{std.json.fmt(disc, .{})});

    var name_buf: [32]u8 = undefined;
    var stamp_buf: [16]u8 = undefined;
    const term_name = det.terminalName(&name_buf);
    const stamp = util.utcStamp(io, &stamp_buf);
    const path = opts.out orelse try std.fmt.allocPrint(arena, "termbench-{s}-{s}.jsonl", .{ term_name, stamp });
    const file = Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        term.restore();
        try out.print("termbench: could not create {s}: {t}\n", .{ path, err });
        try out.flush();
        return 1;
    };
    defer file.close(io);
    var file_buf: [8192]u8 = undefined;
    var fw = file.writer(io, &file_buf);
    const jw = &fw.interface;

    const header: Header = .{
        .date = stamp,
        .machine = .{ .model = sysctlString(arena, "hw.model"), .cpu = sysctlString(arena, "machdep.cpu.brand_string"), .macos = sysctlString(arena, "kern.osproductversion") },
        .terminal = det.xtversion orelse det.env.TERM_PROGRAM orelse "unknown",
        .winsize = size,
        .cell_px = if (size.px_w == 0) null else .{ size.cellW(), size.cellH() },
        .term_procs = disc,
        .options = .{ .duration_s = opts.duration_s, .fps = opts.fps, .max_inflight = opts.max_inflight, .ack_timeout_s = opts.ack_timeout_s, .overlay = opts.overlay, .double_buffer = opts.double_buffer },
        .detect = det,
    };
    try writeLine(jw, header);

    var cells: std.ArrayList(Cell) = .empty;
    var res_it = opts.res.iterator();
    while (res_it.next()) |res| {
        var scene_it = opts.scene.iterator();
        while (scene_it.next()) |sc| {
            var tr_it = opts.transport.iterator();
            while (tr_it.next()) |tr| try cells.append(arena, .{ .res = res, .scene = sc, .transport = tr });
        }
    }

    var reader = try reader_mod.Reader.init(gpa);
    defer reader.deinit(gpa);
    reader.stall_ns = @intFromFloat(opts.ack_timeout_s * std.time.ns_per_s);
    try reader.start();

    var runner: Runner = .{
        .gpa = gpa,
        .arena = arena,
        .opts = opts,
        .reader = &reader,
        .procs = disc.procs,
        .size = size,
        .tmpdir = env.get("TMPDIR") orelse "/tmp",
        .cells_total = cells.items.len,
    };

    var results: std.ArrayList(CellResult) = .empty;
    var abort: ?[]const u8 = null;
    for (cells.items, 0..) |cell, i| {
        const res = runner.runCell(i, cell) catch |err| switch (err) {
            error.Interrupted => break,
            error.TerminalNotResponding, error.WriteFailed => {
                abort = @errorName(err);
                std.log.err("cell {d} ({t} {t} {t}): {t}; stopping", .{ i, cell.transport, cell.res, cell.scene, err });
                break;
            },
            else => return err,
        };
        std.log.info("cell: {f}", .{std.json.fmt(res, .{})});
        try writeLine(jw, res);
        try results.append(arena, res);
        if (res.status == .interrupted) break;
    }

    reader.join();
    term.restore();
    try printSummary(out, header, results.items, abort, path);
    try out.flush();
    if (term.interrupted.load(.acquire)) return 130;
    return if (abort != null) 1 else 0;
}

fn writeLine(w: *Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, w);
    try w.writeByte('\n');
    try w.flush();
}

fn sysctlString(arena: std.mem.Allocator, name: [*:0]const u8) ?[]const u8 {
    var len: usize = 0;
    if (c.sysctlbyname(name, null, &len, null, 0) != 0 or len == 0) return null;
    const buf = arena.alloc(u8, len) catch return null;
    if (c.sysctlbyname(name, buf.ptr, &len, null, 0) != 0) return null;
    return std.mem.trimEnd(u8, buf[0..len], "\x00");
}

fn printSummary(w: *Io.Writer, header: Header, results: []const CellResult, abort: ?[]const u8, path: []const u8) !void {
    try w.print("\n{s:<12} {s:<8} {s:<8} {s:>7} {s:>7} {s:>7} {s:>7} {s:>6} {s:>7} {s:>6} {s:>7} {s:>8}  {s}\n", .{
        "transport", "res", "scene", "avg", "min", "max", "p99 ms", "tb %", "tb ms/f", "term %", "term ms", "MB/s", "result",
    });
    for (results) |r| {
        const s = r.stats;
        var tp: [16]u8 = undefined;
        var tm: [16]u8 = undefined;
        try w.print("{s:<12} {s:<8} {s:<8} {d:>7.1} {d:>7.0} {d:>7.0} {d:>7.2} {d:>6.0} {d:>7.2} {s:>6} {s:>7} {d:>8.1}  {s}{s}{s}\n", .{
            @tagName(r.transport), @tagName(r.res), @tagName(r.scene),
            s.avg_fps,             s.min_fps,       s.max_fps,
            s.p99_frame_ms,        s.self_cpu_pct,  s.self_ms_per_frame,
            optFmt(&tp, "{d:.0}", s.term_cpu_pct),  optFmt(&tm, "{d:.2}", s.term_ms_per_frame),
            s.bytes_per_s / 1e6,
            switch (r.status) {
                .ok => if (r.pass) "PASS" else "FAIL",
                .failed => "FAILED",
                .interrupted => "INTERRUPTED",
            },
            if (r.reason != null) ": " else "",
            r.reason orelse "",
        });
    }
    try w.print("\nterminal: {s}   window: {d}x{d} cells, {d}x{d} px   termbench: {s}\n", .{
        header.terminal, header.winsize.cols, header.winsize.rows, header.winsize.px_w, header.winsize.px_h, header.termbench_optimize,
    });
    try w.writeAll("terminal processes:");
    for (header.term_procs.procs) |p| try w.print(" {s}({d})", .{ p.name, p.pid });
    try w.print("   via {t}\n", .{header.term_procs.method});
    if (abort) |a| try w.print("run stopped early: {s}\n", .{a});
    try w.print("results: {s}\n", .{path});
}

fn optFmt(buf: []u8, comptime f: []const u8, v: ?f64) []const u8 {
    const x = v orelse return "-";
    return std.fmt.bufPrint(buf, f, .{x}) catch "?";
}
