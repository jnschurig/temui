//! The status line on the window's bottom row (D13), lualine-style: a left,
//! a center and a right segment, each built from a list of components so
//! item 10's config can rearrange them.
//!
//!   ` TUI  LEGACY  Space: menu      Super Metroid · Snes9x 1.63      60.0 fps · 1× `
//!
//! On a narrow window the center is cut first, then the right; the left is
//! cut only by the window's edge. Drawing it is the viewer's job; this only
//! builds the row, padded to exactly the window's width.

const std = @import("std");
const Modes = @import("Modes.zig");
const overlay = @import("overlay.zig");
const text = @import("text.zig");

pub const Component = enum {
    /// `GAME` or `TUI`.
    mode,
    /// `LEGACY` on the legacy input path.
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
    legacy: bool,
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

/// Builds the row in `buf`: exactly `@min(cols, max_cols)` cells.
pub fn format(buf: *[max_len]u8, st: State, layout: Layout, cols: u32) []const u8 {
    var segs: [3][seg_cap]u8 = undefined;
    const left = segment(&segs[0], st, layout.left);
    const center = segment(&segs[1], st, layout.center);
    const right = segment(&segs[2], st, layout.right);

    var w: std.Io.Writer = .fixed(buf);
    compose(&w, left, center, right, @min(cols, max_cols)) catch unreachable; // max_len fits
    return w.buffered();
}

/// The segment's components that show, joined and cleaned.
fn segment(buf: *[seg_cap]u8, st: State, list: []const Component) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (list) |c| {
        var tmp: [seg_cap]u8 = undefined;
        var tw: std.Io.Writer = .fixed(&tmp);
        // A component longer than the segment is cut, not an error.
        writeComponent(&tw, st, c) catch {};
        if (tw.end == 0) continue;
        if (w.end > 0) _ = text.writeCleanFit(&w, component_sep, seg_cap);
        _ = text.writeCleanFit(&w, tw.buffered(), seg_cap);
    }
    return w.buffered();
}

fn writeComponent(w: *std.Io.Writer, st: State, c: Component) std.Io.Writer.Error!void {
    switch (c) {
        .mode => try w.writeAll(switch (st.mode) {
            .game => "GAME",
            .tui => "TUI",
        }),
        .flags => if (st.legacy) try w.writeAll("LEGACY"),
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
fn compose(w: *std.Io.Writer, left: []const u8, center: []const u8, right: []const u8, cols: u32) !void {
    if (cols == 0) return;
    var at: usize = 0;
    try w.writeByte(' ');
    at += 1;
    at += try text.writeClean(w, left, cols - at);
    if (at >= cols) return;

    const gap = 2;
    const rest = cols - at;
    // The right segment keeps all it can (gap before, edge space after).
    const r_w = text.width(right);
    const r_cells: usize = if (r_w > 0 and rest > gap + 1) @min(r_w, rest - gap - 1) else 0;
    const r_total: usize = if (r_cells > 0) gap + r_cells + 1 else 0;
    // The center gets what's left: a gap before it and, with no right
    // segment after it, the edge space.
    const after: usize = if (r_cells > 0) 0 else 1;
    const c_room = rest - r_total;
    const c_w = text.width(center);
    const c_cells: usize = if (c_w > 0 and c_room > gap + after) @min(c_w, c_room - gap - after) else 0;

    if (c_cells > 0) {
        // Centered on the whole row where possible.
        const ideal = (cols - c_cells) / 2;
        const lo = at + gap;
        const hi = cols - r_total - after - c_cells;
        try pad(w, &at, std.math.clamp(ideal, lo, hi));
        at += try text.writeClean(w, center, c_cells);
    }
    if (r_cells > 0) {
        try pad(w, &at, cols - r_total + gap);
        at += try text.writeClean(w, right, r_cells);
    }
    try pad(w, &at, cols);
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
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@min(cols, max_cols), text.width(got));
}

test "game mode, wide" {
    try expectRow(
        " GAME                      Super Metroid · Snes9x 1.63              60.0 fps · 1× ",
        .{ .mode = .game, .legacy = false, .game = game, .stats = steady },
        82,
    );
}

test "TUI mode with the legacy flag and the hint" {
    try expectRow(
        " TUI  LEGACY  Space: menu  Super Metroid · Snes9x 1.63              60.0 fps · 1× ",
        .{ .mode = .tui, .legacy = true, .game = game, .stats = steady },
        82,
    );
}

test "detailed stats replace the game" {
    var st: State = .{ .mode = .game, .legacy = false, .game = game, .detailed = true, .stats = steady };
    st.stats.rebases = 3;
    try expectRow(
        " GAME        pres 60.0 · 2.1 MB/s · enc 1.2 ms/s · wr 3.0 ms/s · lag 3  60.0 fps · 1× ",
        st,
        86,
    );
}

test "paused and max on the right" {
    var st: State = .{ .mode = .game, .legacy = false, .stats = steady };
    st.stats.paused = true;
    try expectRow(" GAME                       paused ", st, 35);
    st.stats.paused = false;
    st.stats.speed = .max;
    try expectRow(" GAME              60.0 fps · max ", st, 34);
}

test "truncation: the center goes first, then the right, never the left" {
    const st: State = .{ .mode = .tui, .legacy = true, .game = game, .stats = steady };
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
        .{ .mode = .tui, .legacy = false, .message = &lines, .game = game, .stats = steady },
        45,
    );
}

test "the game name is cleaned and wide characters count two cells" {
    try expectRow(
        " GAME  ドラ?[2J  60.0 fps · 1× ",
        .{ .mode = .game, .legacy = false, .game = "ドラ\x1b[2J", .stats = steady },
        31,
    );
}

test "a custom layout" {
    var buf: [max_len]u8 = undefined;
    const layout: Layout = .{ .left = &.{.basic_stats}, .center = &.{}, .right = &.{ .flags, .mode } };
    const got = format(&buf, .{ .mode = .game, .legacy = true, .stats = steady }, layout, 40);
    try testing.expectEqualStrings(" 60.0 fps · 1×             LEGACY  GAME ", got);
}

test "very wide windows are capped" {
    var buf: [max_len]u8 = undefined;
    const got = format(&buf, .{ .mode = .game, .legacy = false, .game = game, .stats = steady }, default_layout, 5000);
    try testing.expectEqual(max_cols, text.width(got));
}
