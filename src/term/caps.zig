//! Terminal capabilities and backend selection (D7). `Capabilities` is a
//! plain value filled by detection (`detect.zig`) and, later, overridable per
//! terminal by config (item 10). `select` is pure: the same capabilities,
//! override and OS always give the same `Choice`.

const std = @import("std");
const replies = @import("replies.zig");

pub const Backend = enum { kitty, halfblock, ascii };

/// Kitty graphics transports (D7). Raw inline RGB/RGBA is never used.
pub const Transport = enum { shm, file, zlib };

pub const AsciiColor = enum { truecolor, ansi256, none };

pub const CellPx = struct { w: u32, h: u32 };

/// Used when neither `CSI 16 t` nor `TIOCGWINSZ` gives a cell size: only the
/// 1:2 ratio matters for layout.
pub const assumed_cell_px: CellPx = .{ .w = 10, .h = 20 };

pub const WinSize = struct {
    cols: u32,
    rows: u32,
    /// Zero when the terminal doesn't report pixels.
    px_w: u32 = 0,
    px_h: u32 = 0,
};

/// What the terminal told us. Strings point into memory owned by whoever
/// filled the struct (detection uses an arena).
pub const Capabilities = struct {
    /// stdin and stdout are both terminals; false skips detection entirely.
    is_tty: bool = false,
    /// The terminal answered the DA1 sentinel (it is alive and talking).
    da1: bool = false,
    /// XTVERSION text, e.g. `ghostty 1.4.0`, `kitty(0.39.1)`.
    xtversion: ?[]const u8 = null,
    term: ?[]const u8 = null,
    term_program: ?[]const u8 = null,
    colorterm: ?[]const u8 = null,
    /// The kitty graphics `a=q` query answered OK.
    kitty_graphics: bool = false,
    kitty_keyboard_flags: ?u32 = null,
    /// DECRQSS echoed back a truecolor SGR.
    truecolor_decrqss: bool = false,
    /// `CSI 16 t` reply.
    cell_px_reply: ?CellPx = null,
    /// `TIOCGWINSZ`.
    winsize: ?WinSize = null,
    /// Kitty transports whose 1×1 probe answered OK.
    transports_ok: std.EnumSet(Transport) = .empty,

    /// XTVERSION's first word (`kitty(0.39.1)` → `kitty`), else null.
    pub fn terminalName(c: Capabilities) ?[]const u8 {
        const v = c.xtversion orelse return null;
        var it = std.mem.tokenizeAny(u8, v, " (");
        return it.next();
    }

    pub fn truecolor(c: Capabilities) bool {
        if (c.truecolor_decrqss) return true;
        const ct = c.colorterm orelse return false;
        return std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit");
    }

    pub const CellPxSource = enum { reply, winsize, assumed };

    /// `CSI 16 t`, else `TIOCGWINSZ` pixels ÷ cells, else 1:2.
    pub fn cellPx(c: Capabilities) struct { px: CellPx, source: CellPxSource } {
        if (c.cell_px_reply) |px| if (px.w > 0 and px.h > 0) return .{ .px = px, .source = .reply };
        if (c.winsize) |ws| if (ws.cols > 0 and ws.rows > 0 and ws.px_w >= ws.cols and ws.px_h >= ws.rows)
            return .{ .px = .{ .w = ws.px_w / ws.cols, .h = ws.px_h / ws.rows }, .source = .winsize };
        return .{ .px = assumed_cell_px, .source = .assumed };
    }

    /// Folds one parsed reply into the capabilities. XTVERSION text is
    /// copied with `arena`, since the event's slices die on the next feed.
    pub fn record(c: *Capabilities, arena: std.mem.Allocator, e: replies.Event) !void {
        switch (e.kind) {
            .da1 => c.da1 = true,
            .kitty_graphics => c.kitty_graphics = c.kitty_graphics or e.kittyOk(),
            .kitty_keyboard => c.kitty_keyboard_flags = e.keyboardFlags(),
            .decrqss => c.truecolor_decrqss = c.truecolor_decrqss or (e.decrqssValid() and
                (std.mem.indexOf(u8, e.body, "1:2:3") != null or std.mem.indexOf(u8, e.body, "1;2;3") != null)),
            .cell_px => if (e.dims()) |hw| {
                c.cell_px_reply = .{ .w = hw[1], .h = hw[0] };
            },
            .xtversion => c.xtversion = try arena.dupe(u8, e.body),
            else => {},
        }
    }
};

/// An ordered list of up to three transports.
pub const Order = struct {
    buf: [3]Transport = undefined,
    len: u8 = 0,

    pub fn slice(o: *const Order) []const Transport {
        return o.buf[0..o.len];
    }

    fn append(o: *Order, t: Transport) void {
        o.buf[o.len] = t;
        o.len += 1;
    }

    fn contains(o: Order, t: Transport) bool {
        return std.mem.indexOfScalar(Transport, o.buf[0..o.len], t) != null;
    }
};

/// The terminal's transport preference, keyed by XTVERSION's first word
/// (D7, spike 02): Rex prefers inline zlib; everyone else local-first.
pub fn preferenceOrder(name: ?[]const u8) [3]Transport {
    if (name) |n| if (std.ascii.eqlIgnoreCase(n, "rex")) return .{ .zlib, .shm, .file };
    return .{ .shm, .file, .zlib };
}

pub const Choice = struct {
    backend: Backend,
    /// Kitty only: transports to try in order; inline zlib is always present.
    transports: Order = .{},
    ascii_color: AsciiColor,
    cell_px: CellPx,
};

pub const Os = enum { posix, windows };

pub fn osOf(tag: std.Target.Os.Tag) Os {
    return if (tag == .windows) .windows else .posix;
}

/// Picks the backend (auto, or `override`), the kitty transport order and the
/// ASCII colour mode.
pub fn select(c: Capabilities, override: ?Backend, os: Os) Choice {
    const ascii_color: AsciiColor = if (!c.is_tty)
        .none
    else if (os == .windows or c.truecolor())
        .truecolor
    else if (c.term != null and std.mem.indexOf(u8, c.term.?, "256color") != null)
        .ansi256
    else
        .none;

    const backend: Backend = override orelse if (!c.is_tty)
        .ascii
    else if (os == .windows)
        .halfblock
    else if (c.kitty_graphics)
        .kitty
    else if (c.truecolor())
        .halfblock
    else
        .ascii;

    var choice: Choice = .{ .backend = backend, .ascii_color = ascii_color, .cell_px = c.cellPx().px };
    if (backend == .kitty) {
        if (os == .posix) {
            for (preferenceOrder(c.terminalName())) |t| {
                if (t == .zlib or c.transports_ok.contains(t)) choice.transports.append(t);
            }
        }
        if (!choice.transports.contains(.zlib)) choice.transports.append(.zlib);
    }
    return choice;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Builds capabilities as detection would: env and tty state, then every
/// reply fed through the parser, then the probed transports.
fn fromReplies(arena: std.mem.Allocator, base: Capabilities, bytes: []const u8, ok: []const Transport) !Capabilities {
    var c = base;
    var p: replies.Parser = .{};
    for (bytes) |b| if (p.feed(b)) |e| try c.record(arena, e);
    for (ok) |t| c.transports_ok.insert(t);
    return c;
}

fn expectOrder(want: []const Transport, got: Choice) !void {
    try testing.expectEqualSlices(Transport, want, got.transports.slice());
}

// Recorded in spike 02 (docs/spikes/02-terminal-graphics.md, "Detection").
const rex_replies = "\x1b_Gi=31;OK\x1b\\\x1b[?0u\x1bP1$r0;48:2::1:2:3m\x1b\\\x1b[4;1972;3375t\x1b[6;29;15t\x1bP>|rex 0.1.0-preview.19\x1b\\\x1b[?62;22c";
const ghostty_replies = "\x1b_Gi=31;OK\x1b\\\x1b[?0u\x1bP1$r0;48:2::1:2:3m\x1b\\\x1b[4;2080;3430t\x1b[6;32;14t\x1bP>|ghostty 1.4.0\x1b\\\x1b[?62;22;52c";
// Not recorded here (not installed on the dev machine): representative
// replies from each terminal's documented behaviour.
const kitty_replies = "\x1b_Gi=31;OK\x1b\\\x1b[?0u\x1bP1$r0;48:2:1:2:3m\x1b\\\x1b[4;1200;1600t\x1b[6;20;10t\x1bP>|kitty(0.39.1)\x1b\\\x1b[?62;c";
const wezterm_replies = "\x1b_Gi=31;OK\x1b\\\x1b[?0u\x1bP1$r48:2::1:2:3m\x1b\\\x1b[4;1200;1600t\x1b[6;20;10t\x1bP>|WezTerm 20240203-110809-5046fc22\x1b\\\x1b[?65;4;6;18;22c";
const tmux_replies = "\x1bP>|tmux 3.5a\x1b\\\x1b[?1;2;4c";
const plain_truecolor_replies = "\x1bP1$r0;48:2:1:2:3m\x1b\\\x1b[?62;22c";

const local_env: Capabilities = .{ .is_tty = true, .term = "xterm-256color", .colorterm = "truecolor" };

test "rex: kitty, inline zlib first" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), local_env, rex_replies, &.{ .shm, .file, .zlib });
    try testing.expectEqualStrings("rex", c.terminalName().?);
    try testing.expect(c.da1 and c.kitty_graphics and c.truecolor_decrqss);
    try testing.expectEqual(@as(?u32, 0), c.kitty_keyboard_flags);
    const ch = select(c, null, .posix);
    try testing.expectEqual(Backend.kitty, ch.backend);
    try expectOrder(&.{ .zlib, .shm, .file }, ch);
    try testing.expectEqual(CellPx{ .w = 15, .h = 29 }, ch.cell_px);
    try testing.expectEqual(AsciiColor.truecolor, ch.ascii_color);
}

test "ghostty: kitty, shm first" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), .{ .is_tty = true, .term = "xterm-ghostty", .colorterm = "truecolor" }, ghostty_replies, &.{ .shm, .file, .zlib });
    const ch = select(c, null, .posix);
    try testing.expectEqual(Backend.kitty, ch.backend);
    try expectOrder(&.{ .shm, .file, .zlib }, ch);
    try testing.expectEqual(CellPx{ .w = 14, .h = 32 }, ch.cell_px);
}

test "kitty: name parsed from kitty(version)" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), .{ .is_tty = true, .term = "xterm-kitty" }, kitty_replies, &.{ .shm, .file, .zlib });
    try testing.expectEqualStrings("kitty", c.terminalName().?);
    try testing.expect(c.truecolor_decrqss);
    const ch = select(c, null, .posix);
    try testing.expectEqual(Backend.kitty, ch.backend);
    try expectOrder(&.{ .shm, .file, .zlib }, ch);
}

test "wezterm: kitty, default order" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), local_env, wezterm_replies, &.{ .shm, .file, .zlib });
    try testing.expectEqualStrings("WezTerm", c.terminalName().?);
    const ch = select(c, null, .posix);
    try testing.expectEqual(Backend.kitty, ch.backend);
    try expectOrder(&.{ .shm, .file, .zlib }, ch);
}

test "remote (ssh): shm and file probes fail, zlib only" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), local_env, ghostty_replies, &.{.zlib});
    try expectOrder(&.{.zlib}, select(c, null, .posix));
}

test "file ok but shm not: order keeps preference among survivors" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), local_env, ghostty_replies, &.{.file});
    try expectOrder(&.{ .file, .zlib }, select(c, null, .posix));
}

test "tmux: no kitty reply, truecolor from env → half-block" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), .{ .is_tty = true, .term = "tmux-256color", .colorterm = "truecolor", .winsize = .{ .cols = 80, .rows = 24, .px_w = 800, .px_h = 480 } }, tmux_replies, &.{});
    try testing.expect(!c.kitty_graphics and !c.truecolor_decrqss);
    try testing.expectEqualStrings("tmux", c.terminalName().?);
    const ch = select(c, null, .posix);
    try testing.expectEqual(Backend.halfblock, ch.backend);
    try testing.expectEqual(CellPx{ .w = 10, .h = 20 }, ch.cell_px);
    try testing.expectEqual(Capabilities.CellPxSource.winsize, c.cellPx().source);
}

test "plain truecolor terminal (DECRQSS only) → half-block" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), .{ .is_tty = true, .term = "xterm" }, plain_truecolor_replies, &.{});
    try testing.expect(c.truecolor_decrqss);
    const ch = select(c, null, .posix);
    try testing.expectEqual(Backend.halfblock, ch.backend);
    try testing.expectEqual(AsciiColor.truecolor, ch.ascii_color);
}

test "dumb terminal: nothing answers → ASCII, mono, assumed cell" {
    const c: Capabilities = .{ .is_tty = true, .term = "dumb" };
    const ch = select(c, null, .posix);
    try testing.expectEqual(Backend.ascii, ch.backend);
    try testing.expectEqual(AsciiColor.none, ch.ascii_color);
    try testing.expectEqual(assumed_cell_px, ch.cell_px);
    try testing.expectEqual(@as(u8, 0), ch.transports.len);
}

test "256-colour terminal without truecolor → ASCII with 256 colours" {
    const ch = select(.{ .is_tty = true, .term = "screen-256color" }, null, .posix);
    try testing.expectEqual(Backend.ascii, ch.backend);
    try testing.expectEqual(AsciiColor.ansi256, ch.ascii_color);
}

test "COLORTERM=24bit counts as truecolor" {
    try testing.expectEqual(Backend.halfblock, select(.{ .is_tty = true, .colorterm = "24bit" }, null, .posix).backend);
}

test "override: forced kitty on a silent terminal uses inline zlib" {
    const ch = select(.{ .is_tty = true, .term = "dumb" }, .kitty, .posix);
    try testing.expectEqual(Backend.kitty, ch.backend);
    try expectOrder(&.{.zlib}, ch);
}

test "override: half-block and ASCII on a kitty terminal" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const c = try fromReplies(a.allocator(), local_env, ghostty_replies, &.{ .shm, .file, .zlib });
    try testing.expectEqual(Backend.halfblock, select(c, .halfblock, .posix).backend);
    const ch = select(c, .ascii, .posix);
    try testing.expectEqual(Backend.ascii, ch.backend);
    try testing.expectEqual(@as(u8, 0), ch.transports.len);
}

test "windows: half-block by default, kitty override is zlib only" {
    const c: Capabilities = .{ .is_tty = true, .transports_ok = .full };
    const ch = select(c, null, .windows);
    try testing.expectEqual(Backend.halfblock, ch.backend);
    try testing.expectEqual(AsciiColor.truecolor, ch.ascii_color);
    try expectOrder(&.{.zlib}, select(c, .kitty, .windows));
    try testing.expectEqual(Backend.ascii, select(c, .ascii, .windows).backend);
}

test "not a tty: auto is ASCII without colour, overrides still honoured" {
    const c: Capabilities = .{ .is_tty = false, .term = "xterm-256color", .colorterm = "truecolor" };
    const ch = select(c, null, .posix);
    try testing.expectEqual(Backend.ascii, ch.backend);
    try testing.expectEqual(AsciiColor.none, ch.ascii_color);
    try testing.expectEqual(Backend.halfblock, select(c, .halfblock, .posix).backend);
}

test "cell size fallbacks" {
    try testing.expectEqual(Capabilities.CellPxSource.reply, (Capabilities{ .cell_px_reply = .{ .w = 9, .h = 18 } }).cellPx().source);
    // Zero pixel sizes from TIOCGWINSZ (common over some PTYs) fall through.
    const no_px: Capabilities = .{ .winsize = .{ .cols = 80, .rows = 24 } };
    try testing.expectEqual(Capabilities.CellPxSource.assumed, no_px.cellPx().source);
    try testing.expectEqual(assumed_cell_px, no_px.cellPx().px);
}

test "preference order" {
    try testing.expectEqual([3]Transport{ .zlib, .shm, .file }, preferenceOrder("Rex"));
    try testing.expectEqual([3]Transport{ .shm, .file, .zlib }, preferenceOrder("ghostty"));
    try testing.expectEqual([3]Transport{ .shm, .file, .zlib }, preferenceOrder(null));
}
