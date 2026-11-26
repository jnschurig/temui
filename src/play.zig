//! `temui play <rom> --core <path>`: run a game in the terminal (item 05).
//!
//! One thread, one loop (D8). Each iteration runs the frames the engine has
//! due, drains the core's contained stdio into the log, lets the viewer
//! present and redraw the overlay, then waits for the earliest of the next
//! frame, the next present, the overlay refresh, the per-second stats log,
//! the `--duration` end, a key or a resize.
//!
//! Startup order: detection (raw mode only while it queries), renderer
//! choice, the session (alternate screen, raw mode, stdio contained), and
//! only then the core, so anything it prints while loading is contained.
//! Teardown runs in reverse: viewer cleared, core unloaded (cores print in
//! `retro_deinit` too), C stdio flushed and drained into the log, session
//! restored. The summary is returned for the caller to print afterwards.

const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const log_mod = @import("log.zig");
const host = @import("libretro/host.zig");
const caps = @import("term/caps.zig");
const detect = @import("term/detect.zig");
const session = @import("term/session.zig");
const Renderer = @import("render/Renderer.zig");
const Engine = @import("play/Engine.zig");
const Viewer = @import("play/Viewer.zig");
const Events = @import("play/events.zig");
const keys = @import("play/keys.zig");
const overlay = @import("play/overlay.zig");
const stdio = @import("play/stdio.zig");

const log = std.log.scoped(.play);
const ns_per_s = std.time.ns_per_s;

/// Bounds for `engineBudget`: at least `min_budget_ns`, so an overdue
/// present doesn't shrink ticks to nothing, and at most `max_budget_ns`, so
/// keys stay responsive when the present period is long (e.g.
/// `--present-fps 0.2`) or presents are very slow.
const min_budget_ns: i96 = 1 * std.time.ns_per_ms;
const max_budget_ns: i96 = 20 * std.time.ns_per_ms;

/// The engine's time for one tick. It ends at the next present deadline, so
/// presents stay on time when frames are always due (unthrottled, or a high
/// speed). It is never shorter than the last present took (up to
/// `max_budget_ns`): when presents cost more than the present period (a
/// large frame, zlib, a slow terminal, a Debug build), every present is
/// overdue, and without that floor the engine got 1 ms per loop, so
/// unthrottled play fell to about one frame per present, below 1×. With it,
/// emulation gets at least half of each loop while a present takes up to
/// `max_budget_ns`.
pub fn engineBudget(now: i96, next_present_ns: i96, present_cost_ns: i96) u64 {
    const until_present = std.math.clamp(next_present_ns - now, min_budget_ns, max_budget_ns);
    return @intCast(@max(until_present, @min(present_cost_ns, max_budget_ns)));
}

/// The window size assumed when the terminal reports none.
const fallback_window: caps.WinSize = .{ .cols = 80, .rows = 24, .px_w = 0, .px_h = 0 };

/// The window to start in: the first size that is known and non-empty. A
/// pty whose size was never set reports 0x0 (a container's `-t` before its
/// first resize), which would draw nothing until a resize. A 0x0 resize
/// later on is taken as given: the window really is too small.
fn startWindow(now: ?caps.WinSize, at_detect: ?caps.WinSize) caps.WinSize {
    for ([_]?caps.WinSize{ now, at_detect }) |ws| {
        if (ws) |s| if (s.cols > 0 and s.rows > 0) return s;
    }
    return fallback_window;
}

/// Runs `play` until the user quits, `--duration` ends or input closes.
/// On success the exit summary is written to `summary` (print it once this
/// returns: the terminal is restored by then). On failure `diag` says why,
/// when known. `error.Interrupted`: Ctrl-C during detection.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: *const cli.Options,
    summary: *std.Io.Writer,
    diag: *host.Diagnostic,
) !void {
    const p = &opts.play;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const cs = detect.run(arena_state.allocator(), io, env, .{}) catch |err| {
        // Windows sends no queries, so it can't be interrupted.
        if (comptime builtin.os.tag != .windows) if (err == error.Interrupted) return error.Interrupted;
        if (err == error.InputNotPollable) {
            diag.set("{s}", .{detect.input_not_pollable_msg});
        } else diag.set("terminal detection failed: {t}", .{err});
        return err;
    };
    if (!cs.is_tty) {
        diag.set("play needs a terminal on stdin and stdout", .{});
        return error.NotATerminal;
    }
    const choice = caps.select(cs, opts.renderer, caps.osOf(builtin.os.tag));
    log.info("renderer: {t} ({s}) transports={any} kitty_z={d} cell_px={d}x{d}", .{
        choice.backend,            if (opts.renderer != null) "--renderer" else "auto",
        choice.transports.slice(), choice.kitty_z,
        choice.cell_px.w,          choice.cell_px.h,
    });

    session.enter(.{
        .alt_screen = true,
        .contain_stdio = if (log_mod.isActive()) .pipe else .discard,
    }) catch |err| {
        diag.set("cannot set up the terminal: {t}", .{err});
        return err;
    };
    // Closed only after `restore`: fds 1 and 2 point at its write end until
    // then, and writing to a pipe with no reader raises SIGPIPE.
    const pipe_fd = session.stdioPipe();
    defer if (pipe_fd) |fd| closeFd(fd);
    defer session.restore();
    var drain: ?stdio.Drain = if (pipe_fd) |fd| .{ .fd = fd } else null;
    defer {
        session.flushContained();
        if (drain) |*d| d.finish(stdio.LogSink{});
    }

    const rom_dir = std.fs.path.dirname(p.rom) orelse ".";
    try host.load(gpa, io, .{
        .core_path = p.core,
        .rom_path = p.rom,
        .system_dir = p.system_dir orelse rom_dir,
        .save_dir = p.save_dir orelse rom_dir,
        .options = p.options(),
    }, diag);
    defer host.unload();
    // stderr is contained, so warnings go to the log only.
    for (host.optionWarnings()) |w| log.warn("{s}", .{w});

    var io_copy = io;
    const clock: Engine.Clock = .{ .ctx = &io_copy, .nowFn = awakeNow };
    var engine: Engine = .init(clock, .{ .speed = p.speed, .paused = p.paused });
    const core_fps = engine.pacer.fps;
    const present_fps = p.present_fps orelse core_fps;
    log.info("play: core {d:.3} fps, speed {f}, present at most {d:.3} fps{s}", .{
        core_fps, SpeedFmt{ .s = p.speed }, present_fps, if (p.paused) ", paused" else "",
    });

    var events: Events = Events.init(io, .{
        .in = session.inFd(),
        .out = session.outFd(),
        .stdio = pipe_fd,
    }) catch |err| {
        diag.set("cannot wait for terminal events: {t}", .{err});
        return err;
    };
    defer events.deinit();

    var viewer: Viewer = Viewer.init(gpa, io, choice, clock, .{ .writeFn = writeTerminal }, .{
        .present_fps = present_fps,
        .overlay = p.overlay,
        .window = startWindow(events.winSize(), cs.winsize),
    }) catch |err| {
        diag.set("cannot start the {t} renderer: {t}", .{ choice.backend, err });
        return err;
    };
    defer viewer.deinit(engine.stats());

    // `--paused` shows the first frame: one step, presented at once.
    if (p.paused) engine.apply(.step, clock.now());

    const start = clock.now();
    const end_ns: ?i96 = if (p.duration_s) |s| start + @as(i96, @intFromFloat(s * ns_per_s)) else null;
    var next_log = start + ns_per_s;
    var decoder: keys.Decoder = .{};

    loop: while (true) {
        var now = clock.now();
        if (end_ns) |e| if (now >= e) {
            log.info("--duration reached", .{});
            break;
        };

        _ = try engine.tick(now, engineBudget(now, viewer.next_present_ns, viewer.present_cost_ns));
        if (drain) |*d| d.drain(stdio.LogSink{});

        now = clock.now();
        viewer.update(.{
            .frame = Renderer.frameFrom(engine.frame()),
            .seq = engine.frameSeq(),
            .aspect = if (engine.aspect()) |a| @floatCast(a) else null,
            .on_schedule = engine.onSchedule(),
            .status = status(&engine, now),
        }, engine.stats(), now) catch |err| {
            diag.set("drawing failed: {t}", .{err});
            return err;
        };

        if (now >= next_log) {
            var buf: [overlay.max_len]u8 = undefined;
            log.info("stats: {s}", .{overlay.format(&buf, status(&engine, now), overlay.max_len)});
            next_log = Viewer.nextPresent(next_log, now, ns_per_s);
        }

        // Unthrottled and running: frames are always due, so don't block.
        var deadline: ?i96 = if (engine.speed() == .max and !engine.paused()) now else engine.nextDeadline();
        deadline = earliest(deadline, viewer.nextDeadline(engine.frameSeq(), now));
        deadline = earliest(deadline, next_log);
        deadline = earliest(deadline, end_ns);

        const wake = events.wait(deadline) catch |err| {
            diag.set("waiting for input failed: {t}", .{err});
            return err;
        };
        if (wake.eof) {
            log.info("terminal input closed; quitting", .{});
            break;
        }
        if (wake.resized) viewer.resize(events.winSize(), engine.stats()) catch |err| {
            diag.set("redrawing after a resize failed: {t}", .{err});
            return err;
        };
        if (wake.stdio_ready) if (drain) |*d| d.drain(stdio.LogSink{});

        var it = decoder.feed(wake.input, clock.now());
        while (it.next()) |action| {
            const t = clock.now();
            switch (action) {
                .quit => break :loop,
                .toggle_pause => engine.apply(if (engine.paused()) .@"resume" else .pause, t),
                .step => if (engine.paused()) {
                    engine.apply(.step, t);
                    viewer.forcePresent();
                },
                .faster => engine.apply(.faster, t),
                .slower => engine.apply(.slower, t),
                .reset_speed => engine.apply(.reset_speed, t),
                .toggle_overlay => viewer.toggleOverlay(),
            }
            if (action != .toggle_overlay) viewer.overlayChanged();
            log.debug("key: {t} (speed {f}{s})", .{ action, SpeedFmt{ .s = engine.speed() }, if (engine.paused()) ", paused" else "" });
        }
    }

    const now = clock.now();
    var buf: [overlay.max_len]u8 = undefined;
    log.info("final stats: {s}", .{overlay.format(&buf, status(&engine, now), overlay.max_len)});
    try engine.stats().summary(summary, now);
    log.info("summary: {s}", .{std.mem.trimEnd(u8, summary.buffered(), "\n")});
}

fn status(e: *Engine, now: i96) overlay.State {
    return .{
        .rates = e.stats().rates(now),
        .speed = e.speed(),
        .paused = e.paused(),
        .rebases = e.stats().rebases,
    };
}

fn earliest(a: ?i96, b: ?i96) ?i96 {
    const x = a orelse return b;
    const y = b orelse return x;
    return @min(x, y);
}

fn awakeNow(ctx: ?*anyopaque) i96 {
    const io: *const std.Io = @ptrCast(@alignCast(ctx.?));
    return std.Io.Clock.awake.now(io.*).nanoseconds;
}

fn writeTerminal(_: ?*anyopaque, bytes: []const u8) error{WriteFailed}!void {
    return session.writeOut(bytes);
}

fn closeFd(fd: session.Fd) void {
    if (builtin.os.tag != .windows) _ = std.c.close(fd);
}

const SpeedFmt = struct {
    s: Engine.Speed,

    pub fn format(f: SpeedFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (f.s) {
            .max => try w.writeAll("max"),
            .x => |x| try w.print("{d}x", .{x}),
        }
    }
};

test "engine budget: up to the next present, never less than the last present took" {
    const ms = std.time.ns_per_ms;
    // Cheap presents: time left until the next one, within the bounds.
    try std.testing.expectEqual(10 * ms, engineBudget(0, 10 * ms, 2 * ms));
    try std.testing.expectEqual(1 * ms, engineBudget(50 * ms, 10 * ms, 0)); // overdue
    try std.testing.expectEqual(20 * ms, engineBudget(0, 5000 * ms, 2 * ms)); // long period
    // Slow presents: at least as long as the last one took...
    try std.testing.expectEqual(16 * ms, engineBudget(50 * ms, 10 * ms, 16 * ms));
    try std.testing.expectEqual(16 * ms, engineBudget(0, 10 * ms, 16 * ms));
    // ...but never past the upper bound.
    try std.testing.expectEqual(20 * ms, engineBudget(50 * ms, 10 * ms, 80 * ms));
}

test "start window: a 0x0 size counts as unknown" {
    const zero: caps.WinSize = .{ .cols = 0, .rows = 0, .px_w = 0, .px_h = 0 };
    const at_detect: caps.WinSize = .{ .cols = 100, .rows = 30, .px_w = 0, .px_h = 0 };
    const now: caps.WinSize = .{ .cols = 120, .rows = 40, .px_w = 0, .px_h = 0 };
    try std.testing.expectEqual(now, startWindow(now, at_detect));
    try std.testing.expectEqual(at_detect, startWindow(zero, at_detect));
    try std.testing.expectEqual(at_detect, startWindow(null, at_detect));
    try std.testing.expectEqual(fallback_window, startWindow(zero, zero));
    try std.testing.expectEqual(fallback_window, startWindow(null, null));
    try std.testing.expectEqual(fallback_window, startWindow(.{ .cols = 80, .rows = 0, .px_w = 0, .px_h = 0 }, null));
}
