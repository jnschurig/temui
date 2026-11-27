//! Game mode, TUI mode, the leader menu and the centered boxes (D15,
//! item 06): `keys.Input` in, `Effect`s out. Pure: time and the engine's
//! paused state are passed in, and nothing here touches the engine, the
//! terminal or the viewer.
//!
//! The model is vim's. Game mode is insert mode: keys go to the bindings.
//! The *mode key* (Esc where it is unambiguous, and a Ctrl chord, Ctrl-]
//! by default, everywhere) leaves it for TUI mode, which is normal mode:
//! direct keys, and Space opens the leader menu. Esc only ever backs out
//! one layer.
//!
//! Layers, bottom to top: the mode, the menu (TUI only), then at most one
//! centered box: a modal one (the quit prompt or the input-lost box), which
//! consumes every key, or a transient one (the Ctrl-C prompt or the
//! game-input-disabled notice), which lets keys through. Ctrl-C reaches the
//! quit confirmation from every layer.
//!
//! Game input needs release events (D9): the kitty protocol or the Windows
//! console. Without them (`disabled`), the run stays in TUI mode, and
//! asking for game mode rechecks the kitty protocol first. The
//! `legacy` path (`--keyboard legacy`, for automation) holds each press for
//! a fixed time (`FixedHold`), in game mode only.
//!
//! No stuck keys: entering TUI mode, losing focus and opening a modal box
//! release every button. With release events, a key held through a return
//! to game mode acts only once pressed again.

const std = @import("std");
const keys = @import("../term/keys.zig");
const host = @import("../libretro/host.zig");
const bindings = @import("bindings.zig");
const Engine = @import("Engine.zig");
const FixedHold = @import("FixedHold.zig");

const log = std.log.scoped(.input);

const Modes = @This();

pub const Path = enum {
    kitty,
    console,
    /// `--keyboard legacy`: presses only, held for a fixed time.
    legacy,
    /// No release events (and not `--keyboard legacy`): game input is off.
    disabled,

    /// Whether the path reports releases (and so a lone Esc is unambiguous).
    pub fn hasReleases(p: Path) bool {
        return p == .kitty or p == .console;
    }
};

pub const Config = struct {
    path: Path,
    /// The mode-key chord: Ctrl + this character.
    mode_key: u21 = ']',
    table: []const bindings.Binding = &bindings.default,
};

pub const Mode = enum { game, tui };
pub const Modal = enum { none, quit_prompt, input_lost };
pub const Transient = struct {
    kind: enum { ctrl_c, game_disabled },
    /// When it goes away.
    until: i96,
};

/// How long the Ctrl-C prompt waits for the second Ctrl-C.
pub const ctrl_c_window_ns: i96 = 3 * std.time.ns_per_s;
/// How long the game-input-disabled notice shows.
pub const notice_ns: i96 = 3 * std.time.ns_per_s;

pub const Effect = union(enum) {
    engine: Engine.Command,
    /// The mode, the menu or the box changed: redraw the status line and
    /// the boxes.
    layers_changed,
    toggle_stats,
    /// Quit normally: restore the terminal, print the summary, exit 0.
    quit,
    /// Present the next frame at once (after a step while paused).
    force_present,
    /// Game input is disabled and game mode was asked for: ask the terminal
    /// for the kitty keyboard protocol again, then call `recheckDone`.
    recheck_keyboard,
};

pub const Effects = struct {
    buf: [16]Effect = undefined,
    len: usize = 0,

    pub fn push(e: *Effects, x: Effect) void {
        std.debug.assert(e.len < e.buf.len);
        e.buf[e.len] = x;
        e.len += 1;
    }

    pub fn slice(e: *const Effects) []const Effect {
        return e.buf[0..e.len];
    }

    pub fn clear(e: *Effects) void {
        e.len = 0;
    }
};

pub const Action = enum { toggle_pause, step, faster, slower, reset_speed, toggle_stats, game, quit };

pub const MenuItem = struct {
    key: u8,
    label: []const u8,
    action: Action,
    /// Also a direct key in TUI mode. Quit is in the menu only.
    direct: bool = true,
};

/// The leader menu, which doubles as on-screen help. Item 08 extends it.
pub const menu_items = [_]MenuItem{
    .{ .key = 'p', .label = "pause / resume", .action = .toggle_pause },
    .{ .key = '.', .label = "step one frame", .action = .step },
    .{ .key = '+', .label = "faster", .action = .faster },
    .{ .key = '-', .label = "slower", .action = .slower },
    .{ .key = '0', .label = "normal speed", .action = .reset_speed },
    .{ .key = 'o', .label = "detailed stats", .action = .toggle_stats },
    .{ .key = 'i', .label = "back to game", .action = .game },
    .{ .key = 'q', .label = "quit", .action = .quit, .direct = false },
};

/// The menu with game input disabled: no way back to a game mode that
/// can't be entered.
pub const menu_items_disabled = blk: {
    var out: [menu_items.len - 1]MenuItem = undefined;
    var n: usize = 0;
    for (menu_items) |item| if (item.action != .game) {
        out[n] = item;
        n += 1;
    };
    break :blk out;
};

pub const quit_prompt_text = [_][]const u8{"Quit? Enter to confirm, any other key cancels"};
pub const ctrl_c_text = [_][]const u8{"Press Ctrl-C again to quit"};
pub const game_disabled_text = [_][]const u8{
    "Game input needs the kitty keyboard protocol",
    "(Ghostty, kitty, WezTerm, Rex, foot) or Windows.",
    "If yours has it, try --keyboard kitty.",
};
pub const input_lost_text = [_][]const u8{
    "The terminal stopped reporting key releases,",
    "so game input is off.",
    "Press any key.",
};

pub const Box = struct {
    lines: []const []const u8,
    modal: bool,
};

/// The status line's flag after the mode.
pub const Flag = enum { none, legacy, game_disabled };

/// What the viewer draws.
pub const View = struct {
    mode: Mode,
    flag: Flag = .none,
    /// The menu's entries while it is open.
    menu: ?[]const MenuItem,
    /// The centered box, if any.
    box: ?Box,
};

const max_held = 16;

config: Config,
path: Path,
mode: Mode = .game,
menu_open: bool = false,
modal: Modal = .none,
/// The transient box, if one is showing. A modal box hides it.
transient: ?Transient = null,
/// Release-event paths: the keys pressed in game mode since it was last
/// entered, still down. Keys not in here (held through a mode switch)
/// are ignored until pressed again.
held: [max_held]keys.Key = undefined,
held_len: usize = 0,
/// Legacy path, game mode only.
hold: FixedHold = .{},
/// The buttons last sent with `set_input`.
sent: host.Buttons = @splat(false),
/// Disabled path: a recheck is out (`recheck_keyboard`).
rechecking: bool = false,

/// Starts in game mode, or in TUI mode with game input disabled.
pub fn init(config: Config) Modes {
    var m: Modes = .{ .config = config, .path = config.path };
    if (config.path == .disabled) {
        m.mode = .tui;
        log.warn("game input disabled: the terminal doesn't report key releases (no kitty keyboard protocol detected); if it has the protocol, try --keyboard kitty", .{});
    }
    return m;
}

/// Disables game input until a recheck finds the protocol again (the kitty
/// protocol turned out not to be active): every button is released, the
/// engine is paused unless it already is, and the input-lost box opens.
/// Dismissing it never
/// resumes; `p` does, as for any pause.
pub fn switchToDisabled(m: *Modes, paused: bool, out: *Effects) void {
    if (!m.path.hasReleases()) return;
    log.warn("the terminal stopped reporting key releases: game input disabled, game paused", .{});
    m.path = .disabled;
    m.mode = .tui;
    if (!paused) out.push(.{ .engine = .pause });
    // A Ctrl-C prompt that is showing stays, as Ctrl-C replaces the box: its
    // 0x03 may be the very byte that set this off, so the next one quits.
    const ctrl_c = if (m.transient) |t| t.kind == .ctrl_c else false;
    if (ctrl_c) {
        m.releaseAll();
        out.push(.layers_changed);
    } else m.openModal(.input_lost, out);
    m.syncButtons(out);
}

/// One input at `now`. `paused` is the engine's current state, for the
/// pause toggle and the step key.
pub fn handle(m: *Modes, input: keys.Input, now: i96, paused: bool, out: *Effects) void {
    m.tick(now, out);
    switch (input) {
        .focus => |gained| if (!gained) {
            log.debug("focus lost: releasing every button", .{});
            m.releaseAll();
        },
        .key => |e| {
            log.debug("key: {f}", .{e});
            m.handleKey(e, now, paused, out);
        },
    }
    m.syncButtons(out);
}

/// Expires the transient box and, on the legacy path, fixed holds.
pub fn tick(m: *Modes, now: i96, out: *Effects) void {
    if (m.transient) |t| if (now >= t.until) {
        m.transient = null;
        out.push(.layers_changed);
    };
    if (m.path == .legacy and m.mode == .game) {
        var buf: [FixedHold.capacity]keys.Key = undefined;
        _ = m.hold.expire(now, &buf);
    }
    m.syncButtons(out);
}

/// When `tick` next has work, if ever.
pub fn nextDeadline(m: *const Modes) ?i96 {
    const h = if (m.path == .legacy and m.mode == .game) m.hold.nextDeadline() else null;
    const t = (m.transient orelse return h).until;
    return if (h) |x| @min(x, t) else t;
}

pub fn view(m: *const Modes) View {
    const box: ?Box = switch (m.modal) {
        .quit_prompt => .{ .lines = &quit_prompt_text, .modal = true },
        .input_lost => .{ .lines = &input_lost_text, .modal = true },
        .none => if (m.transient) |t| .{
            .lines = switch (t.kind) {
                .ctrl_c => &ctrl_c_text,
                .game_disabled => &game_disabled_text,
            },
            .modal = false,
        } else null,
    };
    return .{
        .mode = m.mode,
        .flag = switch (m.path) {
            .kitty, .console => .none,
            .legacy => .legacy,
            .disabled => .game_disabled,
        },
        .menu = if (m.menu_open) m.menu() else null,
        .box = box,
    };
}

/// The buttons the core sees from the next frame.
pub fn buttons(m: *const Modes) host.Buttons {
    return m.sent;
}

fn menu(m: *const Modes) []const MenuItem {
    return if (m.path == .disabled) &menu_items_disabled else &menu_items;
}

fn handleKey(m: *Modes, e: keys.Event, now: i96, paused: bool, out: *Effects) void {
    // Modifier keys on their own (kitty flag 8 reports them) never act.
    if (e.key == .named and e.key.named.isModifier()) return;

    if (e.isCtrlC()) {
        if (e.kind == .press) m.ctrlC(now, out);
        return;
    }

    if (m.modal != .none) {
        if (e.kind == .press) m.dismissModal(e, out);
        return;
    }

    switch (m.mode) {
        .game => m.gameKey(e, now, out),
        .tui => if (e.kind == .press) {
            if (m.menu_open) m.menuKey(e, paused, out) else m.tuiKey(e, paused, out);
        },
    }
}

fn ctrlC(m: *Modes, now: i96, out: *Effects) void {
    if (m.modal == .quit_prompt) {
        log.info("quit confirmed (Ctrl-C at the prompt)", .{});
        out.push(.quit);
        return;
    }
    if (m.transient) |t| if (t.kind == .ctrl_c and now < t.until) {
        log.info("quit confirmed (second Ctrl-C)", .{});
        out.push(.quit);
        return;
    };
    // Replaces the input-lost box, which counts as dismissed, and the
    // game-input-disabled notice.
    if (m.modal == .input_lost) m.closeModal(out);
    m.menu_open = false;
    m.transient = .{ .kind = .ctrl_c, .until = now + ctrl_c_window_ns };
    out.push(.layers_changed);
}

fn dismissModal(m: *Modes, e: keys.Event, out: *Effects) void {
    switch (m.modal) {
        .none => unreachable,
        .quit_prompt => if (e.key == .named and e.key.named == .enter and !e.mods.chord()) {
            log.info("quit confirmed", .{});
            out.push(.quit);
        } else {
            log.info("quit cancelled", .{});
            m.closeModal(out);
        },
        .input_lost => m.closeModal(out),
    }
}

fn gameKey(m: *Modes, e: keys.Event, now: i96, out: *Effects) void {
    if (m.isModeKey(e)) {
        // Its repeats and release are swallowed.
        if (e.kind == .press) m.setMode(.tui, out);
        return;
    }
    switch (m.path) {
        .kitty, .console => {
            // A release always lets go, even with a modifier held since the
            // press (which `lookup` would refuse): only bound keys are held.
            if (e.kind != .release and bindings.lookup(m.config.table, e) == null) return;
            switch (e.kind) {
                .press => if (m.heldIndex(e.key) == null and m.held_len < max_held) {
                    m.held[m.held_len] = normalized(e.key);
                    m.held_len += 1;
                },
                .repeat => {},
                .release => if (m.heldIndex(e.key)) |i| {
                    m.held[i] = m.held[m.held_len - 1];
                    m.held_len -= 1;
                },
            }
        },
        .legacy => {
            // Esc does nothing in game mode here: a lone Esc needs a
            // timeout. ESC then a byte arrives as Alt+key: take it as the
            // key, so a stray Esc doesn't swallow the next game key.
            var k = e;
            if (k.mods.alt and !k.mods.ctrl and !k.mods.super) k.mods.alt = false;
            if (bindings.lookup(m.config.table, k) == null) return;
            // `handle` has expired the holds that ran out.
            m.hold.press(normalized(k.key), now);
        },
        // Game mode is never entered.
        .disabled => unreachable,
    }
}

fn tuiKey(m: *Modes, e: keys.Event, paused: bool, out: *Effects) void {
    if (e.isChord(m.config.mode_key)) return m.enterGame(out);
    if (e.mods.chord()) return;
    switch (e.key) {
        .named => |n| switch (n) {
            .enter => m.enterGame(out),
            else => {}, // Esc: nothing open, nothing to back out of.
        },
        .char => {
            const c = keys.lower(e.produced().?);
            if (c == ' ') {
                m.menu_open = true;
                log.info("menu opened", .{});
                out.push(.layers_changed);
                return;
            }
            const item = itemFor(&menu_items, c) orelse return;
            if (item.direct) m.run(item.action, paused, out);
        },
    }
}

fn menuKey(m: *Modes, e: keys.Event, paused: bool, out: *Effects) void {
    if (e.mods.chord()) return;
    switch (e.key) {
        .named => |n| if (n == .escape) m.closeMenu(out),
        .char => {
            const c = keys.lower(e.produced().?);
            if (c == ' ') return m.closeMenu(out);
            const item = itemFor(m.menu(), c) orelse return;
            m.closeMenu(out);
            m.run(item.action, paused, out);
        },
    }
}

fn run(m: *Modes, a: Action, paused: bool, out: *Effects) void {
    log.debug("action: {t}", .{a});
    switch (a) {
        .toggle_pause => out.push(.{ .engine = if (paused) .@"resume" else .pause }),
        .step => if (paused) {
            out.push(.{ .engine = .step });
            out.push(.force_present);
        },
        .faster => out.push(.{ .engine = .faster }),
        .slower => out.push(.{ .engine = .slower }),
        .reset_speed => out.push(.{ .engine = .reset_speed }),
        .toggle_stats => out.push(.toggle_stats),
        .game => m.enterGame(out),
        .quit => m.openModal(.quit_prompt, out),
    }
    // Speed and pause show on the status line.
    if (a != .game and a != .quit) out.push(.layers_changed);
}

/// The entry in `items` for `c`, including `=` for `+` (the same key
/// unshifted).
fn itemFor(items: []const MenuItem, c: u21) ?MenuItem {
    const k: u21 = if (c == '=') '+' else c;
    for (items) |item| if (item.key == k) return item;
    return null;
}

fn isModeKey(m: *const Modes, e: keys.Event) bool {
    if (e.isChord(m.config.mode_key)) return true;
    return m.path.hasReleases() and e.key == .named and e.key.named == .escape and !e.mods.chord();
}

/// Back to game mode, or, with game input disabled, a recheck of the
/// protocol (`recheckDone` then enters game mode or shows the notice).
fn enterGame(m: *Modes, out: *Effects) void {
    if (m.path != .disabled) return m.setMode(.game, out);
    if (m.rechecking) return;
    log.info("game mode asked for: asking the terminal for the kitty keyboard protocol again", .{});
    m.rechecking = true;
    out.push(.recheck_keyboard);
}

/// The answer to `recheck_keyboard`: with the protocol `active`, game input
/// is enabled (the kitty path) and game mode entered, unless a modal box
/// has opened meanwhile; otherwise the notice says why not.
pub fn recheckDone(m: *Modes, active: bool, now: i96, out: *Effects) void {
    if (!m.rechecking) return;
    m.rechecking = false;
    if (!active) return m.refuseGame(now, out);
    log.info("the kitty keyboard protocol is active: game input enabled", .{});
    m.path = .kitty;
    out.push(.layers_changed);
    if (m.modal == .none) m.setMode(.game, out);
}

/// The game-input-disabled notice. A Ctrl-C prompt that is showing stays:
/// Ctrl-C always takes over.
fn refuseGame(m: *Modes, now: i96, out: *Effects) void {
    if (m.transient) |t| if (t.kind == .ctrl_c) return;
    log.debug("game mode refused: game input disabled", .{});
    m.transient = .{ .kind = .game_disabled, .until = now + notice_ns };
    out.push(.layers_changed);
}

fn setMode(m: *Modes, mode: Mode, out: *Effects) void {
    if (m.mode == mode) return;
    m.releaseAll();
    m.mode = mode;
    m.menu_open = false;
    log.info("mode: {t}", .{mode});
    out.push(.layers_changed);
}

fn closeMenu(m: *Modes, out: *Effects) void {
    m.menu_open = false;
    out.push(.layers_changed);
}

fn openModal(m: *Modes, modal: Modal, out: *Effects) void {
    m.modal = modal;
    m.menu_open = false;
    m.transient = null;
    m.releaseAll();
    log.info("box: {t}", .{modal});
    out.push(.layers_changed);
}

fn closeModal(m: *Modes, out: *Effects) void {
    m.modal = .none;
    out.push(.layers_changed);
}

fn releaseAll(m: *Modes) void {
    m.held_len = 0;
    m.hold.releaseAll();
}

fn heldIndex(m: *const Modes, k: keys.Key) ?usize {
    const n = normalized(k);
    for (m.held[0..m.held_len], 0..) |h, i| if (h.eql(n)) return i;
    return null;
}

/// Emits `set_input` when the buttons the held keys press have changed.
fn syncButtons(m: *Modes, out: *Effects) void {
    var b: host.Buttons = @splat(false);
    if (m.mode == .game and m.modal == .none) {
        switch (m.path) {
            .kitty, .console => for (m.held[0..m.held_len]) |k| m.pressInto(&b, k),
            .legacy => for (m.hold.heldKeys()) |h| m.pressInto(&b, h.key),
            .disabled => {},
        }
    }
    if (std.mem.eql(bool, &b, &m.sent)) return;
    m.sent = b;
    out.push(.{ .engine = .{ .set_input = b } });
}

fn pressInto(m: *const Modes, b: *host.Buttons, k: keys.Key) void {
    if (bindings.lookup(m.config.table, .{ .key = k })) |button| b[@intFromEnum(button)] = true;
}

fn normalized(k: keys.Key) keys.Key {
    return switch (k) {
        .char => |c| .{ .char = keys.lower(c) },
        .named => k,
    };
}


// ---------------------------------------------------------------- tests

const testing = std.testing;
const ms = std.time.ns_per_ms;
const Button = bindings.Button;

/// Drives a `Modes` with scripted inputs, applying pause and resume to its
/// own `paused` as the engine would.
const Harness = struct {
    m: Modes,
    out: Effects = .{},
    paused: bool = false,
    t: i96 = 0,
    /// The terminal's answer to `recheck_keyboard`, given at once; null
    /// leaves the recheck out, for the test to answer.
    recheck: ?bool = false,

    fn init(config: Config) Harness {
        return .{ .m = .init(config) };
    }

    fn apply(h: *Harness) void {
        var i: usize = 0;
        // By index: an answered recheck adds effects.
        while (i < h.out.len) : (i += 1) switch (h.out.buf[i]) {
            .engine => |c| switch (c) {
                .pause => h.paused = true,
                .@"resume" => h.paused = false,
                else => {},
            },
            .recheck_keyboard => if (h.recheck) |active| h.m.recheckDone(active, h.t, &h.out),
            else => {},
        };
    }

    /// Feeds `input` at `t_ms` and returns the effects.
    fn in(h: *Harness, input: keys.Input, t_ms: i96) []const Effect {
        h.t = t_ms * ms;
        h.out.clear();
        h.m.handle(input, h.t, h.paused, &h.out);
        h.apply();
        return h.out.slice();
    }

    fn key(h: *Harness, e: keys.Event, t_ms: i96) []const Effect {
        return h.in(.{ .key = e }, t_ms);
    }

    fn tickAt(h: *Harness, t_ms: i96) []const Effect {
        h.t = t_ms * ms;
        h.out.clear();
        h.m.tick(h.t, &h.out);
        h.apply();
        return h.out.slice();
    }

    fn down(h: *const Harness, b: Button) bool {
        return h.m.buttons()[@intFromEnum(b)];
    }

    fn anyDown(h: *const Harness) bool {
        return std.mem.indexOfScalar(bool, &h.m.buttons(), true) != null;
    }
};

/// Disabling game input logs at warn level, which the test runner prints.
fn quietLogs() std.log.Level {
    const prev = testing.log_level;
    testing.log_level = .err;
    return prev;
}

fn press(c: u21) keys.Event {
    return keys.Event.char(c);
}

fn kind(c: u21, k: keys.Kind) keys.Event {
    return .{ .key = .{ .char = c }, .kind = k };
}

fn named(n: keys.Named) keys.Event {
    return keys.Event.named(n);
}

fn ctrl(c: u21) keys.Event {
    return .{ .key = .{ .char = c }, .mods = .{ .ctrl = true } };
}

fn has(effects: []const Effect, want: Effect) bool {
    for (effects) |e| if (std.meta.eql(e, want)) return true;
    return false;
}

fn hasQuit(effects: []const Effect) bool {
    return has(effects, .quit);
}

test "kitty: press, hold and release drive the bound button" {
    var h: Harness = .init(.{ .path = .kitty });
    try testing.expectEqual(Mode.game, h.m.view().mode);
    try testing.expect(h.m.view().box == null);

    var fx = h.key(press('e'), 0);
    try testing.expect(h.down(.up));
    try testing.expectEqual(1, fx.len);
    try testing.expect(fx[0] == .engine and fx[0].engine == .set_input);
    // Repeats change nothing.
    try testing.expectEqual(0, h.key(kind('e', .repeat), 400).len);
    // A second key adds its button; releases clear each.
    _ = h.key(press('l'), 410);
    try testing.expect(h.down(.up) and h.down(.a));
    _ = h.key(kind('e', .release), 500);
    try testing.expect(!h.down(.up) and h.down(.a));
    _ = h.key(kind('l', .release), 510);
    try testing.expect(!h.anyDown());
    // Unbound keys, Space included, are ignored.
    fx = h.key(press(' '), 600);
    try testing.expectEqual(0, fx.len);
    fx = h.key(named(.up), 601);
    try testing.expectEqual(0, fx.len);
    // Shift doesn't matter; Ctrl does.
    _ = h.key(.{ .key = .{ .char = 'e' }, .shifted = 'E', .mods = .{ .shift = true } }, 700);
    try testing.expect(h.down(.up));
    _ = h.key(.{ .key = .{ .char = 'e' }, .mods = .{ .shift = true }, .kind = .release }, 710);
    try testing.expect(!h.anyDown());
    try testing.expectEqual(0, h.key(ctrl('e'), 720).len);
    // A modifier key on its own does nothing.
    try testing.expectEqual(0, h.key(named(.left_shift), 730).len);
}

test "kitty: Esc enters TUI mode and releases everything; its release is swallowed" {
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(press('e'), 0);
    const fx = h.key(named(.escape), 10);
    try testing.expectEqual(Mode.tui, h.m.view().mode);
    try testing.expect(!h.anyDown());
    try testing.expect(has(fx, .layers_changed));
    try testing.expect(has(fx, .{ .engine = .{ .set_input = @splat(false) } }));
    // The game keeps running: no pause.
    try testing.expect(!h.paused);
    try testing.expectEqual(0, h.key(.{ .key = .{ .named = .escape }, .kind = .repeat }, 20).len);
    try testing.expectEqual(0, h.key(.{ .key = .{ .named = .escape }, .kind = .release }, 30).len);
    try testing.expectEqual(Mode.tui, h.m.view().mode);
}

test "kitty: a key held through the return to game mode stays released" {
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(press('e'), 0);
    _ = h.key(named(.escape), 10);
    // `i` returns to the game; e is still physically held and repeating.
    _ = h.key(press('i'), 20);
    try testing.expectEqual(Mode.game, h.m.view().mode);
    // `i`'s own release in game mode (it is bound to X) is ignored.
    try testing.expectEqual(0, h.key(kind('i', .release), 25).len);
    try testing.expectEqual(0, h.key(kind('e', .repeat), 30).len);
    try testing.expect(!h.anyDown());
    try testing.expectEqual(0, h.key(kind('e', .release), 40).len);
    // Pressed again: it acts.
    _ = h.key(press('e'), 50);
    try testing.expect(h.down(.up));
}

test "mode key chord on every path; Enter and i return; Esc in TUI does nothing" {
    for ([_]Path{ .kitty, .console, .legacy }) |path| {
        var h: Harness = .init(.{ .path = path });
        _ = h.key(ctrl(']'), 1);
        try testing.expectEqual(Mode.tui, h.m.view().mode);
        try testing.expectEqual(0, h.key(named(.escape), 2).len);
        try testing.expectEqual(Mode.tui, h.m.view().mode);
        _ = h.key(ctrl(']'), 3);
        try testing.expectEqual(Mode.game, h.m.view().mode);
        _ = h.key(ctrl(']'), 4);
        _ = h.key(named(.enter), 5);
        try testing.expectEqual(Mode.game, h.m.view().mode);
        _ = h.key(ctrl(']'), 6);
        _ = h.key(.{ .key = .{ .char = 'i' }, .shifted = 'I', .mods = .{ .shift = true } }, 7);
        try testing.expectEqual(Mode.game, h.m.view().mode);
    }
}

test "--mode-key changes the chord; Ctrl-] then is just unbound" {
    var h: Harness = .init(.{ .path = .kitty, .mode_key = 'g' });
    _ = h.key(ctrl(']'), 0);
    try testing.expectEqual(Mode.game, h.m.view().mode);
    _ = h.key(ctrl('g'), 1);
    try testing.expectEqual(Mode.tui, h.m.view().mode);
}

test "legacy: starts in game mode with no box; Esc does nothing in game mode; ESC+byte is the plain key" {
    var h: Harness = .init(.{ .path = .legacy });
    var v = h.m.view();
    try testing.expectEqual(Mode.game, v.mode);
    try testing.expectEqual(Flag.legacy, v.flag);
    try testing.expect(v.box == null);
    try testing.expect(!h.paused);
    try testing.expectEqual(0, h.key(named(.escape), 10).len);
    try testing.expectEqual(Mode.game, h.m.view().mode);
    _ = h.key(.{ .key = .{ .char = 'e' }, .mods = .{ .alt = true } }, 20);
    try testing.expect(h.down(.up));
    // In TUI mode Esc (recognised after the decoder's timeout) backs out.
    _ = h.key(ctrl(']'), 30);
    _ = h.key(press(' '), 40);
    v = h.m.view();
    try testing.expectEqual(menu_items.len, v.menu.?.len);
    _ = h.key(named(.escape), 50);
    try testing.expect(h.m.view().menu == null);
}

test "TUI direct keys" {
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(named(.escape), 0);
    var fx = h.key(press('p'), 1);
    try testing.expect(has(fx, .{ .engine = .pause }) and has(fx, .layers_changed));
    try testing.expect(h.paused);
    fx = h.key(press('.'), 2);
    try testing.expect(has(fx, .{ .engine = .step }) and has(fx, .force_present));
    fx = h.key(press('p'), 3);
    try testing.expect(has(fx, .{ .engine = .@"resume" }));
    // Step only while paused.
    try testing.expect(!has(h.key(press('.'), 4), .{ .engine = .step }));
    try testing.expect(has(h.key(press('+'), 5), .{ .engine = .faster }));
    try testing.expect(has(h.key(press('='), 6), .{ .engine = .faster }));
    // Kitty's Shift-= with alternate key `+`.
    try testing.expect(has(h.key(.{ .key = .{ .char = '=' }, .shifted = '+', .mods = .{ .shift = true } }, 7), .{ .engine = .faster }));
    try testing.expect(has(h.key(press('-'), 8), .{ .engine = .slower }));
    try testing.expect(has(h.key(press('0'), 9), .{ .engine = .reset_speed }));
    try testing.expect(has(h.key(press('o'), 10), .toggle_stats));
    // Quit is never a direct key; repeats and releases never act.
    try testing.expectEqual(0, h.key(press('q'), 11).len);
    try testing.expectEqual(0, h.key(kind('p', .repeat), 12).len);
    try testing.expectEqual(0, h.key(kind('p', .release), 13).len);
    // Bound game keys do nothing in TUI mode.
    try testing.expectEqual(0, h.key(press('e'), 14).len);
    try testing.expect(!h.anyDown());
}

test "leader menu: opens on Space, runs an entry and closes, ignores other keys" {
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(press(' '), 0); // game mode: unbound, ignored
    try testing.expect(h.m.view().menu == null);
    _ = h.key(named(.escape), 1);
    _ = h.key(press(' '), 2);
    const v = h.m.view();
    try testing.expectEqual(menu_items.len, v.menu.?.len);
    try testing.expect(v.box == null);
    // Ignored: unknown keys, Enter, chords.
    try testing.expectEqual(0, h.key(press('z'), 3).len);
    try testing.expectEqual(0, h.key(named(.enter), 4).len);
    try testing.expect(h.m.view().menu != null);
    const fx = h.key(press('p'), 5);
    try testing.expect(has(fx, .{ .engine = .pause }));
    try testing.expect(h.m.view().menu == null);
    // Space and Esc dismiss.
    _ = h.key(press(' '), 6);
    _ = h.key(press(' '), 7);
    try testing.expect(h.m.view().menu == null);
    _ = h.key(press(' '), 8);
    _ = h.key(named(.escape), 9);
    try testing.expect(h.m.view().menu == null);
    try testing.expectEqual(Mode.tui, h.m.view().mode);
    // `i` from the menu returns to the game.
    _ = h.key(press(' '), 10);
    _ = h.key(press('i'), 11);
    try testing.expectEqual(Mode.game, h.m.view().mode);
    try testing.expect(h.m.view().menu == null);
}

test "quit prompt: q then Enter quits, q then another key cancels and is consumed" {
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(named(.escape), 0);
    _ = h.key(press(' '), 1);
    _ = h.key(press('q'), 2);
    var v = h.m.view();
    try testing.expect(v.menu == null);
    try testing.expect(v.box.?.modal);
    try testing.expectEqualStrings(quit_prompt_text[0], v.box.?.lines[0]);
    // No timeout.
    try testing.expectEqual(0, h.tickAt(60_000).len);
    try testing.expect(hasQuit(h.key(named(.enter), 60_001)));

    h = .init(.{ .path = .kitty });
    _ = h.key(named(.escape), 0);
    _ = h.key(press(' '), 1);
    _ = h.key(press('q'), 2);
    // A modifier on its own doesn't cancel; a release doesn't either.
    try testing.expectEqual(0, h.key(named(.left_shift), 3).len);
    try testing.expectEqual(0, h.key(kind('q', .release), 4).len);
    // `p` cancels and does not pause.
    const fx = h.key(press('p'), 5);
    try testing.expect(!hasQuit(fx) and !has(fx, .{ .engine = .pause }));
    v = h.m.view();
    try testing.expect(v.box == null and v.menu == null);
    try testing.expectEqual(Mode.tui, v.mode);
    // Esc cancels too.
    _ = h.key(press(' '), 6);
    _ = h.key(press('q'), 7);
    try testing.expect(!hasQuit(h.key(named(.escape), 8)));
    try testing.expect(h.m.view().box == null);
    // Ctrl-C at the prompt confirms.
    _ = h.key(press(' '), 9);
    _ = h.key(press('q'), 10);
    try testing.expect(hasQuit(h.key(ctrl('c'), 11)));
}

test "Ctrl-C: transient prompt, second press within 3 s quits, then it starts over" {
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(press('e'), 0);
    var fx = h.key(ctrl('c'), 1000);
    try testing.expect(!hasQuit(fx));
    const v = h.m.view();
    try testing.expect(!v.box.?.modal);
    try testing.expectEqualStrings(ctrl_c_text[0], v.box.?.lines[0]);
    // Transient: game keys keep working, and the held key stays held.
    try testing.expect(h.down(.up));
    _ = h.key(press('l'), 1100);
    try testing.expect(h.down(.a));
    try testing.expectEqual(@as(?i96, 4000 * ms), h.m.nextDeadline());
    // Repeat and release of Ctrl-C don't count.
    try testing.expect(!hasQuit(h.key(.{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true }, .kind = .release }, 1200)));
    try testing.expect(hasQuit(h.key(ctrl('c'), 3999)));

    // Outside the window: the prompt expires and the next one starts over.
    h = .init(.{ .path = .kitty });
    _ = h.key(ctrl('c'), 0);
    fx = h.tickAt(2999);
    try testing.expectEqual(0, fx.len);
    fx = h.tickAt(3000);
    try testing.expect(has(fx, .layers_changed));
    try testing.expect(h.m.view().box == null);
    fx = h.key(ctrl('c'), 3001);
    try testing.expect(!hasQuit(fx));
    try testing.expect(h.m.view().box != null);
    // Ctrl-C never reaches the game.
    try testing.expect(!h.anyDown());
}

test "Ctrl-C from the menu closes it; from TUI mode it works too" {
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(named(.escape), 0);
    _ = h.key(press(' '), 1);
    _ = h.key(ctrl('c'), 2);
    const v = h.m.view();
    try testing.expect(v.menu == null and v.box != null);
    // TUI keys keep working while the prompt shows.
    try testing.expect(has(h.key(press('p'), 3), .{ .engine = .pause }));
    try testing.expect(hasQuit(h.key(ctrl('c'), 4)));
}

test "disabled: starts in TUI mode; no game key reaches the bindings" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .disabled });
    const v = h.m.view();
    try testing.expectEqual(Mode.tui, v.mode);
    try testing.expectEqual(Flag.game_disabled, v.flag);
    try testing.expect(v.box == null);
    try testing.expect(!h.paused);
    // Bound game keys do nothing; Esc is not a mode key.
    for ("esdfljka;hg") |c| try testing.expectEqual(0, h.key(press(c), 1).len);
    try testing.expectEqual(0, h.key(named(.escape), 2).len);
    try testing.expect(!h.anyDown());
    try testing.expectEqual(Mode.tui, h.m.view().mode);
    // TUI keys work.
    try testing.expect(has(h.key(press('p'), 3), .{ .engine = .pause }));
}

test "disabled: i, Enter, the chord and the direct key show the notice for 3 s" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    const ways = [_]keys.Event{ press('i'), named(.enter), ctrl(']'), .{ .key = .{ .char = 'i' }, .shifted = 'I', .mods = .{ .shift = true } } };
    for (ways) |way| {
        var h: Harness = .init(.{ .path = .disabled });
        const fx = h.key(way, 1000);
        try testing.expect(has(fx, .layers_changed));
        const v = h.m.view();
        try testing.expectEqual(Mode.tui, v.mode);
        try testing.expect(!v.box.?.modal);
        try testing.expectEqual(game_disabled_text.len, v.box.?.lines.len);
        try testing.expectEqualStrings("If yours has it, try --keyboard kitty.", v.box.?.lines[2]);
        try testing.expectEqual(@as(?i96, 4000 * ms), h.m.nextDeadline());
        // Transient: TUI keys go through.
        try testing.expect(has(h.key(press('o'), 1500), .toggle_stats));
        try testing.expectEqual(0, h.tickAt(3999).len);
        try testing.expect(has(h.tickAt(4000), .layers_changed));
        try testing.expect(h.m.view().box == null);
    }
}

test "disabled: the menu has no i; Ctrl-C replaces the notice, and the notice doesn't replace the prompt" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .disabled });
    _ = h.key(press(' '), 0);
    const items = h.m.view().menu.?;
    try testing.expectEqual(menu_items.len - 1, items.len);
    for (items) |item| try testing.expect(item.action != .game);
    // `i` isn't an entry here: ignored, and the menu stays open.
    try testing.expectEqual(0, h.key(press('i'), 1).len);
    try testing.expect(h.m.view().menu != null);
    _ = h.key(press(' '), 2);

    _ = h.key(press('i'), 10);
    try testing.expectEqualStrings(game_disabled_text[0], h.m.view().box.?.lines[0]);
    _ = h.key(ctrl('c'), 20);
    try testing.expectEqualStrings(ctrl_c_text[0], h.m.view().box.?.lines[0]);
    _ = h.key(press('i'), 30);
    try testing.expectEqualStrings(ctrl_c_text[0], h.m.view().box.?.lines[0]);
    // The notice didn't take the prompt's place: a second Ctrl-C quits.
    try testing.expect(hasQuit(h.key(ctrl('c'), 40)));

    // A Ctrl-C after the notice is a first press, not a second.
    h = .init(.{ .path = .disabled });
    _ = h.key(press('i'), 0);
    try testing.expect(!hasQuit(h.key(ctrl('c'), 10)));
}

test "disabled: a recheck that finds the protocol enables game input and enters game mode" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .disabled });
    h.recheck = null;
    try testing.expect(has(h.key(press('i'), 0), .recheck_keyboard));
    // Nothing shows while it is out, and asking again asks nothing more.
    try testing.expect(h.m.view().box == null);
    try testing.expect(!has(h.key(named(.enter), 1), .recheck_keyboard));
    h.out.clear();
    h.m.recheckDone(true, 5 * ms, &h.out);
    var v = h.m.view();
    try testing.expectEqual(Mode.game, v.mode);
    try testing.expectEqual(Flag.none, v.flag);
    try testing.expect(v.box == null);
    _ = h.key(press('e'), 10);
    try testing.expect(h.down(.up));
    _ = h.key(kind('e', .release), 20);
    try testing.expect(!h.anyDown());
    // Esc is the mode key now.
    _ = h.key(named(.escape), 30);
    try testing.expectEqual(Mode.tui, h.m.view().mode);

    // Lost again later: disabled again, and `i` rechecks once more.
    h.out.clear();
    h.m.switchToDisabled(h.paused, &h.out);
    h.apply();
    v = h.m.view();
    try testing.expectEqual(Flag.game_disabled, v.flag);
    _ = h.key(press('x'), 40); // dismisses the box
    try testing.expect(has(h.key(press('i'), 50), .recheck_keyboard));
}

test "disabled: a recheck answered with a modal box open enables game input but stays in TUI mode" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .disabled });
    h.recheck = null;
    _ = h.key(press('i'), 0);
    _ = h.key(press(' '), 1);
    _ = h.key(press('q'), 2);
    try testing.expect(h.m.view().box.?.modal);
    h.out.clear();
    h.m.recheckDone(true, 3 * ms, &h.out);
    const v = h.m.view();
    try testing.expectEqual(Mode.tui, v.mode);
    try testing.expectEqual(Flag.none, v.flag);
    try testing.expect(v.box.?.modal);
}

test "legacy: the fixed hold through Modes" {
    var h: Harness = .init(.{ .path = .legacy });
    // Tap: held for 100 ms.
    _ = h.key(press('e'), 1000);
    try testing.expect(h.down(.up));
    try testing.expectEqual(@as(?i96, 1100 * ms), h.m.nextDeadline());
    try testing.expectEqual(0, h.tickAt(1099).len);
    try testing.expect(h.down(.up));
    try testing.expect(has(h.tickAt(1100), .{ .engine = .{ .set_input = @splat(false) } }));

    // Hold: resent every 33 ms, continuous; released 100 ms after the last.
    var t: i96 = 2000;
    _ = h.key(press('f'), t);
    t += 33;
    while (t < 3000) : (t += 33) {
        try testing.expectEqual(0, h.key(press('f'), t).len);
        try testing.expect(h.down(.right));
    }
    const last = t - 33;
    _ = h.tickAt(last + 99);
    try testing.expect(h.down(.right));
    _ = h.tickAt(last + 100);
    try testing.expect(!h.anyDown());

    // Two keys at once.
    _ = h.key(press('e'), 4000);
    _ = h.key(press('l'), 4050);
    try testing.expect(h.down(.up) and h.down(.a));
    _ = h.tickAt(4100);
    try testing.expect(!h.down(.up) and h.down(.a));
    _ = h.tickAt(4150);
    try testing.expect(!h.anyDown());

    // Unbound keys don't hold anything.
    _ = h.key(press('z'), 5000);
    try testing.expectEqual(@as(?i96, null), h.m.nextDeadline());
}

test "legacy: a mode switch releases the fixed hold" {
    var h: Harness = .init(.{ .path = .legacy });
    _ = h.key(press('e'), 100);
    try testing.expect(h.down(.up));
    _ = h.key(ctrl(']'), 150);
    try testing.expect(!h.anyDown());
    try testing.expectEqual(@as(?i96, null), h.m.nextDeadline());
    _ = h.key(ctrl(']'), 160);
    try testing.expect(!h.anyDown());
    try testing.expect(!h.m.hold.isHeld(.{ .char = 'e' }));
}

test "focus-out releases every button" {
    var h: Harness = .init(.{ .path = .console });
    _ = h.key(press('e'), 0);
    _ = h.key(press('l'), 1);
    try testing.expect(h.down(.up) and h.down(.a));
    _ = h.in(.{ .focus = false }, 2);
    try testing.expect(!h.anyDown());
    _ = h.in(.{ .focus = true }, 3);
    // Still held physically, but it acts only once pressed again.
    try testing.expectEqual(0, h.key(kind('e', .repeat), 4).len);
    try testing.expect(!h.anyDown());
}

test "switchToDisabled: releases, pauses, the box consumes its key, p resumes" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(press('e'), 0);
    try testing.expect(h.down(.up));
    h.out.clear();
    h.m.switchToDisabled(h.paused, &h.out);
    h.apply();
    try testing.expect(!h.anyDown());
    try testing.expect(h.paused);
    var v = h.m.view();
    try testing.expectEqual(Mode.tui, v.mode);
    try testing.expectEqual(Flag.game_disabled, v.flag);
    try testing.expect(v.box.?.modal);
    try testing.expectEqualStrings(input_lost_text[0], v.box.?.lines[0]);
    // A second call does nothing.
    h.out.clear();
    h.m.switchToDisabled(h.paused, &h.out);
    try testing.expectEqual(0, h.out.len);
    // The dismissing key (p) is consumed: no resume.
    const fx = h.key(press('p'), 10);
    try testing.expect(!has(fx, .{ .engine = .@"resume" }));
    try testing.expect(h.paused);
    try testing.expect(h.m.view().box == null);
    // `p` resumes; game mode stays out of reach.
    try testing.expect(has(h.key(press('p'), 20), .{ .engine = .@"resume" }));
    _ = h.key(named(.escape), 30);
    _ = h.key(press('i'), 40);
    v = h.m.view();
    try testing.expectEqual(Mode.tui, v.mode);
    try testing.expectEqualStrings(game_disabled_text[0], v.box.?.lines[0]);
    _ = h.key(press('e'), 50);
    try testing.expect(!h.anyDown());
}

test "switchToDisabled while paused, from the menu; Ctrl-C replaces the box" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(named(.escape), 0);
    _ = h.key(press('p'), 1);
    _ = h.key(press(' '), 2);
    try testing.expect(h.paused);
    h.out.clear();
    h.m.switchToDisabled(h.paused, &h.out);
    try testing.expect(!has(h.out.slice(), .{ .engine = .pause }));
    h.apply();
    try testing.expect(h.m.view().menu == null);
    // Ctrl-C replaces it (counts as dismissed), and doesn't resume.
    const fx = h.key(ctrl('c'), 3);
    try testing.expect(!has(fx, .{ .engine = .@"resume" }));
    const v = h.m.view();
    try testing.expect(!v.box.?.modal);
    try testing.expectEqualStrings(ctrl_c_text[0], v.box.?.lines[0]);
    try testing.expect(hasQuit(h.key(ctrl('c'), 4)));
}

test "kitty: a release with a modifier held since the press still lets go" {
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(press('f'), 0);
    try testing.expect(h.down(.right));
    // Ctrl goes down, then f comes up with Ctrl reported.
    _ = h.key(.{ .key = .{ .char = 'f' }, .mods = .{ .ctrl = true }, .kind = .release }, 1);
    try testing.expect(!h.anyDown());
    // A press with Alt held still doesn't reach the game.
    _ = h.key(.{ .key = .{ .char = 'f' }, .mods = .{ .alt = true } }, 2);
    try testing.expect(!h.anyDown());
}

test "switchToDisabled set off by Ctrl-C: the prompt stays, and the next Ctrl-C quits" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(ctrl('c'), 0);
    h.out.clear();
    h.m.switchToDisabled(h.paused, &h.out);
    h.apply();
    try testing.expect(h.paused);
    const v = h.m.view();
    try testing.expectEqual(Flag.game_disabled, v.flag);
    try testing.expectEqualStrings(ctrl_c_text[0], v.box.?.lines[0]);
    try testing.expect(hasQuit(h.key(ctrl('c'), 10)));
}

test "every menu item has a distinct key; only quit is menu-only" {
    for (menu_items, 0..) |a, i| {
        for (menu_items[0..i]) |b| try testing.expect(a.key != b.key);
        try testing.expectEqual(a.action != .quit, a.direct);
    }
}
