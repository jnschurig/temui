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
//! centered box: a modal one (the quit prompt or the legacy warning), which
//! consumes every key, or the transient Ctrl-C prompt, which lets keys
//! through. Ctrl-C reaches the quit confirmation from every layer.
//!
//! No stuck keys: entering TUI mode, losing focus and opening a modal box
//! release every button. With release events (kitty, Windows console), a
//! key held through a return to game mode acts only once pressed again.
//! On the legacy path, releases are guessed from auto-repeat
//! (`ReleaseGuesser`), in game mode only.

const std = @import("std");
const keys = @import("../term/keys.zig");
const host = @import("../libretro/host.zig");
const bindings = @import("bindings.zig");
const Engine = @import("Engine.zig");
const ReleaseGuesser = @import("ReleaseGuesser.zig");

const log = std.log.scoped(.input);

const Modes = @This();

pub const Path = enum {
    kitty,
    console,
    legacy,

    /// Whether the path reports releases (and so a lone Esc is unambiguous).
    pub fn hasReleases(p: Path) bool {
        return p != .legacy;
    }
};

pub const Config = struct {
    path: Path,
    /// The mode-key chord: Ctrl + this character.
    mode_key: u21 = ']',
    /// `--paused`: the engine starts paused, so the legacy warning's hold
    /// must not resume it.
    start_paused: bool = false,
    table: []const bindings.Binding = &bindings.default,
};

pub const Mode = enum { game, tui };
pub const Modal = enum { none, quit_prompt, legacy_warning };

/// How long the Ctrl-C prompt waits for the second Ctrl-C.
pub const ctrl_c_window_ns: i96 = 3 * std.time.ns_per_s;

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

pub const quit_prompt_text = [_][]const u8{"Quit? Enter to confirm, any other key cancels"};
pub const ctrl_c_text = [_][]const u8{"Press Ctrl-C again to quit"};
/// The legacy warning. It names the mode key, because Esc can't leave game
/// mode on this path and the chord is the only way out.
pub fn legacyWarningText(mode_key: u21) []const []const u8 {
    return switch (mode_key) {
        inline 'a'...'z', ']', '\\', '^' => |k| legacyWarning(std.fmt.comptimePrint("Ctrl-{c}", .{std.ascii.toUpper(@as(u8, k))})),
        else => legacyWarning("The mode key"),
    };
}

/// A container-level constant per chord, so the lines outlive the call: the
/// viewer keeps them across frames.
fn legacyWarning(comptime chord: []const u8) []const []const u8 {
    return &struct {
        const lines = [_][]const u8{
            "Legacy keyboard input",
            "",
            "Held keys are guessed from auto-repeat:",
            "a tap holds its button for up to 0.5 s,",
            "and only one key can be held at a time.",
            "The kitty keyboard protocol (or Windows)",
            "reports real releases.",
            "",
            chord ++ " leaves game mode (Esc doesn't).",
            "",
            "Press any key to continue.",
        };
    }.lines;
}

pub const Box = struct {
    lines: []const []const u8,
    modal: bool,
};

/// What the viewer draws.
pub const View = struct {
    mode: Mode,
    legacy: bool,
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
/// When the Ctrl-C prompt goes away; null when it isn't shown.
ctrl_c_until: ?i96 = null,
/// The legacy warning paused the engine, so dismissing it resumes it.
hold_resumes: bool = false,
/// Release-event paths: the keys pressed in game mode since it was last
/// entered, still down. Keys not in here (held through a mode switch)
/// are ignored until pressed again.
held: [max_held]keys.Key = undefined,
held_len: usize = 0,
/// Legacy path, game mode only.
guesser: ReleaseGuesser = .{},
/// The buttons last sent with `set_input`.
sent: host.Buttons = @splat(false),

/// Starts in game mode. On the legacy path the warning is shown at once,
/// with the engine held paused behind it (`out` gets the commands; the
/// caller still steps once for the first frame when `start_paused`).
pub fn init(config: Config, out: *Effects) Modes {
    var m: Modes = .{ .config = config, .path = config.path };
    if (config.path == .legacy) {
        m.openLegacyWarning(config.start_paused, out);
        // The first frame is shown behind the box.
        if (!config.start_paused) out.push(.{ .engine = .step });
    }
    return m;
}

/// Switches to the legacy path for the rest of the run (the kitty protocol
/// turned out not to be active): every button is released and the legacy
/// warning opens, holding the engine unless it is already `paused`.
pub fn switchToLegacy(m: *Modes, paused: bool, out: *Effects) void {
    if (m.path == .legacy) return;
    m.path = .legacy;
    m.releaseAll();
    m.guesser = .{};
    m.openLegacyWarning(paused, out);
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

/// Expires the Ctrl-C prompt and, on the legacy path, guessed holds.
pub fn tick(m: *Modes, now: i96, out: *Effects) void {
    if (m.ctrl_c_until) |t| if (now >= t) {
        m.ctrl_c_until = null;
        out.push(.layers_changed);
    };
    if (m.path == .legacy and m.mode == .game) {
        var buf: [ReleaseGuesser.capacity]keys.Key = undefined;
        _ = m.guesser.expire(now, &buf);
    }
    m.syncButtons(out);
}

/// When `tick` next has work, if ever.
pub fn nextDeadline(m: *const Modes) ?i96 {
    const g = if (m.path == .legacy and m.mode == .game) m.guesser.nextDeadline() else null;
    const c = m.ctrl_c_until orelse return g;
    return if (g) |x| @min(x, c) else c;
}

pub fn view(m: *const Modes) View {
    const box: ?Box = switch (m.modal) {
        .quit_prompt => .{ .lines = &quit_prompt_text, .modal = true },
        .legacy_warning => .{ .lines = legacyWarningText(m.config.mode_key), .modal = true },
        .none => if (m.ctrl_c_until != null) .{ .lines = &ctrl_c_text, .modal = false } else null,
    };
    return .{
        .mode = m.mode,
        .legacy = m.path == .legacy,
        .menu = if (m.menu_open) &menu_items else null,
        .box = box,
    };
}

/// The buttons the core sees from the next frame.
pub fn buttons(m: *const Modes) host.Buttons {
    return m.sent;
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
    if (m.ctrl_c_until) |t| if (now < t) {
        log.info("quit confirmed (second Ctrl-C)", .{});
        out.push(.quit);
        return;
    };
    // Replaces the legacy warning, which counts as dismissed.
    if (m.modal == .legacy_warning) m.closeModal(out);
    m.menu_open = false;
    m.ctrl_c_until = now + ctrl_c_window_ns;
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
        .legacy_warning => m.closeModal(out),
    }
}

fn gameKey(m: *Modes, e: keys.Event, now: i96, out: *Effects) void {
    if (m.isModeKey(e)) {
        // Its repeats and release are swallowed.
        if (e.kind == .press) m.setMode(.tui, out);
        return;
    }
    if (m.path.hasReleases()) {
        if (bindings.lookup(m.config.table, e) == null) return;
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
    } else {
        // Esc does nothing in game mode here: a lone Esc needs a timeout.
        // ESC then a byte arrives as Alt+key: take it as the key, so a
        // habitual Esc doesn't swallow the next game key.
        var k = e;
        if (k.mods.alt and !k.mods.ctrl and !k.mods.super) k.mods.alt = false;
        if (bindings.lookup(m.config.table, k) == null) return;
        _ = m.guesser.press(normalized(k.key), now);
    }
}

fn tuiKey(m: *Modes, e: keys.Event, paused: bool, out: *Effects) void {
    if (e.isChord(m.config.mode_key)) return m.setMode(.game, out);
    if (e.mods.chord()) return;
    switch (e.key) {
        .named => |n| switch (n) {
            .enter => m.setMode(.game, out),
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
            const item = itemFor(c) orelse return;
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
            const item = itemFor(c) orelse return;
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
        .game => m.setMode(.game, out),
        .quit => m.openModal(.quit_prompt, out),
    }
    // Speed and pause show on the status line.
    if (a != .game and a != .quit) out.push(.layers_changed);
}

/// The menu entry for `c`, including `=` for `+` (the same key unshifted).
fn itemFor(c: u21) ?MenuItem {
    const k: u21 = if (c == '=') '+' else c;
    for (menu_items) |item| if (item.key == k) return item;
    return null;
}

fn isModeKey(m: *const Modes, e: keys.Event) bool {
    if (e.isChord(m.config.mode_key)) return true;
    return m.path.hasReleases() and e.key == .named and e.key.named == .escape and !e.mods.chord();
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
    m.ctrl_c_until = null;
    m.releaseAll();
    log.info("box: {t}", .{modal});
    out.push(.layers_changed);
}

fn openLegacyWarning(m: *Modes, paused: bool, out: *Effects) void {
    log.warn("legacy keyboard input: releases are guessed from auto-repeat", .{});
    m.openModal(.legacy_warning, out);
    m.hold_resumes = !paused;
    if (!paused) out.push(.{ .engine = .pause });
}

fn closeModal(m: *Modes, out: *Effects) void {
    if (m.modal == .legacy_warning and m.hold_resumes) {
        m.hold_resumes = false;
        out.push(.{ .engine = .@"resume" });
    }
    m.modal = .none;
    out.push(.layers_changed);
}

fn releaseAll(m: *Modes) void {
    m.held_len = 0;
    m.guesser.releaseAll();
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
        if (m.path.hasReleases()) {
            for (m.held[0..m.held_len]) |k| m.pressInto(&b, k);
        } else {
            for (m.guesser.held[0..m.guesser.len]) |h| m.pressInto(&b, h.key);
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

    fn init(config: Config) Harness {
        var h: Harness = .{ .m = undefined, .paused = config.start_paused };
        h.m = Modes.init(config, &h.out);
        h.apply();
        return h;
    }

    fn apply(h: *Harness) void {
        for (h.out.slice()) |e| switch (e) {
            .engine => |c| switch (c) {
                .pause => h.paused = true,
                .@"resume" => h.paused = false,
                else => {},
            },
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

/// The legacy warning logs at warn level, which the test runner prints.
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
    const lv = quietLogs();
    defer testing.log_level = lv;
    for ([_]Path{ .kitty, .console, .legacy }) |path| {
        var h: Harness = .init(.{ .path = path });
        if (path == .legacy) _ = h.key(press('x'), 0); // dismiss the warning
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

test "legacy: Esc does nothing in game mode; ESC+byte is the plain key" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .legacy });
    _ = h.key(press('x'), 0);
    try testing.expectEqual(0, h.key(named(.escape), 10).len);
    try testing.expectEqual(Mode.game, h.m.view().mode);
    _ = h.key(.{ .key = .{ .char = 'e' }, .mods = .{ .alt = true } }, 20);
    try testing.expect(h.down(.up));
    // In TUI mode Esc (recognised after the decoder's timeout) backs out.
    _ = h.key(ctrl(']'), 30);
    _ = h.key(press(' '), 40);
    try testing.expect(h.m.view().menu != null);
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

test "legacy warning: holds the engine, any key dismisses it and is consumed" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .legacy });
    try testing.expect(h.paused);
    try testing.expect(has(h.out.slice(), .{ .engine = .step }));
    const v = h.m.view();
    try testing.expect(v.legacy);
    try testing.expect(v.box.?.modal);
    try testing.expectEqualStrings("Legacy keyboard input", v.box.?.lines[0]);
    try testing.expectEqualStrings("Ctrl-] leaves game mode (Esc doesn't).", v.box.?.lines[8]);
    // The view returns the same lines each frame, so the viewer doesn't redraw.
    try testing.expectEqual(v.box.?.lines.ptr, h.m.view().box.?.lines.ptr);
    // The dismissing key is bound (e), but never reaches the game.
    const fx = h.key(press('e'), 10);
    try testing.expect(has(fx, .{ .engine = .@"resume" }));
    try testing.expect(!h.paused);
    try testing.expect(!h.anyDown());
    try testing.expect(h.m.view().box == null);
    _ = h.key(press('e'), 20);
    try testing.expect(h.down(.up));
}

test "legacy warning names the --mode-key chord" {
    try testing.expectEqualStrings("Ctrl-G leaves game mode (Esc doesn't).", legacyWarningText('g')[8]);
    try testing.expectEqualStrings("Ctrl-\\ leaves game mode (Esc doesn't).", legacyWarningText('\\')[8]);
}

test "legacy warning with --paused: dismissing it doesn't resume" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .legacy, .start_paused = true });
    try testing.expect(!has(h.out.slice(), .{ .engine = .step }));
    try testing.expect(!has(h.out.slice(), .{ .engine = .pause }));
    try testing.expect(!has(h.key(press('x'), 0), .{ .engine = .@"resume" }));
    try testing.expect(h.paused);
}

test "Ctrl-C replaces the legacy warning, which counts as dismissed" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .legacy });
    const fx = h.key(ctrl('c'), 0);
    try testing.expect(has(fx, .{ .engine = .@"resume" }));
    const v = h.m.view();
    try testing.expect(!v.box.?.modal);
    try testing.expectEqualStrings(ctrl_c_text[0], v.box.?.lines[0]);
    // Keys now reach the game.
    _ = h.key(press('e'), 10);
    try testing.expect(h.down(.up));
}

test "legacy: tap and hold through the guesser" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .legacy });
    _ = h.key(press('x'), 0); // dismiss
    // Tap: held for the initial window.
    _ = h.key(press('e'), 1000);
    try testing.expect(h.down(.up));
    try testing.expectEqual(@as(?i96, 1500 * ms), h.m.nextDeadline());
    try testing.expectEqual(0, h.tickAt(1499).len);
    try testing.expect(h.down(.up));
    _ = h.tickAt(1500);
    try testing.expect(!h.anyDown());

    // Hold: 400 ms delay, then 33 ms repeats: continuous, released after.
    _ = h.key(press('f'), 2000);
    var t: i96 = 2400;
    while (t < 3000) : (t += 33) {
        try testing.expectEqual(0, h.key(press('f'), t).len);
        try testing.expect(h.down(.right));
    }
    const last = t - 33;
    _ = h.tickAt(last + 82);
    try testing.expect(h.down(.right));
    _ = h.tickAt(last + 83);
    try testing.expect(!h.anyDown());

    // Unbound keys don't hold anything.
    _ = h.key(press('z'), 5000);
    try testing.expectEqual(@as(?i96, null), h.m.nextDeadline());
}

test "legacy: a mode switch releases the guessed hold and resets the guesser" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .legacy });
    _ = h.key(press('x'), 0);
    _ = h.key(press('e'), 100);
    try testing.expect(h.down(.up));
    _ = h.key(ctrl(']'), 150);
    try testing.expect(!h.anyDown());
    try testing.expectEqual(@as(?i96, null), h.m.nextDeadline());
    _ = h.key(ctrl(']'), 200);
    try testing.expect(!h.anyDown());
    try testing.expect(!h.m.guesser.isHeld(.{ .char = 'e' }));
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

test "automatic fallback: releases, warns, holds; then guesses" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(press('e'), 0);
    try testing.expect(h.down(.up));
    h.out.clear();
    h.m.switchToLegacy(h.paused, &h.out);
    h.apply();
    try testing.expect(!h.anyDown());
    try testing.expect(h.paused);
    const v = h.m.view();
    try testing.expect(v.legacy and v.box.?.modal);
    // A second call does nothing.
    h.out.clear();
    h.m.switchToLegacy(h.paused, &h.out);
    try testing.expectEqual(0, h.out.len);
    // Dismiss: the engine resumes; Esc is no longer the mode key.
    try testing.expect(has(h.key(press('x'), 10), .{ .engine = .@"resume" }));
    _ = h.key(named(.escape), 20);
    try testing.expectEqual(Mode.game, h.m.view().mode);
    _ = h.key(press('e'), 30);
    try testing.expect(h.down(.up));
    _ = h.tickAt(530);
    try testing.expect(!h.anyDown());
}

test "fallback while the user has paused: dismissing doesn't resume" {
    const lv = quietLogs();
    defer testing.log_level = lv;
    var h: Harness = .init(.{ .path = .kitty });
    _ = h.key(named(.escape), 0);
    _ = h.key(press('p'), 1);
    try testing.expect(h.paused);
    h.out.clear();
    h.m.switchToLegacy(h.paused, &h.out);
    h.apply();
    try testing.expect(!has(h.key(press('x'), 2), .{ .engine = .@"resume" }));
    try testing.expect(h.paused);
}

test "every menu item has a distinct key; only quit is menu-only" {
    for (menu_items, 0..) |a, i| {
        for (menu_items[0..i]) |b| try testing.expect(a.key != b.key);
        try testing.expectEqual(a.action != .quit, a.direct);
    }
}
