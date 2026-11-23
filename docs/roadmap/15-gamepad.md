# 15 · Gamepad

> Seed prompt for `/spec-and-dev docs/roadmap/15-gamepad.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **next**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Play with a game controller on every platform, using the mapping system from item 11.

## Context
- D1 — SDL3 is compiled in by `zig build`, with only the gamepad subsystem.
- D9 — gamepads are mapped to the RetroPad; bindings are configurable.
- Item 11's mapping model was designed to take gamepad inputs.

## In scope
- Spike first: build SDL3 statically with only the gamepad and joystick subsystems for all six targets with `zig build`.
- Initialize SDL3 without video; poll gamepad events in the input loop.
- Default gamepad → RetroPad mapping; gamepad entries in item 11's remapping UI and config.
- Hotplug: connect and disconnect during play.
- Multiple controllers mapped to RetroPad ports 1–N.

## Out of scope
- Rumble and motion sensors.
- Gamepads over SSH (they attach to the remote host).

## Acceptance sketch
- All six targets still cross-compile with SDL3 included.
- On macOS, Linux and Windows, a common controller (Xbox or DualSense) plays a game.
- Unplugging and replugging a controller mid-game works without a restart.
- Gamepad remaps persist in config.

## Depends on
- [11](./11-game-control-mapping.md) — the mapping system.

## Open questions for the cycle's interview
- Does SDL3's gamepad subsystem need any system libraries at link time on Linux (udev, dbus) — can they be loaded at runtime?
- Should SDL's controller database be updatable from a file in config?
- If the SDL3 static build fails on some target, ship without gamepads there or use a different library?
