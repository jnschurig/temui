//! The play loop's viewer (D5, D7, D8): draws the engine's latest frame
//! through the `Renderer`, at most `present_fps` times a second, with the
//! stats overlay on top. It knows nothing of the libretro host: the loop
//! hands it a `Source` (the frame and the engine's state) each iteration.
//!
//! Everything for one update goes into one buffer and reaches the terminal
//! in one write, which is timed and counted in `Stats` (bytes and write
//! time), so a slow terminal shows up in the stats.

const std = @import("std");
const caps = @import("../term/caps.zig");
const Renderer = @import("../render/Renderer.zig");
const sgr = @import("../render/sgr.zig");
const Engine = @import("Engine.zig");
const Stats = @import("Stats.zig");
const overlay = @import("overlay.zig");

const Viewer = @This();

const Rect = Renderer.Rect;
const log = std.log.scoped(.play);

/// The overlay text refreshes at most this often.
pub const overlay_period_ns: i96 = 250 * std.time.ns_per_ms;

/// Where finished updates go: the terminal (`session.writeOut`) in play,
/// a buffer in tests.
pub const Output = struct {
    ctx: ?*anyopaque = null,
    writeFn: *const fn (?*anyopaque, []const u8) error{WriteFailed}!void,

    fn write(o: Output, bytes: []const u8) error{WriteFailed}!void {
        return o.writeFn(o.ctx, bytes);
    }
};

pub const Config = struct {
    /// Present at most this many times a second (> 0).
    present_fps: f64,
    overlay: bool = false,
    /// The window, in cells; `rect` starts as all of it.
    window: caps.WinSize,
};

/// What the viewer reads from the engine each update.
pub const Source = struct {
    frame: Renderer.Frame,
    /// Increments for every frame the engine runs.
    seq: u64,
    /// The core's display aspect, or null for the frame's own.
    aspect: ?f32,
    /// The engine ran everything due in its last tick (not catching up).
    on_schedule: bool,
    /// For the overlay text.
    status: overlay.State,
};

renderer: Renderer,
clock: Engine.Clock,
output: Output,
/// Overlay colours: reverse video where the terminal may lack 256 colours.
basic_color: bool,
rect: Rect,
cell_px: caps.CellPx,
period_ns: i96,
next_present_ns: i96,
/// `Source.seq` at the last present.
presented_seq: u64 = 0,
/// Present on the next update whatever the rate (resize, step, toggle).
force: bool = true,
overlay_shown: bool,
overlay_buf: [overlay.max_len]u8 = undefined,
overlay_len: usize = 0,
next_overlay_ns: i96 = 0,
/// The cells the overlay currently covers on screen.
drawn: ?Rect = null,
/// What the last present cost: encoding plus writing (0 before the first).
present_cost_ns: i96 = 0,
buf: std.Io.Writer.Allocating,

pub fn init(gpa: std.mem.Allocator, io: std.Io, choice: caps.Choice, clock: Engine.Clock, output: Output, cfg: Config) !Viewer {
    std.debug.assert(cfg.present_fps > 0);
    return .{
        .renderer = try .init(gpa, io, choice, .{}),
        .clock = clock,
        .output = output,
        .basic_color = choice.backend == .ascii and choice.ascii_color == .none,
        .rect = windowRect(cfg.window),
        .cell_px = choice.cell_px,
        .period_ns = @intFromFloat(@max(1, @round(std.time.ns_per_s / cfg.present_fps))),
        .next_present_ns = clock.now(),
        .overlay_shown = cfg.overlay,
        .buf = .init(gpa),
    };
}

/// Removes what was drawn (kitty images, the frame's cells, the overlay),
/// then frees memory. Call before the session is restored.
pub fn deinit(v: *Viewer, stats: *Stats) void {
    v.buf.clearRetainingCapacity();
    const w = &v.buf.writer;
    blk: {
        if (v.drawn) |d| sgr.clearRect(w, d) catch break :blk;
        v.renderer.clear(w) catch break :blk;
        v.flush(stats) catch |err| log.warn("final clear failed: {t}", .{err});
    }
    v.renderer.deinit();
    v.buf.deinit();
    v.* = undefined;
}

fn windowRect(ws: caps.WinSize) Rect {
    return .{ .col = 1, .row = 1, .cols = ws.cols, .rows = ws.rows };
}

/// The present rule, pure for testing: a new frame once the present
/// deadline has passed; or a forced repaint. While emulation is catching
/// up, presenting waits for it, but at most one more period: a core that
/// can't keep up is behind for good, and must still be shown (at half
/// the present rate, since `nextPresent` then restarts the period).
pub fn shouldPresent(p: struct {
    now: i96,
    next_present_ns: i96,
    period_ns: i96,
    new_frame: bool,
    on_schedule: bool,
    forced: bool,
}) bool {
    if (p.forced) return true;
    if (!p.new_frame or p.now < p.next_present_ns) return false;
    return p.on_schedule or p.now - p.next_present_ns >= p.period_ns;
}

/// The next present deadline after presenting at `now`: one period on from
/// the last deadline, so the rate doesn't drift with wake-up jitter, but
/// never a burst to make up for a long gap.
pub fn nextPresent(next_ns: i96, now: i96, period_ns: i96) i96 {
    if (now - next_ns >= period_ns) return now + period_ns;
    return next_ns + period_ns;
}

/// When the viewer next needs an update, or null when only the engine (a
/// new frame) or input can make it need one.
pub fn nextDeadline(v: *const Viewer, src_seq: u64, now: i96) ?i96 {
    if (v.force) return now;
    var d: ?i96 = null;
    if (src_seq != v.presented_seq) d = v.next_present_ns;
    if (v.overlay_shown) d = if (d) |x| @min(x, v.next_overlay_ns) else v.next_overlay_ns;
    return d;
}

/// Repaints everything on the next update (e.g. after a step).
pub fn forcePresent(v: *Viewer) void {
    v.force = true;
}

/// Shows or hides the overlay; the next update redraws it, or repaints
/// the cells it covered.
pub fn toggleOverlay(v: *Viewer) void {
    v.overlay_shown = !v.overlay_shown;
    v.next_overlay_ns = 0;
    v.force = true;
}

/// Refreshes the overlay text on the next update (the speed or pause
/// state changed).
pub fn overlayChanged(v: *Viewer) void {
    v.next_overlay_ns = 0;
}

pub fn overlayShown(v: *const Viewer) bool {
    return v.overlay_shown;
}

/// The window changed size: clear the screen and everything drawn, take the
/// new size (and cell size, when the terminal reports pixels) and repaint
/// on the next update. A null size keeps the old one.
pub fn resize(v: *Viewer, ws: ?caps.WinSize, stats: *Stats) !void {
    v.buf.clearRetainingCapacity();
    const w = &v.buf.writer;
    try v.renderer.clear(w);
    try w.writeAll("\x1b[0m\x1b[2J");
    if (ws) |s| {
        v.rect = windowRect(s);
        if (s.cols > 0 and s.rows > 0 and s.px_w >= s.cols and s.px_h >= s.rows)
            v.cell_px = .{ .w = s.px_w / s.cols, .h = s.px_h / s.rows };
        log.debug("resized to {d}x{d} cells, cell {d}x{d} px", .{ s.cols, s.rows, v.cell_px.w, v.cell_px.h });
    }
    v.renderer.resize(v.cell_px);
    v.drawn = null;
    v.force = true;
    try v.flush(stats);
}

/// Presents and redraws the overlay if due. Writes nothing when neither is.
pub fn update(v: *Viewer, src: Source, stats: *Stats, now: i96) !void {
    const new_frame = src.seq != v.presented_seq;
    var present = shouldPresent(.{
        .now = now,
        .next_present_ns = v.next_present_ns,
        .period_ns = v.period_ns,
        .new_frame = new_frame,
        .on_schedule = src.on_schedule,
        .forced = v.force,
    });
    const text_due = v.overlay_shown and now >= v.next_overlay_ns;
    if (!present and !text_due) return;

    if (text_due) {
        // Wide enough for the whole line; cut to the box below.
        v.overlay_len = overlay.format(&v.overlay_buf, src.status, overlay.max_len).len;
        v.next_overlay_ns = now + overlay_period_ns;
    }
    const box = v.renderer.fitted(src.frame, v.rect, src.aspect);
    const text = if (v.overlay_shown and !box.isEmpty()) truncate(v.overlay_buf[0..v.overlay_len], box.cols) else "";
    const cover: ?Rect = if (text.len == 0) null else .{
        .col = box.col,
        .row = box.row,
        .cols = @intCast(std.unicode.utf8CountCodepoints(text) catch text.len),
        .rows = 1,
    };

    v.buf.clearRetainingCapacity();
    const w = &v.buf.writer;
    if (v.drawn) |d| if (cover == null or !rectEql(d, cover.?)) {
        // Uncover the old cells. Kitty's image shows through blank cells;
        // the cell backends repaint them on a present.
        try w.writeAll("\x1b[0m");
        try sgr.clearRect(w, d);
        if (v.renderer.backend() != .kitty) present = true;
    };
    const t0 = v.clock.now();
    if (present) {
        const covers: []const Rect = if (cover) |*c| c[0..1] else &.{};
        try v.renderer.present(w, src.frame, v.rect, .{ .aspect = src.aspect, .occlude = covers });
        // A window too small for the picture draws nothing: not a present.
        if (!box.isEmpty()) {
            const t1 = v.clock.now();
            stats.encoded(t1, @intCast(@max(t1 - t0, 0)));
            stats.presented(now);
        }
        v.presented_seq = src.seq;
        v.next_present_ns = nextPresent(v.next_present_ns, now, v.period_ns);
        v.force = false;
    }
    if (cover) |c| {
        try sgr.cup(w, c.row, c.col);
        try w.writeAll(if (v.basic_color) "\x1b[0;7m" else "\x1b[0;38;5;252;48;5;236m");
        try w.writeAll(text);
        try w.writeAll("\x1b[0m");
    }
    v.drawn = cover;
    try v.flush(stats);
    if (present) v.present_cost_ns = @max(v.clock.now() - t0, 0);
}

fn truncate(text: []const u8, cols: u32) []const u8 {
    var n: u32 = 0;
    var it: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (n < cols) : (n += 1) {
        _ = it.nextCodepointSlice() orelse break;
    }
    return text[0..it.i];
}

fn rectEql(a: Rect, b: Rect) bool {
    return a.col == b.col and a.row == b.row and a.cols == b.cols and a.rows == b.rows;
}

/// Writes the buffer to the terminal in one go, timed.
fn flush(v: *Viewer, stats: *Stats) !void {
    const bytes = v.buf.written();
    if (bytes.len == 0) return;
    const t0 = v.clock.now();
    try v.output.write(bytes);
    const t1 = v.clock.now();
    stats.wrote(t1, bytes.len, @intCast(@max(t1 - t0, 0)));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const ms = std.time.ns_per_ms;

test "present rule" {
    const P = struct {
        fn at(now: i96, new_frame: bool, on_schedule: bool, forced: bool) bool {
            return shouldPresent(.{ .now = now, .next_present_ns = 100, .period_ns = 50, .new_frame = new_frame, .on_schedule = on_schedule, .forced = forced });
        }
    };
    try testing.expect(P.at(100, true, true, false));
    // Before the deadline.
    try testing.expect(!P.at(99, true, true, false));
    // No new frame: never re-send an unchanged one.
    try testing.expect(!P.at(500, false, true, false));
    // Catching up: wait for emulation, but at most one more period.
    try testing.expect(!P.at(100, true, false, false));
    try testing.expect(!P.at(149, true, false, false));
    try testing.expect(P.at(150, true, false, false));
    try testing.expect(!P.at(500, false, false, false));
    // Forced (resize, overlay toggle, step): always, even mid-period.
    try testing.expect(P.at(0, false, false, true));
}

test "a core that can't keep up is still presented" {
    // Behind for good: on_schedule never comes back. Presents still come,
    // one every two periods, not one per re-base.
    const period: i96 = 16 * ms;
    var next: i96 = period;
    var n: usize = 0;
    var now: i96 = 0;
    while (now < 1000 * ms) : (now += ms) {
        if (shouldPresent(.{ .now = now, .next_present_ns = next, .period_ns = period, .new_frame = true, .on_schedule = false, .forced = false })) {
            n += 1;
            next = nextPresent(next, now, period);
        }
    }
    try testing.expect(n >= 28 and n <= 32);
}

test "present deadlines don't drift or burst" {
    const p: i96 = 16 * ms;
    // Presented a little late: the next deadline stays on the grid.
    try testing.expectEqual(32 * ms, nextPresent(16 * ms, 17 * ms, p));
    // A long gap (paused): restart from now instead of a burst.
    try testing.expectEqual(1000 * ms + p, nextPresent(16 * ms, 1000 * ms, p));
}

/// A viewer over the ASCII backend writing to a buffer, with a fake clock.
const Harness = struct {
    out: std.ArrayList(u8) = .empty,
    snap: std.ArrayList(u8) = .empty,
    t: i96 = 0,
    /// Added to `t` after every read, so timed work takes time.
    tick: i96 = 0,
    stats: Stats = .init(0),

    fn write(ctx: ?*anyopaque, bytes: []const u8) error{WriteFailed}!void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        h.out.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
    }

    fn read(ctx: ?*anyopaque) i96 {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        defer h.t += h.tick;
        return h.t;
    }

    fn viewer(h: *Harness, overlay_on: bool) !Viewer {
        return .init(testing.allocator, testing.io, .{
            .backend = .ascii,
            .ascii_color = .truecolor,
            .cell_px = .{ .w = 10, .h = 20 },
        }, .{ .ctx = h, .nowFn = read }, .{ .ctx = h, .writeFn = write }, .{
            .present_fps = 60,
            .overlay = overlay_on,
            .window = .{ .cols = 40, .rows = 12, .px_w = 0, .px_h = 0 },
        });
    }

    /// What was written since the last call. Copied, since clearing `out`
    /// poisons its old bytes in debug builds.
    fn take(h: *Harness) []u8 {
        h.snap.clearRetainingCapacity();
        h.snap.appendSlice(testing.allocator, h.out.items) catch @panic("OOM");
        h.out.clearRetainingCapacity();
        return h.snap.items;
    }

    fn deinit(h: *Harness) void {
        h.out.deinit(testing.allocator);
        h.snap.deinit(testing.allocator);
    }
};

const test_rgb: [8 * 6 * 3]u8 = @splat(128);

fn testSource(seq: u64) Source {
    return .{
        .frame = .{ .width = 8, .height = 6, .rgb = &test_rgb },
        .seq = seq,
        .aspect = null,
        .on_schedule = true,
        .status = .{ .rates = .{ .emulated_fps = 60, .presented_fps = 60 }, .speed = .normal, .paused = false, .rebases = 0 },
    };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "the first update presents; an unchanged frame is not re-sent" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    try v.update(testSource(1), &h.stats, 0);
    try testing.expect(h.take().len > 0);
    try testing.expectEqual(1, h.stats.totals.presented);
    // Same frame, past the deadline: nothing.
    try v.update(testSource(1), &h.stats, 100 * ms);
    try testing.expectEqual(0, h.take().len);
    // New frame within the period: wait for the deadline.
    try v.update(testSource(2), &h.stats, 5 * ms);
    try testing.expectEqual(0, h.take().len);
    try testing.expectEqual(@as(?i96, v.next_present_ns), v.nextDeadline(2, 5 * ms));
    try v.update(testSource(2), &h.stats, 17 * ms);
    try testing.expectEqual(2, h.stats.totals.presented);
    // Every byte written is counted.
    try testing.expect(h.stats.totals.bytes > 0);
}

test "overlay: drawn over the box, toggled off without stale cells" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(true);
    defer v.deinit(&h.stats);
    try v.update(testSource(1), &h.stats, 0);
    const first = h.take();
    try testing.expect(contains(first, "emu 60.0"));
    try testing.expect(contains(first, "\x1b[0;38;5;252;48;5;236m"));
    const cover = v.drawn.?;
    try testing.expectEqual(1, cover.rows);
    try testing.expect(cover.cols > 0);

    // Refreshes on its own period, without a new frame.
    try v.update(testSource(1), &h.stats, overlay_period_ns);
    const refresh = h.take();
    try testing.expect(contains(refresh, "emu 60.0"));
    try testing.expectEqual(1, h.stats.totals.presented);

    // Off: the covered cells are erased and repainted by a present.
    v.toggleOverlay();
    try v.update(testSource(1), &h.stats, overlay_period_ns + 1);
    const off = h.take();
    try testing.expect(!contains(off, "emu "));
    try testing.expect(contains(off, "\x1b[0m"));
    try testing.expectEqual(null, v.drawn);
    try testing.expectEqual(2, h.stats.totals.presented);
}

test "resize clears and repaints into the new window; too small draws nothing" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(true);
    defer v.deinit(&h.stats);
    try v.update(testSource(1), &h.stats, 0);
    _ = h.take();

    try v.resize(.{ .cols = 0, .rows = 0, .px_w = 0, .px_h = 0 }, &h.stats);
    try testing.expect(contains(h.take(), "\x1b[2J"));
    try v.update(testSource(1), &h.stats, 1);
    _ = h.take();
    try testing.expectEqual(null, v.drawn);
    // Nothing drawn, so nothing counted as presented.
    try testing.expectEqual(1, h.stats.totals.presented);

    try v.resize(.{ .cols = 30, .rows = 10, .px_w = 300, .px_h = 200 }, &h.stats);
    _ = h.take();
    try testing.expectEqual(caps.CellPx{ .w = 10, .h = 20 }, v.cell_px);
    try v.update(testSource(1), &h.stats, 2);
    try testing.expect(contains(h.take(), "emu "));
    try testing.expect(v.drawn != null);
    try testing.expectEqual(2, h.stats.totals.presented);
}

test "overlay text is cut to the box width" {
    try testing.expectEqualStrings("emu", truncate("emu 60.0", 3));
    try testing.expectEqualStrings("1×", truncate("1× · x", 2));
    try testing.expectEqualStrings("ab", truncate("ab", 10));
}

test "a present records its encode time and its whole cost" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    h.tick = ms;
    try testing.expectEqual(@as(i96, 0), v.present_cost_ns);

    try v.update(testSource(1), &h.stats, h.t);
    // Clock reads: before encoding, after it, before and after the write,
    // and the cost; each read moves it on by 1 ms.
    try testing.expectEqual(@as(u64, 1 * ms), h.stats.totals.encode_ns);
    try testing.expectEqual(@as(u64, 1 * ms), h.stats.totals.write_ns);
    try testing.expectEqual(@as(i96, 4 * ms), v.present_cost_ns);

    // Nothing to present: the cost of the last present is kept.
    _ = h.take();
    try v.update(testSource(1), &h.stats, h.t);
    try testing.expectEqualStrings("", h.take());
    try testing.expectEqual(@as(i96, 4 * ms), v.present_cost_ns);
}
