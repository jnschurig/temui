# 22 · Multi-instance input broadcast

> Seed prompt for `/spec-and-dev docs/roadmap/22-multi-instance-input-broadcast.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **later**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Game mode can attach to N selected instances and send each input to all of them at once.

## Context
- D15 — game mode targets one instance by default; this item adds groups.
- D6 — inputs are frame-numbered over the control protocol.
- Builds on the grid's selection and focus (item 14) and the viewer's input forwarding (item 13).

## In scope
- Selecting a group of instances in the grid.
- Game mode with a group: each input is sent to every instance in the group.
- Showing which instances belong to the group.
- Protocol support for group input if a new command is needed.

## Out of scope
- Different inputs per instance (scripting handles that via `ctl`).
- Groups across machines.

## Acceptance sketch
- One keypress reaches every instance in the group.
- The group is visible in the grid.
- Leaving game mode releases all held keys in every instance.

## Depends on
- [12](./12-control-protocol-and-registry.md) — control protocol.
- [13](./13-attach-detach-viewer.md) — input forwarding.
- [14](./14-grid-and-command-palette.md) — grid selection.

## Open questions for the cycle's interview
- Apply each input on the same frame number in every instance, or as soon as it arrives?
- How to show which instances belong to the group?
- How to handle instances running at different speeds, or paused?
