# 14 · Grid and command palette

> Seed prompt for `/spec-and-dev docs/roadmap/14-grid-and-command-palette.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **next**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
See many instances at once in a tiled view, and run any control command from the TUI, with the same power as `temui ctl`.

## Context
- D5, D6 — instances are separate processes found through the registry; the palette sends the same protocol commands as `ctl`.
- D7 — ASCII exists to keep dense grids cheap.
- D15 — TUI-mode keys; game mode targets the focused instance.

## In scope
- `temui grid` and a grid view inside the TUI shell: tiles laid out to fit the terminal, focus moves with `h`/`j`/`k`/`l`.
- Per-tile renderer and fps choice based on tile size (e.g. ASCII when small).
- Command palette (e.g. `:`) with completion, sending protocol commands; every palette command has a `ctl` equivalent.
- Live updates: instances spawned or killed from outside appear or disappear without a refresh.
- Enter game mode on the focused tile.

## Out of scope
- Broadcasting input to several instances (item 22).
- Saved layouts.

## Acceptance sketch
- A 3×3 grid of test-core instances stays responsive.
- An instance spawned with `temui ctl spawn` appears in the grid within a second.
- Every palette command maps 1:1 to a `ctl` command (checked by a test).
- Entering and leaving game mode on a tile works.

## Depends on
- [08](./08-tui-shell-and-rom-browser.md) — TUI shell.
- [12](./12-control-protocol-and-registry.md) — protocol and registry.
- [13](./13-attach-detach-viewer.md) — viewer rendering and input forwarding.

## Open questions for the cycle's interview
- Grid layout algorithm and the maximum useful number of tiles?
- Is the grid a separate command, a TUI screen, or both?
- Palette syntax: free text like `ctl`, or a structured picker?
