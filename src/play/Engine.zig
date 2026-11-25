//! The play loop's engine (D5, D8): the loaded core, its frame schedule and
//! the run's stats. It never touches the terminal; the viewer drives it with
//! `Command`s and reads frames and stats back. The commands mirror D6's
//! pause / resume / step / set speed, so item 12 can map socket commands
//! straight onto `apply`.
//!
//! Times come from a `Clock` the caller supplies, so tests use a fake one.
//!
//! A mid-game fps change from the core (`SET_SYSTEM_AV_INFO`) is not
//! followed: the schedule keeps the fps reported at load.

const std = @import("std");
const host = @import("../libretro/host.zig");
const Pacer = @import("Pacer.zig");
const Stats = @import("Stats.zig");

const log = std.log.scoped(.play);

pub const Speed = Pacer.Speed;

const Engine = @This();

/// Monotonic nanoseconds.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    nowFn: *const fn (?*anyopaque) i96,

    pub fn now(c: Clock) i96 {
        return c.nowFn(c.ctx);
    }
};

pub const Config = struct {
    speed: Speed = .normal,
    paused: bool = false,
};

pub const Command = union(enum) {
    pause,
    @"resume",
    /// One frame; only while paused.
    step,
    set_speed: Speed,
    faster,
    slower,
    reset_speed,
    quit,
};

pub const Tick = struct {
    /// Frames run in this tick.
    ran: u64 = 0,
    /// The current frame differs from the one before the tick.
    frame_changed: bool = false,
};

/// Used when a core reports no usable fps.
const fallback_fps = 60;

clock: Clock,
pacer: Pacer,
stats_: Stats,
/// Incremented for every frame run; the viewer compares it to what it
/// last presented.
frame_seq: u64 = 0,
quit_requested: bool = false,
/// The last tick ran every frame that was due (it was not cut short by
/// its time budget). Always true unthrottled or paused.
on_schedule: bool = true,

/// Over the already-loaded `host`.
pub fn init(clock: Clock, config: Config) Engine {
    const now = clock.now();
    var fps = host.avInfo().timing.fps;
    if (!(fps > 0) or !std.math.isFinite(fps)) {
        log.warn("core reports {d} fps; pacing at {d}", .{ fps, fallback_fps });
        fps = fallback_fps;
    }
    return .{
        .clock = clock,
        .pacer = .init(fps, config.speed, config.paused, now),
        .stats_ = .init(now),
    };
}

pub fn apply(e: *Engine, cmd: Command, now: i96) void {
    const p = &e.pacer;
    switch (cmd) {
        .pause => p.pause(),
        .@"resume" => p.resumeAt(now),
        .step => p.step(),
        .set_speed => |s| p.setSpeed(s, now),
        .faster => p.setSpeed(p.speed.faster(), now),
        .slower => p.setSpeed(p.speed.slower(), now),
        .reset_speed => p.setSpeed(.normal, now),
        .quit => e.quit_requested = true,
    }
}

/// Runs the frames due at `now`, back to back, discarding their audio.
/// Stops early once `budget_ns` has passed (always the case unthrottled),
/// leaving the rest for the next tick.
pub fn tick(e: *Engine, now: i96, budget_ns: u64) error{OutOfMemory}!Tick {
    const rebases = e.pacer.rebases;
    const due = e.pacer.due(now);
    if (e.pacer.rebases != rebases) {
        e.stats_.rebased();
        log.info("fell more than {d} ms behind; schedule re-based ({d} so far)", .{
            @divTrunc(Pacer.max_lag_ns, std.time.ns_per_ms), e.pacer.rebases,
        });
    }
    var t: Tick = .{};
    var end = now;
    while (t.ran < due) {
        try host.runFrame();
        _ = host.drainAudio(); // not played until item 09
        t.ran += 1;
        e.frame_seq += 1;
        end = e.clock.now();
        if (end - now >= @as(i96, budget_ns)) break;
    }
    e.pacer.ran(t.ran);
    if (t.ran > 0) e.stats_.emulated(end, t.ran);
    t.frame_changed = t.ran > 0;
    e.on_schedule = e.pacer.speed == .max or e.pacer.paused or t.ran == due;
    return t;
}

/// When the next frame is due; null when paused or unthrottled.
pub fn nextDeadline(e: *const Engine) ?i96 {
    return e.pacer.nextDeadline();
}

/// The latest frame (0×0 before the first).
pub fn frame(_: *const Engine) host.Frame {
    return host.frame();
}

pub fn frameSeq(e: *const Engine) u64 {
    return e.frame_seq;
}

/// The core's display aspect (width / height), or null when it reports
/// none (then the frame's own shape is used).
pub fn aspect(_: *const Engine) ?f64 {
    const a: f64 = host.avInfo().geometry.aspect_ratio;
    return if (a > 0 and std.math.isFinite(a)) a else null;
}

pub fn stats(e: *Engine) *Stats {
    return &e.stats_;
}

pub fn speed(e: *const Engine) Speed {
    return e.pacer.speed;
}

pub fn paused(e: *const Engine) bool {
    return e.pacer.paused;
}

pub fn onSchedule(e: *const Engine) bool {
    return e.on_schedule;
}

pub fn quitRequested(e: *const Engine) bool {
    return e.quit_requested;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const ns_per_s = std.time.ns_per_s;

/// Every read advances it by `per_read`, then returns it: the cost of a
/// frame, as the engine reads the clock once after each frame it runs.
const FakeClock = struct {
    t: i96 = 0,
    per_read: i96 = 0,

    fn read(ctx: ?*anyopaque) i96 {
        const f: *FakeClock = @ptrCast(@alignCast(ctx.?));
        f.t += f.per_read;
        return f.t;
    }

    fn clock(f: *FakeClock) Clock {
        return .{ .ctx = f, .nowFn = read };
    }
};

fn loadTestCore() !void {
    const o = @import("test_options");
    const dir = std.fs.path.dirname(o.testcore_rom) orelse ".";
    var diag: host.Diagnostic = .{};
    host.load(testing.allocator, testing.io, .{
        .core_path = o.test_core_path,
        .rom_path = o.testcore_rom,
        .system_dir = dir,
        .save_dir = dir,
    }, &diag) catch |err| {
        std.debug.print("load failed: {s}\n", .{diag.message()});
        return err;
    };
}

/// The test core's frame counter: u32 LE at SRAM offset 0.
fn coreFrames() u32 {
    const sram = host.memory(@import("libretro").RETRO_MEMORY_SAVE_RAM).?;
    return std.mem.readInt(u32, sram[0..4], .little);
}

const no_budget = std.math.maxInt(u64);

test "N steps while paused advance the core's frame counter by exactly N" {
    try loadTestCore();
    defer host.unload();
    var fc: FakeClock = .{};
    var e: Engine = .init(fc.clock(), .{ .paused = true });
    try testing.expectEqual(0, (try e.tick(fc.t, no_budget)).ran);
    const before = coreFrames();
    for (0..7) |_| {
        e.apply(.step, fc.t);
        const t = try e.tick(fc.t, no_budget);
        try testing.expectEqual(1, t.ran);
        try testing.expect(t.frame_changed);
        try testing.expectEqual(0, (try e.tick(fc.t, no_budget)).ran);
    }
    try testing.expectEqual(before + 7, coreFrames());
    try testing.expectEqual(7, e.frameSeq());
    try testing.expectEqual(null, e.nextDeadline());
}

test "one simulated second at 1x runs 60 frames" {
    try loadTestCore();
    defer host.unload();
    var fc: FakeClock = .{ .t = 10 * ns_per_s };
    var e: Engine = .init(fc.clock(), .{});
    const end = fc.t + ns_per_s;
    var now = fc.t;
    while (now < end) {
        _ = try e.tick(now, no_budget);
        try testing.expect(e.onSchedule());
        now = e.nextDeadline().?;
    }
    try testing.expectEqual(60, e.frameSeq());
    try testing.expectEqual(60, e.stats().totals.emulated);
    try testing.expectEqual(0, e.stats().rebases);
    try testing.expectEqual(null, e.aspect()); // the test core reports 0
}

test "unthrottled stops at the budget" {
    try loadTestCore();
    defer host.unload();
    // Each frame costs 1 ms; a 16 ms budget runs 16.
    var fc: FakeClock = .{ .per_read = std.time.ns_per_ms };
    var e: Engine = .init(fc.clock(), .{ .speed = .max });
    try testing.expectEqual(null, e.nextDeadline());
    const t = try e.tick(fc.t, 16 * std.time.ns_per_ms);
    try testing.expectEqual(16, t.ran);
    try testing.expect(e.onSchedule());
}

test "a catch-up burst cut by the budget is off schedule until it finishes" {
    try loadTestCore();
    defer host.unload();
    var fc: FakeClock = .{};
    var e: Engine = .init(fc.clock(), .{});
    _ = try e.tick(fc.t, no_budget);
    // 90 ms late: 6 frames due; each costs 1 ms, the budget allows 3.
    fc.per_read = std.time.ns_per_ms;
    const now = e.nextDeadline().? + 90 * std.time.ns_per_ms;
    fc.t = now;
    try testing.expectEqual(3, (try e.tick(now, 3 * std.time.ns_per_ms)).ran);
    try testing.expect(!e.onSchedule());
    try testing.expectEqual(3, (try e.tick(fc.t, no_budget)).ran);
    try testing.expect(e.onSchedule());
    try testing.expectEqual(0, e.stats().rebases);
}

test "pause runs nothing; a long stall is counted as a re-base" {
    try loadTestCore();
    defer host.unload();
    var fc: FakeClock = .{};
    var e: Engine = .init(fc.clock(), .{});
    _ = try e.tick(0, no_budget);
    e.apply(.pause, 0);
    try testing.expect(e.paused());
    try testing.expectEqual(0, (try e.tick(5 * ns_per_s, no_budget)).ran);
    e.apply(.@"resume", 5 * ns_per_s);
    try testing.expectEqual(1, (try e.tick(5 * ns_per_s, no_budget)).ran);
    try testing.expectEqual(0, e.stats().rebases);
    // 200 ms stall: re-base, one frame, counted.
    try testing.expectEqual(1, (try e.tick(5 * ns_per_s + 200 * std.time.ns_per_ms, no_budget)).ran);
    try testing.expectEqual(1, e.stats().rebases);
}

test "speed commands walk the ladder; quit is recorded" {
    try loadTestCore();
    defer host.unload();
    var fc: FakeClock = .{};
    var e: Engine = .init(fc.clock(), .{ .speed = .{ .x = 3 } });
    e.apply(.faster, 0);
    try testing.expect(e.speed().eql(.{ .x = 4 }));
    e.apply(.slower, 0);
    e.apply(.slower, 0);
    try testing.expect(e.speed().eql(.{ .x = 1 }));
    e.apply(.{ .set_speed = .max }, 0);
    try testing.expect(e.speed().eql(.max));
    e.apply(.reset_speed, 0);
    try testing.expect(e.speed().eql(.normal));
    try testing.expect(!e.quitRequested());
    e.apply(.quit, 0);
    try testing.expect(e.quitRequested());
}
