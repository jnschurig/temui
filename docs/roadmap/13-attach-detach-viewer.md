# 13 · Attach / detach viewer

> Seed prompt for `/spec-and-dev docs/roadmap/13-attach-detach-viewer.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **next**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Watch and play a headless instance from any terminal, then detach and leave it running.

## Context
- D5 — `temui attach` connects as a viewer; detaching never kills the instance.
- D6 — the viewer uses the same protocol as `ctl`.
- D8 — each viewer sets its own presentation rate; speed control.
- D10 — only one process plays audio; `--audio` moves audio to the attaching viewer.

## In scope
- `temui attach <instance> [--fps N] [--audio]`.
- Receive frames (shared memory when local) and render them with item 04's renderers.
- Forward keyboard input from the viewer to the instance.
- Speed and pause controls from the viewer.
- Audio handoff: stream audio samples to the attached viewer, or move device playback; only one audible process.
- Detach with the leader key; the instance keeps running.

## Out of scope
- The multi-instance grid (item 14).
- Viewers on other machines (local only).

## Acceptance sketch
- Attach to a `run --detach` instance, play, detach, reattach: the game state persists.
- Two viewers attached at once with different fps settings both work.
- `--audio` plays sound in the viewer, and only there.
- Killing the viewer leaves the instance running.

## Depends on
- [09](./09-audio.md) — audio.
- [12](./12-control-protocol-and-registry.md) — protocol and registry.

## Open questions for the cycle's interview
- Audio handoff: stream samples over the socket, or does the instance open the device itself?
- When two viewers send input, who wins?
- What happens when a viewer is slower than its requested fps (drop to newest frame)?
