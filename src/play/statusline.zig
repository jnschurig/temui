//! The status line on the window's bottom row (D13), lualine-style: a left,
//! a center and a right segment, each built from a list of components so
//! item 10's config can rearrange them.
//!
//!   ` TUI  LEGACY  Space: menu      Super Metroid · Snes9x 1.63      60.0 fps · 1× `
//!
//! On a narrow window the center is cut first, then the right; the left is
//! cut only by the window's edge. Drawing it is the viewer's job; this only
//! builds the row, padded to exactly the window's width, and says which
//! bytes of it are an alert (`GAME MODE DISABLED`, drawn white on red).

const std = @import("std");
const Modes = @import("Modes.zig");
const overlay = @import("overlay.zig");
const text = @import("text.zig");

pub const Component = enum {
    /// `GAME` or `TUI`.
    mode,
    /// `LEGACY` on the fixed-hold path, or `GAME MODE DISABLED` (an alert)
    /// with game input disabled.
    flags,
    /// A box's text when the window is too small for the box; else
    /// `Space: menu` in TUI mode.
    hint,
    /// The ROM and core, e.g. `Super Metroid · Snes9x 1.63`; hidden while
    /// the detailed stats are on.
    game,
    /// Item 05's overlay minus emulated fps and speed; only while on.
    detailed_stats,
    /// `60.0 fps · 1×`, `paused`.
    basic_stats,
};

pub const Layout = struct {
    left: []const Component,
    center: []const Component,
    right: []const Component,
};

pub const default_layout: Layout = .{
    .left = &.{ .mode, .flags, .hint },
    .center = &.{ .game, .detailed_stats },
    .right = &.{.basic_stats},
};

pub const State = struct {
    mode: Modes.Mode,
    flag: Modes.Flag = .none,
    /// A box that didn't fit; its lines are joined with spaces.
    message: []const []const u8 = &.{},
    game: []const u8 = "",
    detailed: bool = false,
    stats: overlay.State,
};

/// Wider windows get a line this wide; the rest of the row is left alone.
pub const max_cols = 1024;
const seg_cap = 512;
/// Large enough for any line `format` builds.
pub const max_len = 3 * seg_cap + max_cols;

const component_sep = "  ";

/// Byte offsets, `start` inclusive and `end` exclusive.
pub const Range = struct { start: usize, end: usize };

pub const Row = struct {
    text: []const u8,
    /// The bytes of `text` to draw as an alert, if any show.
    alert: ?Range = null,
};

/// Builds the row in `buf`: exactly `@min(cols, max_cols)` cells.
pub fn format(buf: *[max_len]u8, st: State, layout: Layout, cols: u32) Row {
    var segs: [3][seg_cap]u8 = undefined;
    const left = segment(&segs[0], st, layout.left);
    const center = segment(&segs[1], st, layout.center);
    const right = segment(&segs[2], st, layout.right);

    var w: std.Io.Writer = .fixed(buf);
    var alert: ?Range = null;
    compose(&w, left, center, right, @min(cols, max_cols), &alert) catch unreachable; // max_len fits
    return .{ .text = w.buffered(), .alert = alert };
}

const Segment = struct {
    text: []const u8,
    /// Within `text`.
    alert: ?Range = null,
};

/// The segment's components that show, joined and cleaned.
fn segment(buf: *[seg_cap]u8, st: State, list: []const Component) Segment {
    var w: std.Io.Writer = .fixed(buf);
    var alert: ?Range = null;
    for (list) |c| {
        var tmp: [seg_cap]u8 = undefined;
        var tw: std.Io.Writer = .fixed(&tmp);
        // A component longer than the segment is cut, not an error.
        writeComponent(&tw, st, c) catch {};
        if (tw.end == 0) continue;
        if (w.end > 0) _ = text.writeCleanFit(&w, component_sep, seg_cap);
        const start = w.end;
        _ = text.writeCleanFit(&w, tw.buffered(), seg_cap);
        if (c == .flags and st.flag == .game_disabled and w.end > start) alert = .{ .start = start, .end = w.end };
    }
    return .{ .text = w.buffered(), .alert = alert };
}

fn writeComponent(w: *std.Io.Writer, st: State, c: Component) std.Io.Writer.Error!void {
    switch (c) {
        .mode => try w.writeAll(switch (st.mode) {
            .game => "GAME",
            .tui => "TUI",
        }),
        .flags => try w.writeAll(switch (st.flag) {
            .none => "",
            .legacy => "LEGACY",
            .game_disabled => "GAME MODE DISABLED",
        }),
        .hint => if (st.message.len > 0) {
            var first = true;
            for (st.message) |line| {
                if (line.len == 0) continue;
                if (!first) try w.writeByte(' ');
                try w.writeAll(line);
                first = false;
            }
        } else if (st.mode == .tui) try w.writeAll("Space: menu"),
        .game => if (!st.detailed) try w.writeAll(st.game),
        .detailed_stats => if (st.detailed) try overlay.writeDetailed(w, st.stats),
        .basic_stats => try overlay.writeBasic(w, st.stats),
    }
}

/// ` L  ..  C  ..  R `: one space at each edge and at least two between
/// segments. `cols` cells exactly.
fn compose(w: *std.Io.Writer, left: Segment, center: Segment, right: Segment, cols: u32, alert: *?Range) !void {
    if (cols == 0) return;
    var at: usize = 0;
    try w.writeByte(' ');
    at += 1;
    at += try put(w, left, cols - at, alert);
    if (at >= cols) return;

    const gap = 2;
    const rest = cols - at;
    // The right segment keeps all it can (gap before, edge space after).
    const r_w = text.width(right.text);
    const r_cells: usize = if (r_w > 0 and rest > gap + 1) @min(r_w, rest - gap - 1) else 0;
    const r_total: usize = if (r_cells > 0) gap + r_cells + 1 else 0;
    // The center gets what's left: a gap before it and, with no right
    // segment after it, the edge space.
    const after: usize = if (r_cells > 0) 0 else 1;
    const c_room = rest - r_total;
    const c_w = text.width(center.text);
    const c_cells: usize = if (c_w > 0 and c_room > gap + after) @min(c_w, c_room - gap - after) else 0;

    if (c_cells > 0) {
        // Centered on the whole row where possible.
        const ideal = (cols - c_cells) / 2;
        const lo = at + gap;
        const hi = cols - r_total - after - c_cells;
        try pad(w, &at, std.math.clamp(ideal, lo, hi));
        at += try put(w, center, c_cells, alert);
    }
    if (r_cells > 0) {
        try pad(w, &at, cols - r_total + gap);
        at += try put(w, right, r_cells, alert);
    }
    try pad(w, &at, cols);
}

/// Writes `seg` cut to `max_cells`, and moves its alert, or what is left
/// of it, into the row's byte offsets. Returns the cells written.
fn put(w: *std.Io.Writer, seg: Segment, max_cells: usize, alert: *?Range) !usize {
    const base = w.end;
    const cells = try text.writeClean(w, seg.text, max_cells);
    if (seg.alert) |a| {
        const end = @min(base + a.end, w.end);
        if (base + a.start < end) alert.* = .{ .start = base + a.start, .end = end };
    }
    return cells;
}

fn pad(w: *std.Io.Writer, at: *usize, to: usize) !void {
    while (at.* < to) : (at.* += 1) try w.writeByte(' ');
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const steady: overlay.State = .{
    .rates = .{
        .emulated_fps = 60,
        .presented_fps = 59.96,
        .bytes_per_s = 2_100_000,
        .encode_ns_per_s = 1_200_000,
        .write_ns_per_s = 3_000_000,
    },
    .speed = .normal,
    .paused = false,
    .rebases = 0,
};

const game = "Super Metroid · Snes9x 1.63";

fn expectRow(want: []const u8, st: State, cols: u32) !void {
    var buf: [max_len]u8 = undefined;
    const got = format(&buf, st, default_layout, cols);
    try testing.expectEqualStrings(want, got.text);
    try testing.expectEqual(@min(cols, max_cols), text.width(got.text));
    if (st.flag != .game_disabled) try testing.expectEqual(@as(?Range, null), got.alert);
}

fn alertText(row: Row) ?[]const u8 {
    const a = row.alert orelse return null;
    return row.text[a.start..a.end];
}

test "game mode, wide" {
    try expectRow(
        " GAME                      Super Metroid · Snes9x 1.63              60.0 fps · 1× ",
        .{ .mode = .game, .game = game, .stats = steady },
        82,
    );
}

test "TUI mode with the legacy flag and the hint" {
    try expectRow(
        " TUI  LEGACY  Space: menu  Super Metroid · Snes9x 1.63              60.0 fps · 1× ",
        .{ .mode = .tui, .flag = .legacy, .game = game, .stats = steady },
        82,
    );
}

test "detailed stats replace the game" {
    var st: State = .{ .mode = .game, .game = game, .detailed = true, .stats = steady };
    st.stats.rebases = 3;
    try expectRow(
        " GAME        pres 60.0 · 2.1 MB/s · enc 1.2 ms/s · wr 3.0 ms/s · lag 3  60.0 fps · 1× ",
        st,
        86,
    );
}

test "paused and max on the right" {
    var st: State = .{ .mode = .game, .stats = steady };
    st.stats.paused = true;
    try expectRow(" GAME                       paused ", st, 35);
    st.stats.paused = false;
    st.stats.speed = .max;
    try expectRow(" GAME              60.0 fps · max ", st, 34);
}

test "truncation: the center goes first, then the right, never the left" {
    const st: State = .{ .mode = .tui, .flag = .legacy, .game = game, .stats = steady };
    // Room for everything but part of the center.
    try expectRow(" TUI  LEGACY  Space: menu  Super Metr  60.0 fps · 1× ", st, 53);
    // No room for the center: the right starts losing cells.
    try expectRow(" TUI  LEGACY  Space: menu  60.0 fps · 1× ", st, 41);
    try expectRow(" TUI  LEGACY  Space: menu  60.0 f ", st, 34);
    // Only the left.
    try expectRow(" TUI  LEGACY  Space: menu   ", st, 28);
    try expectRow(" TUI  LEGACY  Space: menu ", st, 26);
    // The window's edge cuts the left.
    try expectRow(" TUI  LEGACY  Spa", st, 17);
    try expectRow(" ", st, 1);
    try expectRow("", st, 0);
}

test "a box's text replaces the hint" {
    const lines = [_][]const u8{ "Quit?", "", "Enter to confirm" };
    try expectRow(
        " TUI  Quit? Enter to confirm   60.0 fps · 1× ",
        .{ .mode = .tui, .message = &lines, .game = game, .stats = steady },
        45,
    );
}

test "the game name is cleaned and wide characters count two cells" {
    try expectRow(
        " GAME  ドラ?[2J  60.0 fps · 1× ",
        .{ .mode = .game, .game = "ドラ\x1b[2J", .stats = steady },
        31,
    );
}

test "a custom layout" {
    var buf: [max_len]u8 = undefined;
    const layout: Layout = .{ .left = &.{.basic_stats}, .center = &.{}, .right = &.{ .flags, .mode } };
    const got = format(&buf, .{ .mode = .game, .flag = .legacy, .stats = steady }, layout, 40);
    try testing.expectEqualStrings(" 60.0 fps · 1×             LEGACY  GAME ", got.text);
}

test "very wide windows are capped" {
    var buf: [max_len]u8 = undefined;
    const got = format(&buf, .{ .mode = .game, .game = game, .stats = steady }, default_layout, 5000);
    try testing.expectEqual(max_cols, text.width(got.text));
}

test "game input disabled: the flag and its alert range" {
    const st: State = .{ .mode = .tui, .flag = .game_disabled, .game = game, .stats = steady };
    var buf: [max_len]u8 = undefined;
    var row = format(&buf, st, default_layout, 80);
    try testing.expect(std.mem.startsWith(u8, row.text, " TUI  GAME MODE DISABLED  Space: menu  Super Metroid"));
    try testing.expectEqualStrings("GAME MODE DISABLED", alertText(row).?);
    try testing.expectEqual(@as(?Range, .{ .start = 6, .end = 24 }), row.alert);
    // Narrow: the center and right go; the left, alert included, stays.
    row = format(&buf, st, default_layout, 40);
    try testing.expectEqualStrings(" TUI  GAME MODE DISABLED  Space: menu   ", row.text);
    try testing.expectEqualStrings("GAME MODE DISABLED", alertText(row).?);
    // The window's edge cuts the alert too.
    row = format(&buf, st, default_layout, 15);
    try testing.expectEqualStrings(" TUI  GAME MODE", row.text);
    try testing.expectEqualStrings("GAME MODE", alertText(row).?);
    row = format(&buf, st, default_layout, 5);
    try testing.expectEqual(@as(?Range, null), row.alert);
    // In another segment, after other text.
    const layout: Layout = .{ .left = &.{.basic_stats}, .center = &.{}, .right = &.{ .mode, .flags } };
    row = format(&buf, st, layout, 50);
    try testing.expectEqualStrings("GAME MODE DISABLED", alertText(row).?);
    try testing.expect(std.mem.endsWith(u8, row.text, "TUI  GAME MODE DISABLED "));
}
