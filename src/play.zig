//! `temui play <rom> --core <path>`: run a game in the terminal (item 05).
//!
//! One thread, one loop (D8). Each iteration runs the frames the engine has
//! due, drains the core's contained stdio into the log, lets the viewer
//! present and redraw the boxes and status line, then waits for the earliest of the next
//! frame, the next present, the status-line check, the per-second stats log,
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
const Modes = @import("play/Modes.zig");
const Watchdog = @import("play/Watchdog.zig");
const key_decoder = @import("term/key_decoder.zig");
const overlay = @import("play/overlay.zig");
const stdio = @import("play/stdio.zig");

const log = std.log.scoped(.play);
const is_windows = builtin.os.tag == .windows;

/// The kitty keyboard flags pushed (D9): disambiguate, event types,
/// alternate keys and all keys as escape codes.
const kitty_flags: u8 = 15;

/// The input path: Windows console input always; otherwise `--keyboard`,
/// with `auto` following detection. Without the kitty protocol, `auto`
/// disables game input (D9); only `--keyboard legacy` gives the fixed hold.
fn inputPath(k: cli.Keyboard, detected: bool, windows: bool) Modes.Path {
    if (windows) return .console;
    return switch (k) {
        .kitty => .kitty,
        .legacy => .legacy,
        .auto => if (detected) .kitty else .disabled,
    };
}
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

    const path = inputPath(p.keyboard, cs.kitty_keyboard_flags != null, is_windows);
    if (is_windows) {
        log.info("keyboard: console input{s}", .{if (p.keyboard != .auto) " (--keyboard is ignored on Windows)" else ""});
    } else {
        switch (path) {
            .kitty => log.info("keyboard: kitty ({s}), pushing flags 15", .{if (p.keyboard == .auto) "detected" else "--keyboard"}),
            .legacy => log.info("keyboard: legacy (--keyboard, fixed 100 ms hold)", .{}),
            .disabled => log.info("keyboard: disabled (no kitty keyboard protocol detected)", .{}),
            .console => unreachable,
        }
    }

    session.enter(.{
        .alt_screen = true,
        .contain_stdio = if (log_mod.isActive()) .pipe else .discard,
        .kitty_keyboard_flags = if (path == .kitty) kitty_flags else null,
        .focus_events = true,
        // A paste is discarded, never read as keys (D9).
        .bracketed_paste = true,
        .vt_input = false,
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

    const si = host.systemInfo();
    const game = try std.fmt.allocPrint(arena_state.allocator(), "{s} · {s} {s}", .{ std.fs.path.stem(p.rom), si.name, si.version });

    // Armed just before the first wait; stopped (below) before teardown.
    var watchdog: Watchdog = .init(io, .{ .in = session.inFd() });
    var events: Events = Events.init(io, .{
        .in = session.inFd(),
        .out = session.outFd(),
        .stdio = pipe_fd,
        .handback = watchdog.handback(),
    }) catch |err| {
        diag.set("cannot wait for terminal events: {t}", .{err});
        return err;
    };
    defer events.deinit();

    var viewer: Viewer = Viewer.init(gpa, io, choice, clock, .{ .writeFn = writeTerminal }, .{
        .present_fps = present_fps,
        .detailed_stats = p.overlay,
        .window = startWindow(events.winSize(), cs.winsize),
    }) catch |err| {
        diag.set("cannot start the {t} renderer: {t}", .{ choice.backend, err });
        return err;
    };
    defer viewer.deinit(engine.stats());
    // Runs before the teardown above: nothing below may race the thread.
    defer watchdog.stop();

    // `--paused` shows the first frame: one step, presented at once.
    if (p.paused) engine.apply(.step, clock.now());

    var fx: Modes.Effects = .{};
    var modes: Modes = .init(.{ .path = path, .mode_key = p.mode_key });
    var decoder: key_decoder.Decoder = .init(if (path == .kitty) .kitty else .legacy);

    const start = clock.now();
    const end_ns: ?i96 = if (p.duration_s) |s| start + @as(i96, @intFromFloat(s * ns_per_s)) else null;
    var next_log = start + ns_per_s;

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
            .view = modes.view(),
            .game = game,
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
        deadline = earliest(deadline, modes.nextDeadline());
        if (!is_windows) deadline = earliest(deadline, decoder.deadline());

        // Armed once the loop runs, so detection and core loading never count.
        if (watchdog.thread == null) watchdog.start() catch |err| {
            diag.set("cannot start the watchdog thread: {t}", .{err});
            return err;
        };

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

        const t = clock.now();
        if (is_windows) {
            for (wake.keys) |in| {
                modes.handle(in, t, engine.paused(), &fx);
                if (applyEffects(&fx, &engine, &viewer, &decoder, t)) break :loop;
            }
        } else {
            // Raw bytes, for recording terminals' key sequences as test
            // fixtures (`--verbose`).
            if (wake.input.len > 0) log.debug("input: \"{f}\"", .{std.ascii.hexEscape(wake.input, .lower)});
            var it = decoder.feed(wake.input, t);
            while (it.next()) |in| {
                modes.handle(in, t, engine.paused(), &fx);
                if (applyEffects(&fx, &engine, &viewer, &decoder, t)) break :loop;
            }
            if (decoder.expire(t)) |in| modes.handle(in, t, engine.paused(), &fx);
            if (decoder.wantsQuery()) {
                // A key in legacy form: maybe the protocol is gone, maybe
                // the tail of a split sequence. The terminal says which.
                log.info("a key arrived in legacy form; asking the terminal for the kitty keyboard flags", .{});
                session.writeOut(session.kitty_query) catch |err| log.warn("kitty keyboard query: {t}", .{err});
                decoder.querySent(t);
            }
            if (decoder.takeAnswer()) |answer| keyboardAnswer(answer, &decoder, &modes, engine.paused(), t, &fx);
        }
        modes.tick(t, &fx);
        if (applyEffects(&fx, &engine, &viewer, &decoder, t)) break :loop;
    }

    const now = clock.now();
    var buf: [overlay.max_len]u8 = undefined;
    log.info("final stats: {s}", .{overlay.format(&buf, status(&engine, now), overlay.max_len)});
    try engine.stats().summary(summary, now);
    log.info("summary: {s}", .{std.mem.trimEnd(u8, summary.buffered(), "\n")});
}

/// The terminal's answer to a kitty keyboard query (POSIX): the one at
/// enter, one after a key in legacy form, or a recheck before game mode.
fn keyboardAnswer(answer: key_decoder.Answer, decoder: *key_decoder.Decoder, modes: *Modes, paused: bool, t: i96, fx: *Modes.Effects) void {
    if (modes.rechecking) {
        if (answer == .active) decoder.switchToKitty();
        modes.recheckDone(answer == .active, t, fx);
        return;
    }
    switch (answer) {
        .active => log.debug("kitty keyboard protocol active", .{}),
        .inactive => if (modes.path == .kitty) {
            log.warn("the kitty keyboard protocol isn't active", .{});
            // TUI keys still arrive, in legacy form.
            decoder.switchToLegacy();
            modes.switchToDisabled(paused, fx);
        },
    }
}

/// Asks the terminal for the kitty keyboard protocol again, for a recheck
/// before game mode (POSIX). A failed write leaves the query to time out.
fn recheckKeyboard(decoder: *key_decoder.Decoder, t: i96) void {
    session.requestKittyFlags(kitty_flags) catch |err| log.warn("kitty keyboard recheck: {t}", .{err});
    decoder.querySent(t);
}

/// Carries out `Modes`' effects, then clears them. Returns true to quit.
fn applyEffects(fx: *Modes.Effects, engine: *Engine, viewer: *Viewer, decoder: *key_decoder.Decoder, t: i96) bool {
    defer fx.clear();
    var quit = false;
    for (fx.slice()) |e| switch (e) {
        .engine => |cmd| {
            engine.apply(cmd, t);
            if (cmd != .set_input) viewer.statusChanged();
        },
        // The viewer compares the layers itself; this refreshes the status
        // line at once too.
        .layers_changed => viewer.statusChanged(),
        .toggle_stats => viewer.toggleStats(),
        .force_present => viewer.forcePresent(),
        // Never on Windows: the console path always has releases.
        .recheck_keyboard => if (!is_windows) recheckKeyboard(decoder, t),
        .quit => quit = true,
    };
    return quit;
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

test "input path: Windows is always console; auto follows detection" {
    try std.testing.expectEqual(Modes.Path.console, inputPath(.legacy, true, true));
    try std.testing.expectEqual(Modes.Path.console, inputPath(.auto, false, true));
    try std.testing.expectEqual(Modes.Path.kitty, inputPath(.auto, true, false));
    try std.testing.expectEqual(Modes.Path.disabled, inputPath(.auto, false, false));
    try std.testing.expectEqual(Modes.Path.kitty, inputPath(.kitty, false, false));
    try std.testing.expectEqual(Modes.Path.legacy, inputPath(.legacy, true, false));
}

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
