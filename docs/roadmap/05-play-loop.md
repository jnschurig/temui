# 05 · Play loop

> Seed prompt for `/spec-and-dev docs/roadmap/05-play-loop.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
`temui play <rom> --core <path>` runs a game in the terminal at the right speed, with speed controls and a stats overlay.

## Context
- D5 — `play` runs engine and viewer in one process. **The control socket is deferred to item 12**; `play` runs without one until then.
- D8 — wall-clock pacing (audio pacing arrives in item 09); fast-forward, slow motion, pause, single-step; presentation decoupled from emulation.
- D13 — optional overlay: emulated fps, presented fps, bytes/s written to the terminal.

## In scope
- Main loop: emulate at the core's reported fps, paced by a high-resolution timer.
- Speed: N×, unthrottled, slow motion (<1×), pause, step one frame.
- Presentation at its own rate (frameskip), configurable via flag (e.g. `--present-fps`).
- Terminal resize handling (SIGWINCH on POSIX, console events on Windows).
- Stats overlay toggle.
- Temporary minimal key handling (quit, pause, speed) until item 06 replaces it.

## Out of scope
- Control socket, `run --detach`, attach (items 12, 13).
- Real input handling and modes (item 06).
- Audio (item 09).
- Downloading cores (item 07); the core is given by path.

## Acceptance sketch
- The test core holds 60.0 ± 0.5 emulated fps at 1× for 5 minutes.
- 4× and unthrottled modes run faster; the overlay shows the emulated rate rising while presented fps stays at the configured rate.
- Pause and step advance exactly one frame per step.
- Resizing the terminal during play doesn't crash or leave the screen corrupted.
- A real SNES ROM is playable to look at (input comes in item 06).

## Depends on
- [03](./03-libretro-host-and-test-core.md) — core host.
- [04](./04-renderers.md) — renderers.

## Open questions for the cycle's interview
- Windows timer precision: are high-resolution waitable timers needed?
- What should happen when the host can't keep up at 1× (drop presented frames first, then slow emulation)?
- Overlay placement and whether it reserves a terminal row or draws over the image.
- How does `play` structure the engine/viewer split now so item 12 can add the socket without a rewrite?
