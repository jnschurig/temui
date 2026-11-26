//! `temui-bench live`: draws a frame loop in the real terminal through the
//! production renderer, paced (default 60 fps, missed slots dropped), with
//! `CSI 5 n` after every frame. A reader thread timestamps the `CSI 0 n`
//! replies (they come back in order), so the writer never waits for a round
//! trip; it only blocks when `max_inflight` frames are unacknowledged. This
//! is spike 02's acknowledgement method (termbench), on temui's renderer,
//! session and detection. POSIX only.

const std = @import("std");
const builtin = @import("builtin");
const temui = @import("temui");
const scene = @import("scene.zig");
const stats = @import("stats.zig");
const procstat = @import("procstat.zig");

const c = std.c;
const caps = temui.term.caps;
const session = temui.term.session;
const replies = temui.term.replies;
const Renderer = temui.render.Renderer;
const log = std.log.scoped(.bench);

const ms = std.time.ns_per_ms;
const drain_ns = 5 * std.time.ns_per_s;

pub const Config = struct {
    loop: *const scene.Loop,
    source: scene.Source,
    duration_s: f64,
    /// 0 = unpaced.
    fps: f64,
    renderer: ?caps.Backend,
    /// Kitty: try this transport first (inline zlib stays as the fallback).
    transport: ?caps.Transport,
    /// Draw into the top-left `cols`×`rows` cells instead of the window.
    cells: ?[2]u32,
    max_inflight: u32,
    /// Fail when frames are outstanding and no ack arrives for this long.
    ack_timeout_s: f64 = 1,
    term_pids: []const i32,
};

pub const Status = enum { ok, failed, interrupted };

pub const Result = struct {
    type: []const u8 = "live",
    optimize: []const u8,
    terminal: ?[]const u8,
    window: ?caps.WinSize,
    cell_px: caps.CellPx,
    source: scene.Source,
    frame_w: u32,
    frame_h: u32,
    backend: caps.Backend,
    /// Kitty: the transport in use at the end (null otherwise).
    transport: ?caps.Transport,
    /// Kitty: a runtime error moved it off the first transport in the order.
    transport_fell_back: bool,
    ascii_color: ?caps.AsciiColor,
    rect_cols: u32,
    rect_rows: u32,
    target_fps: f64,
    duration_s: f64,
    status: Status,
    reason: ?[]const u8 = null,
    frames_sent: u64,
    /// Paced: frame slots skipped because the writer was late.
    slots_dropped: u64,
    /// Every outstanding ack arrived after the run ended (within 5 s).
    drained: bool,
    /// Mean wall time of `present` plus the write, per frame.
    present_ms: f64,
    bytes_per_frame: f64,
    /// Bytes that arrived on stdin and weren't acks, DA1s or keys we use.
    stray_input_bytes: u64,
    term_procs: procstat.Discovery,
    stats: stats.Stats,
    /// status ok and every full 1-s window ≥ 60 fps.
    pass: bool,
};

// ---------------------------------------------------------------- clock

fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    var ts: c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = c.nanosleep(&ts, null);
}

fn realtimeIn(ns: u64) c.timespec {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.REALTIME, &ts);
    const total = @as(u64, @intCast(ts.nsec)) + ns;
    ts.sec += @intCast(total / std.time.ns_per_s);
    ts.nsec = @intCast(total % std.time.ns_per_s);
    return ts;
}

// ---------------------------------------------------------------- reader

/// Ring of ack timestamps; index = ack number mod len.
const ring_len = 1 << 20;

/// Background thread reading terminal replies and keys from `fd`.
const Reader = struct {
    fd: c.fd_t,
    ack_ns: []u64,
    /// Total DSR acks seen. Written only by the reader thread.
    acks: std.atomic.Value(u64) = .init(0),
    /// Total DA1 replies seen (resync sentinel).
    da1s: std.atomic.Value(u64) = .init(0),
    /// Ctrl-C or `q` was pressed (or the terminal went away).
    quit: std.atomic.Value(bool) = .init(false),
    stray: std.atomic.Value(u64) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    mutex: c.pthread_mutex_t = c.PTHREAD_MUTEX_INITIALIZER,
    cond: c.pthread_cond_t = c.PTHREAD_COND_INITIALIZER,
    thread: ?std.Thread = null,

    fn init(gpa: std.mem.Allocator, fd: c.fd_t) !Reader {
        return .{ .fd = fd, .ack_ns = try gpa.alloc(u64, ring_len) };
    }

    fn deinit(r: *Reader, gpa: std.mem.Allocator) void {
        r.join();
        gpa.free(r.ack_ns);
    }

    fn start(r: *Reader) !void {
        r.thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, readLoop, .{r});
    }

    fn join(r: *Reader) void {
        r.stop.store(true, .release);
        if (r.thread) |t| t.join();
        r.thread = null;
    }

    fn ackTime(r: *const Reader, n: u64) u64 {
        return r.ack_ns[n % ring_len];
    }

    fn waitAcks(r: *Reader, target: u64, deadline_ns: u64) u64 {
        return r.waitFor(&r.acks, target, deadline_ns);
    }

    fn waitDa1(r: *Reader, target: u64, deadline_ns: u64) u64 {
        return r.waitFor(&r.da1s, target, deadline_ns);
    }

    /// Blocks until `counter >= target`, the deadline passes, or quit.
    fn waitFor(r: *Reader, counter: *const std.atomic.Value(u64), target: u64, deadline_ns: u64) u64 {
        var n = counter.load(.acquire);
        if (n >= target) return n;
        _ = c.pthread_mutex_lock(&r.mutex);
        defer _ = c.pthread_mutex_unlock(&r.mutex);
        while (true) {
            n = counter.load(.acquire);
            if (n >= target or r.quit.load(.acquire)) return n;
            const now = nowNs();
            if (now >= deadline_ns) return n;
            // Wake at least every 50 ms to notice quit.
            var abs = realtimeIn(@min(deadline_ns - now, 50 * ms));
            _ = c.pthread_cond_timedwait(&r.cond, &r.mutex, &abs);
        }
    }

    fn readLoop(r: *Reader) void {
        var parser: replies.Parser = .{};
        var buf: [4096]u8 = undefined;
        var fds = [_]c.pollfd{.{ .fd = r.fd, .events = c.POLL.IN, .revents = 0 }};
        while (!r.stop.load(.acquire)) {
            if (c.poll(&fds, 1, 100) <= 0) continue;
            const n = c.read(r.fd, &buf, buf.len);
            if (n == 0) {
                // The terminal went away.
                r.quit.store(true, .release);
                return;
            }
            if (n < 0) continue;
            const now = nowNs();
            var new_acks: u64 = 0;
            var new_da1s: u64 = 0;
            const base = r.acks.load(.monotonic);
            for (buf[0..@intCast(n)]) |b| {
                const e = parser.feed(b) orelse continue;
                switch (e.kind) {
                    .dsr_ok => {
                        r.ack_ns[(base + new_acks) % ring_len] = now;
                        new_acks += 1;
                    },
                    .da1 => new_da1s += 1,
                    .ctrl_c => {
                        // A second Ctrl-C means the main thread is stuck
                        // (e.g. blocked writing to a frozen terminal).
                        if (r.quit.swap(true, .acq_rel)) {
                            session.restore();
                            c._exit(130);
                        }
                    },
                    .byte => if (e.body[0] == 'q') r.quit.store(true, .release) else {
                        _ = r.stray.fetchAdd(1, .monotonic);
                    },
                    else => _ = r.stray.fetchAdd(e.raw.len, .monotonic),
                }
            }
            if (new_da1s > 0) _ = r.da1s.fetchAdd(new_da1s, .acq_rel);
            if (new_acks > 0) r.acks.store(base + new_acks, .release);
            _ = c.pthread_mutex_lock(&r.mutex);
            _ = c.pthread_cond_signal(&r.cond);
            _ = c.pthread_mutex_unlock(&r.mutex);
        }
    }
};

/// Writes all of `bytes` to `fd`, retrying on EINTR and short writes.
fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (c._errno().* == @backingInt(c.E.INTR)) continue;
            return error.WriteFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

// ---------------------------------------------------------------- run

pub const Error = error{ NotATerminal, TerminalNotResponding };

/// Runs one live measurement. The terminal is restored before returning.
/// `NotATerminal`: stdin/stdout aren't a terminal (nothing was drawn).
pub fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cfg: Config, optimize: []const u8) !Result {
    if (comptime builtin.os.tag == .windows) return error.NotATerminal;

    session.enter(.{}) catch |err| switch (err) {
        error.NotATerminal => return error.NotATerminal,
        else => return err,
    };
    defer session.restore();

    const cs = try temui.term.detect.run(arena, io, env, .{});
    // Includes the kitty z-index (item 05), which the 02/04 baselines were
    // measured without: see docs/bench/04-renderers.md.
    var choice = caps.select(cs, cfg.renderer, .posix);
    if (cfg.transport) |t| {
        // Inline zlib stays last: the kitty backend needs it as a fallback.
        choice.transports = if (t == .zlib) .init(&.{.zlib}) else .init(&.{ t, .zlib });
    }
    const win = cs.winsize orelse return error.NotATerminal;
    const rect: Renderer.Rect = if (cfg.cells) |cr|
        .{ .col = 1, .row = 1, .cols = @min(cr[0], win.cols), .rows = @min(cr[1], win.rows) }
    else
        .{ .col = 1, .row = 1, .cols = win.cols, .rows = win.rows };
    log.info("live: {t} transports={any} rect={d}x{d} cell_px={d}x{d}", .{
        choice.backend, choice.transports.slice(), rect.cols, rect.rows, choice.cell_px.w, choice.cell_px.h,
    });

    const disc = try procstat.discover(arena, cfg.term_pids);
    log.info("terminal processes: {f}", .{std.json.fmt(disc, .{})});

    var r: Renderer = try .init(gpa, io, choice, .{ .kitty = .{ .prefix = "temui-bench" } });
    defer r.deinit();
    const first_transport: ?caps.Transport = if (r.impl == .kitty) r.impl.kitty.transport() else null;

    var reader = try Reader.init(gpa, 0);
    defer reader.deinit(gpa);
    try reader.start();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    // Resync: replies come in order, so once a fresh DA1 is answered no
    // stale reply can arrive later.
    try writeAll(1, "\x1b[c");
    if (reader.waitDa1(1, nowNs() + drain_ns) < 1 and !reader.quit.load(.acquire)) return error.TerminalNotResponding;

    const dur_ns: u64 = @intFromFloat(cfg.duration_s * std.time.ns_per_s);
    const timeout_ns: u64 = @intFromFloat(cfg.ack_timeout_s * std.time.ns_per_s);
    const period_ns: u64 = if (cfg.fps > 0) @intFromFloat(std.time.ns_per_s / cfg.fps) else 0;

    const base = reader.acks.load(.acquire);
    const start = nowNs();
    const deadline = start + dur_ns;
    const self0 = procstat.selfCpuNs();
    const term0 = procstat.cpuNs(disc.procs);
    var sent: u64 = 0;
    var dropped: u64 = 0;
    var bytes: u64 = 0;
    var present_ns: u64 = 0;
    var last_acks = base;
    var last_progress = start;
    // When the next frame is due. Missed slots are dropped, not caught up in
    // a burst, so stutter shows up in min fps.
    var due = start;
    var status: Status = .ok;
    var reason: ?[]const u8 = null;

    while (true) {
        const now = nowNs();
        if (now >= deadline) break;
        if (reader.quit.load(.acquire)) {
            status = .interrupted;
            break;
        }
        const acks = reader.acks.load(.acquire);
        if (acks != last_acks) {
            last_acks = acks;
            last_progress = now;
        } else if (base + sent > acks and now - last_progress > timeout_ns) {
            status = .failed;
            reason = try std.fmt.allocPrint(arena, "no ack for {d} s", .{cfg.ack_timeout_s});
            break;
        }
        // Backpressure: wait while max_inflight frames are unacknowledged.
        if (base + sent - acks >= cfg.max_inflight) {
            _ = reader.waitAcks(base + sent - cfg.max_inflight + 1, @min(deadline, last_progress + timeout_ns + 1));
            continue;
        }
        if (period_ns > 0 and now < due) {
            sleepNs(due - now);
            continue;
        }
        if (sent >= ring_len) {
            log.warn("live: {d} frames, ack ring full; run cut short", .{sent});
            break;
        }
        // Nothing outstanding: the ack timeout starts with this frame, not
        // at the last ack (a pacing sleep may be longer than it).
        if (base + sent == acks) last_progress = now;
        if (period_ns > 0) {
            due += period_ns;
            if (due <= now) {
                // A whole slot or more was missed: drop those slots but keep
                // the schedule's phase (re-basing on `now` would drift late
                // by every wake-up's overshoot).
                const missed = (now - due) / period_ns + 1;
                dropped += missed;
                due += missed * period_ns;
            }
        }

        aw.clearRetainingCapacity();
        try r.present(&aw.writer, cfg.loop.frame(sent), rect, .{});
        try aw.writer.writeAll("\x1b[5n");
        writeAll(1, aw.written()) catch {
            status = .failed;
            reason = "write to the terminal failed";
            break;
        };
        present_ns += nowNs() - now;
        sent += 1;
        bytes += aw.written().len;
    }

    const end = @min(nowNs(), deadline);
    const self_cpu = procstat.selfCpuNs() - self0;
    const term_cpu: ?u64 = if (disc.procs.len > 0) procstat.cpuNs(disc.procs) -| term0 else null;

    // Drain outstanding acks so file/shm objects are consumed before
    // `deinit` unlinks them.
    const drained = status != .interrupted and reader.waitAcks(base + sent, nowNs() + drain_ns) >= base + sent;
    const transport: ?caps.Transport = if (r.impl == .kitty) r.impl.kitty.transport() else null;
    aw.clearRetainingCapacity();
    try r.clear(&aw.writer);
    writeAll(1, aw.written()) catch {};
    reader.join();

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

    const sent_f: f64 = @floatFromInt(@max(sent, 1));
    return .{
        .optimize = optimize,
        .terminal = cs.xtversion orelse cs.term_program,
        .window = cs.winsize,
        .cell_px = choice.cell_px,
        .source = cfg.source,
        .frame_w = cfg.loop.width,
        .frame_h = cfg.loop.height,
        .backend = choice.backend,
        .transport = transport,
        .transport_fell_back = transport != first_transport,
        .ascii_color = if (choice.backend == .ascii) choice.ascii_color else null,
        .rect_cols = rect.cols,
        .rect_rows = rect.rows,
        .target_fps = cfg.fps,
        .duration_s = cfg.duration_s,
        .status = status,
        .reason = reason,
        .frames_sent = sent,
        .slots_dropped = dropped,
        .drained = drained,
        .present_ms = @as(f64, @floatFromInt(present_ns)) / sent_f / ms,
        .bytes_per_frame = @as(f64, @floatFromInt(bytes)) / sent_f,
        .stray_input_bytes = reader.stray.load(.monotonic),
        .term_procs = disc,
        .stats = st,
        .pass = status == .ok and st.pass,
    };
}

/// Prints one run's summary (after the terminal is restored).
pub fn printSummary(w: *std.Io.Writer, res: Result) !void {
    const s = res.stats;
    try w.print("terminal: {s}   window: ", .{res.terminal orelse "unknown"});
    if (res.window) |ws| try w.print("{d}x{d} cells, {d}x{d} px", .{ ws.cols, ws.rows, ws.px_w, ws.px_h }) else try w.writeAll("unknown");
    try w.print("   cell: {d}x{d} px   temui-bench: {s}\n", .{ res.cell_px.w, res.cell_px.h, res.optimize });
    try w.print("renderer: {t}", .{res.backend});
    if (res.transport) |t| try w.print(" ({t}{s})", .{ t, if (res.transport_fell_back) ", fell back" else "" });
    if (res.ascii_color) |a| try w.print(" ({t})", .{a});
    try w.print("   source: {t} {d}x{d}   rect: {d}x{d} cells   target: {d} fps for {d} s\n", .{
        res.source, res.frame_w, res.frame_h, res.rect_cols, res.rect_rows, res.target_fps, res.duration_s,
    });
    try w.print("frames: {d} sent, {d} acked, {d} slots dropped{s}\n", .{ res.frames_sent, s.frames, res.slots_dropped, if (res.drained or res.status == .interrupted) "" else " (not all drained)" });
    try w.print("fps: avg {d:.1}  min {d:.0}  max {d:.0}  (1-s windows: {d})   p99 interval: {d:.2} ms\n", .{
        s.avg_fps, s.min_fps, s.max_fps, s.windows, s.p99_frame_ms,
    });
    try w.print("temui: {d:.2} ms/frame CPU ({d:.0} %), present+write {d:.3} ms/frame, {d:.0} bytes/frame\n", .{
        s.self_ms_per_frame, s.self_cpu_pct, res.present_ms, res.bytes_per_frame,
    });
    if (s.term_cpu_pct) |pct| {
        try w.print("terminal: {d:.2} ms/frame CPU ({d:.0} %) over", .{ s.term_ms_per_frame.?, pct });
        for (res.term_procs.procs) |p| try w.print(" {s}({d})", .{ p.name, p.pid });
        try w.print(" via {t}\n", .{res.term_procs.method});
    } else try w.writeAll("terminal: CPU not measured\n");
    if (res.stray_input_bytes > 0) try w.print("stray input: {d} bytes (logged as ignored)\n", .{res.stray_input_bytes});
    try w.print("result: {s}{s}{s}\n", .{
        switch (res.status) {
            .ok => if (res.pass) "PASS (every 1-s window >= 60 fps)" else "FAIL (a 1-s window < 60 fps)",
            .failed => "FAILED",
            .interrupted => "INTERRUPTED",
        },
        if (res.reason != null) ": " else "",
        res.reason orelse "",
    });
}
