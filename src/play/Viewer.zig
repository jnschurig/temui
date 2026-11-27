//! The play loop's viewer (D5, D7, D8, D13): draws the engine's latest
//! frame through the `Renderer`, at most `present_fps` times a second, in
//! the window minus its bottom row, which holds the status line. Over the
//! image it draws the layers `Modes` asks for: the leader menu (anchored at
//! the bottom of the image box) and then the centered box. It knows nothing
//! of the libretro host: the loop hands it a `Source` each iteration.
//!
//! Everything for one update goes into one buffer and reaches the terminal
//! in one write, which is timed and counted in `Stats` (bytes and write
//! time), so a slow terminal shows up in the stats.

const std = @import("std");
const caps = @import("../term/caps.zig");
const Renderer = @import("../render/Renderer.zig");
const sgr = @import("../render/sgr.zig");
const Engine = @import("Engine.zig");
const Modes = @import("Modes.zig");
const Stats = @import("Stats.zig");
const boxes = @import("boxes.zig");
const overlay = @import("overlay.zig");
const statusline = @import("statusline.zig");

const Viewer = @This();

const Rect = Renderer.Rect;
const log = std.log.scoped(.play);

/// The status line's text is checked at most this often (and at once when
/// the layers change).
pub const status_period_ns: i96 = 250 * std.time.ns_per_ms;

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
    /// Start with the detailed stats in the status line.
    detailed_stats: bool = false,
    /// The window, in cells.
    window: caps.WinSize,
};

/// What the viewer reads from the engine and `Modes` each update.
pub const Source = struct {
    frame: Renderer.Frame,
    /// Increments for every frame the engine runs.
    seq: u64,
    /// The core's display aspect, or null for the frame's own.
    aspect: ?f32,
    /// The engine ran everything due in its last tick (not catching up).
    on_schedule: bool,
    /// For the stats in the status line.
    status: overlay.State,
    /// The mode and the layers to draw.
    view: Modes.View,
    /// The status line's game information, e.g. `Super Metroid · Snes9x 1.63`.
    game: []const u8 = "",
};

/// One box on screen: where, and what it says. The lines are static
/// (`Modes`' texts, or the viewer's menu lines), so comparing slices tells
/// whether the content changed.
const Layer = struct {
    rect: Rect,
    lines: []const []const u8,

    fn eql(a: ?Layer, b: ?Layer) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return rectEql(x.rect, y.rect) and x.lines.ptr == y.lines.ptr and x.lines.len == y.lines.len;
    }
};

const Layers = struct {
    menu: ?Layer = null,
    box: ?Layer = null,
    /// A box with no room to be drawn: its text goes on the status line.
    overflow: []const []const u8 = &.{},

    fn eql(a: Layers, b: Layers) bool {
        return Layer.eql(a.menu, b.menu) and Layer.eql(a.box, b.box) and
            a.overflow.ptr == b.overflow.ptr and a.overflow.len == b.overflow.len;
    }

    /// The rects the renderer keeps clear, bottom layer first.
    fn rects(l: *const Layers, buf: *[2]Rect) []const Rect {
        var n: usize = 0;
        if (l.menu) |m| {
            buf[n] = m.rect;
            n += 1;
        }
        if (l.box) |b| {
            buf[n] = b.rect;
            n += 1;
        }
        return buf[0..n];
    }
};

const menu_line_len = 48;

renderer: Renderer,
clock: Engine.Clock,
output: Output,
/// Box and status colours: reverse video where the terminal may lack 256
/// colours.
basic_color: bool,
/// The image's part of the window.
rect: Rect,
/// The status line's row, or null when the window is under 2 rows.
status_row: ?u32,
window_cols: u32,
cell_px: caps.CellPx,
period_ns: i96,
next_present_ns: i96,
/// `Source.seq` at the last present.
presented_seq: u64 = 0,
/// Present on the next update whatever the rate (resize, step).
force: bool = true,
detailed_stats: bool,
status_buf: [statusline.max_len]u8 = undefined,
status_len: usize = 0,
/// Nothing drawn yet (or the screen was cleared): draw even if unchanged.
status_stale: bool = true,
next_status_ns: i96 = 0,
/// The layers on screen; null after a clear, so they're drawn again.
drawn: ?Layers = null,
menu_text: [Modes.menu_items.len][menu_line_len]u8 = undefined,
menu_lines: [Modes.menu_items.len][]const u8,
/// What the last present cost: encoding plus writing (0 before the first).
present_cost_ns: i96 = 0,
buf: std.Io.Writer.Allocating,

pub fn init(gpa: std.mem.Allocator, io: std.Io, choice: caps.Choice, clock: Engine.Clock, output: Output, cfg: Config) !Viewer {
    std.debug.assert(cfg.present_fps > 0);
    var v: Viewer = .{
        .renderer = try .init(gpa, io, choice, .{}),
        .clock = clock,
        .output = output,
        .basic_color = choice.backend == .ascii and choice.ascii_color == .none,
        .rect = undefined,
        .status_row = undefined,
        .window_cols = undefined,
        .cell_px = choice.cell_px,
        .period_ns = @intFromFloat(@max(1, @round(std.time.ns_per_s / cfg.present_fps))),
        .next_present_ns = clock.now(),
        .detailed_stats = cfg.detailed_stats,
        .menu_lines = undefined,
        .buf = .init(gpa),
    };
    v.setWindow(cfg.window);
    return v;
}

/// The menu's lines, `p  pause / resume`. Done once `v` is at its final
/// address, since the slices point into it.
fn menuLines(v: *Viewer) []const []const u8 {
    for (&Modes.menu_items, 0..) |item, i| {
        v.menu_lines[i] = std.fmt.bufPrint(&v.menu_text[i], "{c}  {s}", .{ item.key, item.label }) catch unreachable; // labels are short
    }
    return &v.menu_lines;
}

/// Removes what was drawn (kitty images, the frame's cells, the boxes and
/// the status line), then frees memory. Call before the session is restored.
pub fn deinit(v: *Viewer, stats: *Stats) void {
    v.buf.clearRetainingCapacity();
    const w = &v.buf.writer;
    blk: {
        if (v.drawn) |d| {
            var tmp: [2]Rect = undefined;
            for (d.rects(&tmp)) |r| sgr.clearRect(w, r) catch break :blk;
        }
        if (v.status_row) |row| if (!v.status_stale)
            sgr.clearRect(w, .{ .col = 1, .row = row, .cols = v.window_cols, .rows = 1 }) catch break :blk;
        v.renderer.clear(w) catch break :blk;
        v.flush(stats) catch |err| log.warn("final clear failed: {t}", .{err});
    }
    v.renderer.deinit();
    v.buf.deinit();
    v.* = undefined;
}

/// The image gets the window minus its bottom row, which the status line
/// keeps for good, so nothing ever refits the image. Below 2 rows there is
/// no status line.
fn setWindow(v: *Viewer, ws: caps.WinSize) void {
    v.window_cols = ws.cols;
    if (ws.rows >= 2) {
        v.rect = .{ .col = 1, .row = 1, .cols = ws.cols, .rows = ws.rows - 1 };
        v.status_row = ws.rows;
    } else {
        v.rect = .{ .col = 1, .row = 1, .cols = ws.cols, .rows = ws.rows };
        v.status_row = null;
    }
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
    if (v.status_row != null) d = if (d) |x| @min(x, v.next_status_ns) else v.next_status_ns;
    return d;
}

/// Repaints everything on the next update (e.g. after a step).
pub fn forcePresent(v: *Viewer) void {
    v.force = true;
}

/// Shows or hides the detailed stats in the status line.
pub fn toggleStats(v: *Viewer) void {
    v.detailed_stats = !v.detailed_stats;
    v.next_status_ns = 0;
}

/// Refreshes the status line on the next update (the speed, pause state
/// or layers changed).
pub fn statusChanged(v: *Viewer) void {
    v.next_status_ns = 0;
}

pub fn statsShown(v: *const Viewer) bool {
    return v.detailed_stats;
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
        v.setWindow(s);
        if (s.cols > 0 and s.rows > 0 and s.px_w >= s.cols and s.px_h >= s.rows)
            v.cell_px = .{ .w = s.px_w / s.cols, .h = s.px_h / s.rows };
        log.debug("resized to {d}x{d} cells, cell {d}x{d} px", .{ s.cols, s.rows, v.cell_px.w, v.cell_px.h });
    }
    v.renderer.resize(v.cell_px);
    v.drawn = null;
    v.status_stale = true;
    v.next_status_ns = 0;
    v.force = true;
    try v.flush(stats);
}

/// Where the layers go over `image` (the fitted image box).
fn place(v: *Viewer, view: Modes.View, image: Rect) Layers {
    var l: Layers = .{};
    if (view.menu != null) {
        const lines = v.menuLines();
        if (boxes.layout(lines, .bottom, image)) |r| l.menu = .{ .rect = r, .lines = lines };
    }
    if (view.box) |b| {
        if (boxes.layout(b.lines, .center, image)) |r| l.box = .{ .rect = r, .lines = b.lines } else l.overflow = b.lines;
    }
    return l;
}

/// Presents, redraws the layers and refreshes the status line, each when
/// due. Writes nothing when none is.
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
    const image = v.renderer.fitted(src.frame, v.rect, src.aspect);
    const want = v.place(src.view, image);
    const layers_changed = if (v.drawn) |d| !d.eql(want) else true;
    const status_due = v.status_row != null and (layers_changed or v.status_stale or now >= v.next_status_ns);
    if (!present and !layers_changed and !status_due) return;

    v.buf.clearRetainingCapacity();
    const w = &v.buf.writer;
    var want_buf: [2]Rect = undefined;
    const want_rects = want.rects(&want_buf);
    if (layers_changed) if (v.drawn) |d| {
        var old_buf: [2]Rect = undefined;
        const old_rects = d.rects(&old_buf);
        if (!rectsEql(old_rects, want_rects)) {
            if (v.renderer.backend() == .kitty) {
                // The image shows through blank cells; the boxes still
                // open are drawn again below.
                for (old_rects) |r| try sgr.clearRect(w, r);
            } else {
                // The renderer repaints the cells no longer covered (and
                // learns the new ones) on a present.
                present = true;
            }
        }
    };

    const t0 = v.clock.now();
    if (present) {
        try v.renderer.present(w, src.frame, v.rect, .{ .aspect = src.aspect, .occlude = want_rects });
        // A window too small for the picture draws nothing: not a present.
        if (!image.isEmpty()) {
            const t1 = v.clock.now();
            stats.encoded(t1, @intCast(@max(t1 - t0, 0)));
            stats.presented(now);
        }
        v.presented_seq = src.seq;
        v.next_present_ns = nextPresent(v.next_present_ns, now, v.period_ns);
        v.force = false;
    }
    if (layers_changed) {
        if (want.menu) |m| try boxes.draw(w, m.rect, m.lines, v.basic_color);
        if (want.box) |b| try boxes.draw(w, b.rect, b.lines, v.basic_color);
        if (want.menu != null or want.box != null)
            log.debug("layers: menu {any}, box {any}", .{ want.menu != null, want.box != null });
    }
    v.drawn = want;
    if (status_due) try v.drawStatus(w, src, want.overflow, now);
    try v.flush(stats);
    if (present) v.present_cost_ns = @max(v.clock.now() - t0, 0);
}

/// Rewrites the status line when its text changed.
fn drawStatus(v: *Viewer, w: *std.Io.Writer, src: Source, overflow: []const []const u8, now: i96) !void {
    const row = v.status_row.?;
    v.next_status_ns = now + status_period_ns;
    var tmp: [statusline.max_len]u8 = undefined;
    const row_text = statusline.format(&tmp, .{
        .mode = src.view.mode,
        .flag = src.view.flag,
        .message = overflow,
        .game = src.game,
        .detailed = v.detailed_stats,
        .stats = src.status,
    }, statusline.default_layout, v.window_cols);
    const line = row_text.text;
    // The alert's place follows from the text, so comparing the text is
    // enough.
    if (!v.status_stale and std.mem.eql(u8, line, v.status_buf[0..v.status_len])) return;
    @memcpy(v.status_buf[0..line.len], line);
    v.status_len = line.len;
    v.status_stale = false;
    try sgr.cup(w, row, 1);
    const style = boxes.style(v.basic_color);
    try w.writeAll(style);
    if (row_text.alert) |a| {
        try w.writeAll(line[0..a.start]);
        try w.writeAll(sgr.reset ++ alert_style);
        try w.writeAll(line[a.start..a.end]);
        try w.writeAll(sgr.reset);
        try w.writeAll(style);
        try w.writeAll(line[a.end..]);
    } else try w.writeAll(line);
    try w.writeAll(sgr.reset);
}

/// White on red, from the basic 16 colours, so every terminal shows it.
pub const alert_style = "\x1b[97;41m";

fn rectEql(a: Rect, b: Rect) bool {
    return a.col == b.col and a.row == b.row and a.cols == b.cols and a.rows == b.rows;
}

fn rectsEql(a: []const Rect, b: []const Rect) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!rectEql(x, y)) return false;
    return true;
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

const TestScreen = @import("TestScreen.zig");

/// A viewer over the ASCII backend writing to a buffer and a screen model,
/// with a fake clock.
const Harness = struct {
    out: std.ArrayList(u8) = .empty,
    snap: std.ArrayList(u8) = .empty,
    screen: TestScreen = .init(80, 24),
    /// The window's width, for `row`.
    cols: u32 = 40,
    t: i96 = 0,
    /// Added to `t` after every read, so timed work takes time.
    tick: i96 = 0,
    stats: Stats = .init(0),

    fn write(ctx: ?*anyopaque, bytes: []const u8) error{WriteFailed}!void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        h.out.appendSlice(testing.allocator, bytes) catch return error.WriteFailed;
        h.screen.feed(bytes) catch return error.WriteFailed;
    }

    fn read(ctx: ?*anyopaque) i96 {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        defer h.t += h.tick;
        return h.t;
    }

    fn viewer(h: *Harness, detailed: bool) !Viewer {
        return h.viewerSized(detailed, 40, 12);
    }

    fn viewerSized(h: *Harness, detailed: bool, cols: u16, rows: u16) !Viewer {
        h.cols = cols;
        return .init(testing.allocator, testing.io, .{
            .backend = .ascii,
            .ascii_color = .truecolor,
            .cell_px = .{ .w = 10, .h = 20 },
        }, .{ .ctx = h, .nowFn = read }, .{ .ctx = h, .writeFn = write }, .{
            .present_fps = 60,
            .detailed_stats = detailed,
            .window = .{ .cols = cols, .rows = rows, .px_w = 0, .px_h = 0 },
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

    /// Screen row `r` as text, the window's width of it.
    fn row(h: *const Harness, buf: []u8, r: u32) []const u8 {
        const line = h.screen.line(buf, r);
        var it: std.unicode.Utf8Iterator = .{ .bytes = line, .i = 0 };
        for (0..h.cols) |_| _ = it.nextCodepointSlice();
        return line[0..it.i];
    }

    fn deinit(h: *Harness) void {
        h.out.deinit(testing.allocator);
        h.snap.deinit(testing.allocator);
    }
};

const test_rgb: [8 * 6 * 3]u8 = @splat(128);
const test_rgb2: [8 * 6 * 3]u8 = @splat(30);

const game_view: Modes.View = .{ .mode = .game, .menu = null, .box = null };
const menu_view: Modes.View = .{ .mode = .tui, .menu = &Modes.menu_items, .box = null };
const tui_view: Modes.View = .{ .mode = .tui, .menu = null, .box = null };
const quit_box: Modes.Box = .{ .lines = &Modes.quit_prompt_text, .modal = true };

fn testSource(seq: u64) Source {
    return viewSource(seq, game_view);
}

fn viewSource(seq: u64, view: Modes.View) Source {
    return .{
        .frame = .{ .width = 8, .height = 6, .rgb = if (seq >= 2) &test_rgb2 else &test_rgb },
        .seq = seq,
        .aspect = null,
        .on_schedule = true,
        .status = .{ .rates = .{ .emulated_fps = 60, .presented_fps = 60 }, .speed = .normal, .paused = false, .rebases = 0 },
        .view = view,
        .game = "Test · core 1",
    };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// The two screens agree on every cell of the top `cols`×`rows`.
fn expectSameScreen(want: *const TestScreen, got: *const TestScreen, cols: u32, rows: u32) !void {
    for (1..rows + 1) |r| for (1..cols + 1) |c| {
        const a = want.at(@intCast(r), @intCast(c));
        const b = got.at(@intCast(r), @intCast(c));
        if (a.cp != b.cp or a.bg != b.bg) {
            std.debug.print("cell {d},{d}: want '{u}' bg {any}, got '{u}' bg {any}\n", .{ r, c, a.cp, a.bg, b.cp, b.bg });
            return error.TestUnexpectedResult;
        }
    };
}

test "the first update presents; an unchanged frame is not re-sent" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    try v.update(testSource(1), &h.stats, 0);
    try testing.expect(h.take().len > 0);
    try testing.expectEqual(1, h.stats.totals.presented);
    // Same frame, past the deadline but before the status check: nothing.
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

test "the bottom row is the status line's" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    try v.update(testSource(1), &h.stats, 0);
    try testing.expectEqual(Rect{ .col = 1, .row = 1, .cols = 40, .rows = 11 }, v.rect);
    const image = v.renderer.fitted(testSource(1).frame, v.rect, null);
    try testing.expect(image.row + image.rows - 1 <= 11);
    var buf: [512]u8 = undefined;
    const status = h.row(&buf, 12);
    try testing.expect(std.mem.startsWith(u8, status, " GAME "));
    try testing.expect(contains(status, "Test · core 1"));
    try testing.expect(std.mem.endsWith(u8, status, " 60.0 fps · 1× "));
    try testing.expect(h.screen.at(12, 1).bg and h.screen.at(12, 40).bg);
    for (1..12) |r| try testing.expect(!contains(h.row(&buf, @intCast(r)), "GAME"));
}

test "game input disabled: the flag is drawn white on red, the rest as usual" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    try v.update(viewSource(1, .{ .mode = .tui, .flag = .game_disabled, .menu = null, .box = null }), &h.stats, 0);
    const out = h.take();
    const style = comptime boxes.style(false);
    try testing.expect(contains(out, style ++ " TUI  " ++ sgr.reset ++ alert_style ++ "GAME MODE DISABLED" ++ sgr.reset ++ style ++ "  Space: menu"));
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, h.row(&buf, 12), " TUI  GAME MODE DISABLED  Space: menu"));
}

test "the status line is rewritten only when its text changes" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    try v.update(testSource(1), &h.stats, 0);
    _ = h.take();
    try testing.expectEqual(@as(?i96, status_period_ns), v.nextDeadline(1, 1));

    // Due, but the same text: nothing written.
    try v.update(testSource(1), &h.stats, status_period_ns);
    try testing.expectEqual(0, h.take().len);

    // Changed: rewritten on the next check, with no present.
    var src = testSource(1);
    src.status.rates.emulated_fps = 59;
    try v.update(src, &h.stats, status_period_ns + 1);
    try testing.expectEqual(0, h.take().len);
    try v.update(src, &h.stats, 2 * status_period_ns);
    try testing.expect(contains(h.take(), "59.0 fps"));
    try testing.expectEqual(1, h.stats.totals.presented);

    // `statusChanged` checks at once.
    src.status.paused = true;
    v.statusChanged();
    try v.update(src, &h.stats, 2 * status_period_ns + 1);
    try testing.expect(contains(h.take(), "paused"));
}

test "detailed stats toggle in the status line" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(true);
    defer v.deinit(&h.stats);
    try v.update(testSource(1), &h.stats, 0);
    var buf: [512]u8 = undefined;
    try testing.expect(contains(h.row(&buf, 12), "pres 60.0"));
    try testing.expect(!contains(h.row(&buf, 12), "Test · core 1"));
    v.toggleStats();
    try testing.expect(!v.statsShown());
    try v.update(testSource(1), &h.stats, 1);
    try testing.expect(contains(h.row(&buf, 12), "Test · core 1"));
    try testing.expectEqual(1, h.stats.totals.presented);
}

test "the menu is drawn, then closed with its cells repainted" {
    var ref: Harness = .{};
    defer ref.deinit();
    var rv = try ref.viewer(false);
    defer rv.deinit(&ref.stats);
    try rv.update(viewSource(1, tui_view), &ref.stats, 0);

    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    try v.update(viewSource(1, tui_view), &h.stats, 0);
    try v.update(viewSource(1, menu_view), &h.stats, 1);
    const m = v.drawn.?.menu.?.rect;
    const image = v.renderer.fitted(testSource(1).frame, v.rect, null);
    // Anchored at the bottom of the image box.
    try testing.expectEqual(image.row + image.rows, m.row + m.rows);
    try testing.expectEqual('┌', h.screen.at(m.row, m.col).cp);
    var buf: [512]u8 = undefined;
    try testing.expect(contains(h.row(&buf, m.row + 1), "p  pause / resume"));
    try testing.expect(contains(h.row(&buf, m.row + 8), "q  quit"));

    try v.update(viewSource(1, tui_view), &h.stats, 2);
    try testing.expectEqual(null, v.drawn.?.menu);
    try expectSameScreen(&ref.screen, &h.screen, 40, 12);
}

test "a centered box over the menu; new frames keep clear of both" {
    var ref: Harness = .{};
    defer ref.deinit();
    var rv = try ref.viewer(false);
    defer rv.deinit(&ref.stats);
    try rv.update(viewSource(2, tui_view), &ref.stats, 0);

    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    var both = menu_view;
    both.box = quit_box;
    try v.update(viewSource(1, both), &h.stats, 0);
    const m = v.drawn.?.menu.?.rect;
    const b = v.drawn.?.box.?.rect;
    var buf: [512]u8 = undefined;
    try testing.expect(contains(h.row(&buf, b.row + 1), "│ Quit? Enter to confirm, a │"));

    // A new frame: the renderer leaves both boxes alone.
    try v.update(viewSource(2, both), &h.stats, 17 * ms);
    try testing.expectEqual(2, h.stats.totals.presented);
    try testing.expectEqual('┌', h.screen.at(m.row, m.col).cp);
    try testing.expectEqual('┐', h.screen.at(b.row, b.col + b.cols - 1).cp);
    try testing.expect(contains(h.row(&buf, b.row + 1), "Quit?"));
    try testing.expect(contains(h.row(&buf, m.row + m.rows - 2), "q  quit"));

    // The box closes: the menu shows whole again.
    try v.update(viewSource(2, menu_view), &h.stats, 18 * ms);
    for (m.row..m.row + m.rows) |r| try testing.expect(h.screen.at(@intCast(r), m.col).bg);
    try testing.expect(contains(h.row(&buf, m.row + 1), "p  pause / resume"));

    // Both close: no stale cells.
    try v.update(viewSource(2, tui_view), &h.stats, 19 * ms);
    try expectSameScreen(&ref.screen, &h.screen, 40, 12);
}

test "resize re-centers and redraws an open box" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    var view = game_view;
    view.box = .{ .lines = &Modes.ctrl_c_text, .modal = false };
    try v.update(viewSource(1, view), &h.stats, 0);

    try v.resize(.{ .cols = 70, .rows = 21, .px_w = 700, .px_h = 420 }, &h.stats);
    h.cols = 70;
    try v.update(viewSource(1, view), &h.stats, 1);
    const image = v.renderer.fitted(testSource(1).frame, v.rect, null);
    const want = boxes.layout(&Modes.ctrl_c_text, .center, image).?;
    try testing.expectEqual(want, v.drawn.?.box.?.rect);
    try testing.expectEqual('┌', h.screen.at(want.row, want.col).cp);
    var buf: [512]u8 = undefined;
    const text_row = h.row(&buf, want.row + 1);
    if (!contains(text_row, "Press Ctrl-C again to quit")) {
        std.debug.print("box {any}\nrow: {s}\n", .{ want, text_row });
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.startsWith(u8, h.row(&buf, 21), " GAME "));
}

test "a window too small for a box puts its text on the status line" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewerSized(false, 60, 4);
    defer v.deinit(&h.stats);
    var view = tui_view;
    view.box = quit_box;
    try v.update(viewSource(1, view), &h.stats, 0);
    // A 3-row window: the image box is too short for a box.
    try testing.expectEqual(null, v.drawn.?.box);
    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, h.row(&buf, 4), " TUI  Quit? Enter to confirm, any other key cancels"));
}

test "resize clears and repaints into the new window; too small draws nothing" {
    var h: Harness = .{};
    defer h.deinit();
    var v = try h.viewer(false);
    defer v.deinit(&h.stats);
    try v.update(testSource(1), &h.stats, 0);
    _ = h.take();

    try v.resize(.{ .cols = 0, .rows = 0, .px_w = 0, .px_h = 0 }, &h.stats);
    try testing.expect(contains(h.take(), "\x1b[2J"));
    try testing.expectEqual(null, v.status_row);
    try v.update(testSource(1), &h.stats, 1);
    _ = h.take();
    // Nothing drawn, so nothing counted as presented.
    try testing.expectEqual(1, h.stats.totals.presented);

    // One row: no status line, the image gets it.
    try v.resize(.{ .cols = 30, .rows = 1, .px_w = 0, .px_h = 0 }, &h.stats);
    try testing.expectEqual(null, v.status_row);
    try testing.expectEqual(1, v.rect.rows);

    try v.resize(.{ .cols = 30, .rows = 10, .px_w = 300, .px_h = 200 }, &h.stats);
    _ = h.take();
    try testing.expectEqual(caps.CellPx{ .w = 10, .h = 20 }, v.cell_px);
    try v.update(testSource(1), &h.stats, 2);
    try testing.expect(contains(h.take(), " GAME "));
    try testing.expectEqual(2, h.stats.totals.presented);
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
