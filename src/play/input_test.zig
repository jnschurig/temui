//! In-process end-to-end input test (item 06): scripted `keys.Input`s go
//! through `Modes` into the `Engine` and the test core, which records the
//! buttons it saw on each frame at SRAM offset 4. No terminal involved.
//! The engine is paused and stepped, one frame per `frame` call, so the
//! frames line up with the fake clock exactly.

const std = @import("std");
const testing = std.testing;
const lr = @import("libretro");
const host = @import("../libretro/host.zig");
const keys = @import("../term/keys.zig");
const Engine = @import("Engine.zig");
const Modes = @import("Modes.zig");

const ms = std.time.ns_per_ms;
const up: u16 = 1 << lr.RETRO_DEVICE_ID_JOYPAD_UP;
const a_btn: u16 = 1 << lr.RETRO_DEVICE_ID_JOYPAD_A;

const Rig = struct {
    fc: Engine.FakeClock = .{},
    engine: Engine,
    modes: Modes,
    fx: Modes.Effects = .{},

    fn init(r: *Rig, path: Modes.Path) void {
        r.* = .{ .engine = undefined, .modes = undefined };
        r.engine = .init(r.fc.clock(), .{ .paused = true });
        r.modes = .init(.{ .path = path });
    }

    fn apply(r: *Rig) void {
        for (r.fx.slice()) |e| switch (e) {
            .engine => |cmd| r.engine.apply(cmd, r.fc.t),
            else => {},
        };
        r.fx.clear();
    }

    fn input(r: *Rig, in: keys.Input) void {
        r.modes.handle(in, r.fc.t, r.engine.paused(), &r.fx);
        r.apply();
    }

    fn key(r: *Rig, e: keys.Event) void {
        r.input(.{ .key = e });
    }

    /// Advances the clock by `dt_ms`, runs one frame and returns the
    /// buttons the core saw on it.
    fn frame(r: *Rig, dt_ms: i96) !u16 {
        r.fc.t += dt_ms * ms;
        r.modes.tick(r.fc.t, &r.fx);
        r.apply();
        r.engine.apply(.step, r.fc.t);
        try testing.expectEqual(1, (try r.engine.tick(r.fc.t, Engine.no_budget)).ran);
        return Engine.coreButtons();
    }
};

fn kind(c: u21, k: keys.Kind) keys.Event {
    var e = keys.Event.char(c);
    e.kind = k;
    return e;
}

test "kitty: press, hold, release; a mode switch releases; a key held through the return stays released" {
    try Engine.loadTestCore();
    defer host.unload();
    var r: Rig = undefined;
    r.init(.kitty);

    try testing.expectEqual(0, try r.frame(16));
    r.key(keys.Event.char('e'));
    try testing.expectEqual(up, try r.frame(16));
    // Held with no further events: still down.
    try testing.expectEqual(up, try r.frame(16));
    r.key(kind('e', .repeat));
    r.key(keys.Event.char('l'));
    try testing.expectEqual(up | a_btn, try r.frame(16));
    r.key(kind('e', .release));
    try testing.expectEqual(a_btn, try r.frame(16));
    r.key(kind('l', .release));
    try testing.expectEqual(0, try r.frame(16));

    // Esc to TUI mode while holding `e`: everything released at once.
    r.key(keys.Event.char('e'));
    try testing.expectEqual(up, try r.frame(16));
    r.key(keys.Event.named(.escape));
    try testing.expectEqual(0, try r.frame(16));
    var esc_up = keys.Event.named(.escape);
    esc_up.kind = .release;
    r.key(esc_up);
    // Back to the game with `i`, `e` still physically held.
    r.key(keys.Event.char('i'));
    r.key(kind('i', .release));
    try testing.expectEqual(.game, r.modes.view().mode);
    r.key(kind('e', .repeat));
    try testing.expectEqual(0, try r.frame(16));
    r.key(kind('e', .release));
    try testing.expectEqual(0, try r.frame(16));
    // Pressed again: it counts.
    r.key(keys.Event.char('e'));
    try testing.expectEqual(up, try r.frame(16));
}

test "legacy: the fixed hold: a tap lasts 100 ms, a resent key stays down, Ctrl-] releases" {
    try Engine.loadTestCore();
    defer host.unload();
    var r: Rig = undefined;
    r.init(.legacy);

    // A tap: down on the next frame, up once 100 ms have passed.
    r.key(keys.Event.char('e'));
    for (0..6) |_| try testing.expectEqual(up, try r.frame(16)); // 96 ms
    try testing.expectEqual(0, try r.frame(4)); // 100 ms
    try testing.expectEqual(0, try r.frame(16));

    // A hold: resent every 33 ms, continuously down.
    r.key(keys.Event.char('e'));
    for (0..20) |_| {
        try testing.expectEqual(up, try r.frame(16));
        try testing.expectEqual(up, try r.frame(17));
        r.key(keys.Event.char('e'));
    }
    // Let go: released 100 ms after the last press.
    try testing.expectEqual(up, try r.frame(99));
    try testing.expectEqual(0, try r.frame(1));

    // The mode key releases a held key at once.
    r.key(keys.Event.char('e'));
    try testing.expectEqual(up, try r.frame(16));
    r.key(.{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } });
    try testing.expectEqual(.tui, r.modes.view().mode);
    try testing.expectEqual(0, try r.frame(16));
}

test "disabled: game keys never reach the core" {
    try Engine.loadTestCore();
    defer host.unload();
    // Disabling game input logs at warn level.
    const lv = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = lv;
    var r: Rig = undefined;
    r.init(.disabled);

    for ("esdfljka;hg") |c| {
        r.key(keys.Event.char(c));
        try testing.expectEqual(0, try r.frame(16));
    }
    // The ways into game mode don't open it.
    r.key(keys.Event.char('i'));
    r.key(keys.Event.named(.enter));
    r.key(.{ .key = .{ .char = ']' }, .mods = .{ .ctrl = true } });
    try testing.expectEqual(.tui, r.modes.view().mode);
    r.key(keys.Event.char('e'));
    try testing.expectEqual(0, try r.frame(16));
}
