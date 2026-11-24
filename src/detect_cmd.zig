//! `temui detect`: query the terminal (raw mode only while the queries run),
//! then print the capabilities and what `auto` (or `--renderer`) would pick,
//! as text or JSON. Exits 0 even when the terminal answers nothing.

const std = @import("std");
const builtin = @import("builtin");
const caps = @import("term/caps.zig");
const detect = @import("term/detect.zig");

const Capabilities = caps.Capabilities;
const Transport = caps.Transport;
const log = std.log.scoped(.term);

/// Returns the exit code: 0, or 130 if Ctrl-C interrupted the queries.
pub fn run(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, override: ?caps.Backend, json: bool, out: *std.Io.Writer) !u8 {
    // Windows sends no queries, so it can't be interrupted.
    const cs = if (comptime builtin.os.tag == .windows)
        try detect.run(arena, io, env, .{})
    else
        detect.run(arena, io, env, .{}) catch |err| switch (err) {
            error.Interrupted => return 130,
            else => return err,
        };
    const choice = caps.select(cs, override, caps.osOf(builtin.os.tag));
    const r = report(cs, choice, override != null);
    log.info("renderer: {t} ({s}) transports={any} ascii_color={t} cell_px={d}x{d}", .{
        choice.backend, if (r.renderer.forced) "--renderer" else "auto", choice.transports.slice(), choice.ascii_color, choice.cell_px.w, choice.cell_px.h,
    });
    if (json) {
        try std.json.Stringify.value(r, .{ .whitespace = .indent_2 }, out);
        try out.writeByte('\n');
    } else try writeText(out, r);
    return 0;
}

/// Everything `detect` prints, in a shape `std.json` can serialise.
pub const Report = struct {
    terminal: ?[]const u8,
    term: ?[]const u8,
    term_program: ?[]const u8,
    colorterm: ?[]const u8,
    is_tty: bool,
    /// The terminal answered DA1 (it talks back at all).
    responded: bool,
    kitty_graphics: bool,
    /// Transports whose probe answered OK, in probe order.
    kitty_transports_ok: caps.Order,
    kitty_keyboard_flags: ?u32,
    truecolor: bool,
    truecolor_source: ?enum { decrqss, colorterm },
    cell_px: caps.CellPx,
    cell_px_source: Capabilities.CellPxSource,
    window: ?caps.WinSize,
    renderer: struct {
        backend: caps.Backend,
        /// Set by `--renderer` rather than auto-selected.
        forced: bool,
        /// Kitty only: transports in the order they'll be tried.
        transports: caps.Order,
        ascii_color: caps.AsciiColor,
    },
};

pub fn report(cs: Capabilities, choice: caps.Choice, forced: bool) Report {
    const px = cs.cellPx();
    var r: Report = .{
        .terminal = cs.xtversion,
        .term = cs.term,
        .term_program = cs.term_program,
        .colorterm = cs.colorterm,
        .is_tty = cs.is_tty,
        .responded = cs.da1,
        .kitty_graphics = cs.kitty_graphics,
        .kitty_transports_ok = .{},
        .kitty_keyboard_flags = cs.kitty_keyboard_flags,
        .truecolor = cs.truecolor(),
        .truecolor_source = if (cs.truecolor_decrqss) .decrqss else if (cs.truecolor()) .colorterm else null,
        .cell_px = px.px,
        .cell_px_source = px.source,
        .window = cs.winsize,
        .renderer = .{ .backend = choice.backend, .forced = forced, .transports = choice.transports, .ascii_color = choice.ascii_color },
    };
    for ([_]Transport{ .shm, .file, .zlib }) |t| if (cs.transports_ok.contains(t)) r.kitty_transports_ok.append(t);
    return r;
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

fn writeList(w: *std.Io.Writer, ts: []const Transport) !void {
    if (ts.len == 0) return w.writeAll("none");
    for (ts, 0..) |t, i| try w.print("{s}{t}", .{ if (i > 0) ", " else "", t });
}

pub fn writeText(w: *std.Io.Writer, r: Report) !void {
    try w.print("terminal:        {s}\n", .{r.terminal orelse "unknown (no XTVERSION reply)"});
    try w.print("environment:     TERM={s} TERM_PROGRAM={s} COLORTERM={s}\n", .{ r.term orelse "-", r.term_program orelse "-", r.colorterm orelse "-" });
    if (!r.is_tty) {
        try w.writeAll("tty:             no (stdin or stdout is not a terminal; nothing was queried)\n");
    } else {
        try w.print("responded:       {s}\n", .{yesNo(r.responded)});
    }
    try w.print("kitty graphics:  {s}", .{yesNo(r.kitty_graphics)});
    if (r.kitty_graphics) {
        try w.writeAll(" (transports OK: ");
        try writeList(w, r.kitty_transports_ok.slice());
        try w.writeByte(')');
    }
    try w.writeByte('\n');
    if (r.kitty_keyboard_flags) |f| {
        try w.print("kitty keyboard:  yes (flags {d})\n", .{f});
    } else try w.writeAll("kitty keyboard:  no\n");
    try w.print("truecolor:       {s}{s}\n", .{ yesNo(r.truecolor), if (r.truecolor_source) |s| switch (s) {
        .decrqss => " (DECRQSS)",
        .colorterm => " (COLORTERM)",
    } else "" });
    try w.print("cell size:       {d}x{d} px ({s})\n", .{ r.cell_px.w, r.cell_px.h, switch (r.cell_px_source) {
        .reply => "CSI 16 t",
        .winsize => "TIOCGWINSZ",
        .assumed => "assumed 1:2",
    } });
    if (r.window) |ws| {
        try w.print("window:          {d}x{d} cells, {d}x{d} px\n", .{ ws.cols, ws.rows, ws.px_w, ws.px_h });
    } else try w.writeAll("window:          unknown\n");
    try w.print("\nrenderer:        {t} ({s})\n", .{ r.renderer.backend, if (r.renderer.forced) "--renderer" else "auto" });
    switch (r.renderer.backend) {
        .kitty => {
            try w.writeAll("transport order: ");
            try writeList(w, r.renderer.transports.slice());
            try w.writeByte('\n');
        },
        .ascii => try w.print("ascii colour:    {t}\n", .{r.renderer.ascii_color}),
        .halfblock => {},
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const replies = @import("term/replies.zig");

fn rexCaps(arena: std.mem.Allocator) !Capabilities {
    var cs: Capabilities = .{ .is_tty = true, .term = "xterm-256color", .term_program = "Rex", .colorterm = "truecolor", .winsize = .{ .cols = 120, .rows = 40, .px_w = 1800, .px_h = 1160 } };
    var p: replies.Parser = .{};
    for ("\x1b_Gi=31;OK\x1b\\\x1b[?0u\x1bP1$r0;48:2::1:2:3m\x1b\\\x1b[6;29;15t\x1bP>|rex 0.1.0-preview.19\x1b\\\x1b[?62;22c") |b| {
        if (p.feed(b)) |e| try cs.record(arena, e);
    }
    cs.transports_ok.insert(.zlib);
    cs.transports_ok.insert(.shm);
    return cs;
}

test "text report: Rex" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const cs = try rexCaps(a.allocator());
    const r = report(cs, caps.select(cs, null, .posix), false);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeText(&aw.writer, r);
    try testing.expectEqualStrings(
        \\terminal:        rex 0.1.0-preview.19
        \\environment:     TERM=xterm-256color TERM_PROGRAM=Rex COLORTERM=truecolor
        \\responded:       yes
        \\kitty graphics:  yes (transports OK: shm, zlib)
        \\kitty keyboard:  yes (flags 0)
        \\truecolor:       yes (DECRQSS)
        \\cell size:       15x29 px (CSI 16 t)
        \\window:          120x40 cells, 1800x1160 px
        \\
        \\renderer:        kitty (auto)
        \\transport order: zlib, shm
        \\
    , aw.written());
}

test "text report: not a tty, forced ASCII" {
    const cs: Capabilities = .{ .term = "dumb" };
    const r = report(cs, caps.select(cs, .ascii, .posix), true);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeText(&aw.writer, r);
    try testing.expectEqualStrings(
        \\terminal:        unknown (no XTVERSION reply)
        \\environment:     TERM=dumb TERM_PROGRAM=- COLORTERM=-
        \\tty:             no (stdin or stdout is not a terminal; nothing was queried)
        \\kitty graphics:  no
        \\kitty keyboard:  no
        \\truecolor:       no
        \\cell size:       10x20 px (assumed 1:2)
        \\window:          unknown
        \\
        \\renderer:        ascii (--renderer)
        \\ascii colour:    none
        \\
    , aw.written());
}

test "JSON report: Rex" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const cs = try rexCaps(a.allocator());
    const r = report(cs, caps.select(cs, null, .posix), false);
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(r, .{}, &aw.writer);
    try testing.expectEqualStrings(
        \\{"terminal":"rex 0.1.0-preview.19","term":"xterm-256color","term_program":"Rex","colorterm":"truecolor","is_tty":true,"responded":true,"kitty_graphics":true,"kitty_transports_ok":["shm","zlib"],"kitty_keyboard_flags":0,"truecolor":true,"truecolor_source":"decrqss","cell_px":{"w":15,"h":29},"cell_px_source":"reply","window":{"cols":120,"rows":40,"px_w":1800,"px_h":1160},"renderer":{"backend":"kitty","forced":false,"transports":["zlib","shm"],"ascii_color":"truecolor"}}
    , aw.written());
}
