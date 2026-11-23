# 11 · Game control mapping

> Seed prompt for `/spec-and-dev docs/roadmap/11-game-control-mapping.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Every supported system has sensible keyboard controls out of the box, and users can remap them from the TUI.

## Context
- D9 — bindings are configurable; input can also come from the control socket later.
- D15 — game control mapping is its own item; remapping happens in TUI mode.
- D11 — mappings are stored in config.
- Item 06 shipped hardcoded default bindings; **this item replaces them** with the configurable mapping system.

## In scope
- Mapping model: physical input → RetroPad button/axis, per system, with per-ROM overrides if cheap.
- Per-system defaults for SNES, NES, and GB/GBC.
- A remapping screen in TUI mode: select a button, press a key, conflict detection.
- Persist mappings in the config file from item 10.
- Design the model so gamepad inputs (item 15) can be added without changing its shape.

## Out of scope
- Gamepad support itself (item 15).
- Turbo and macros.
- Mapping frontend hotkeys other than the leader key.

## Acceptance sketch
- SNES, NES and GB each have documented defaults that play well.
- A remap made in the UI takes effect immediately and persists across restarts.
- Conflicting bindings are reported, not silently accepted.
- The hardcoded bindings from item 06 are removed.

## Depends on
- [06](./06-keyboard-input-and-modes.md) — keyboard input.
- [10](./10-persistence-and-config.md) — config loader.

## Open questions for the cycle's interview
- Default layouts per system (e.g. Z/X/A/S vs. J/K/U/I)?
- Per-core or per-ROM overrides now, or only per system?
- How should keys that terminals can't distinguish without the kitty protocol be handled in the remap UI?
