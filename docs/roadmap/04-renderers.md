# 04 · Renderers

> Seed prompt for `/spec-and-dev docs/roadmap/04-renderers.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Build the production renderer interface and its three backends, with automatic selection and an override flag.

## Context
- D7 — kitty graphics (primary), half-block truecolor (fallback), ASCII; auto-detected, overridable.
- D14 — golden-image tests and a throughput benchmark per renderer.
- Item 02's results (`docs/spikes/02-terminal-graphics.md`) set the transport order, the default renderer per terminal, and the performance targets.

## In scope
- The renderer interface: init with terminal capabilities, present a frame into a cell rectangle, resize, teardown.
- Terminal capability detection (from item 02's prototype) and a `--renderer kitty|halfblock|ascii` override.
- Kitty backend: two alternating image ids per instance (D7), native-resolution frames, terminal-side scaling, per-terminal transport order (default shared memory → temp file → inline zlib; inline zlib first in Rex).
- Half-block backend: `▀` with fg/bg truecolor, 2 pixels per cell, redrawing only changed cells.
- ASCII backend: brightness ramp with optional color, sized to the cell rectangle.
- Golden-output tests (escape-sequence output for a known frame) and a benchmark step.

## Out of scope
- The game loop (item 05).
- Sixel / iTerm2 (item 17).
- Multi-instance layout (item 14), though the interface takes a cell rectangle so a grid can use it.

## Acceptance sketch
- Each backend's output for the test core's frame matches its golden file.
- Detection selects the expected backend in kitty, Ghostty, WezTerm, Rex, and a plain truecolor terminal.
- Benchmark numbers meet the targets set by item 02.
- Leaving the renderer (normal exit or a crash handler) deletes kitty images and restores the terminal.

## Depends on
- [02](./02-spike-terminal-graphics.md) — transport and default choices.
- [03](./03-libretro-host-and-test-core.md) — frames from the test core.

## Open questions for the cycle's interview
- Aspect-ratio handling: letterbox inside the cell rectangle? Integer scaling for half-block?
- How should detection results be cached or overridden per terminal in config later (item 10)?
- Golden tests: compare escape-sequence bytes, or decode them back to pixels?
- How to clean up the terminal reliably after a crash or SIGKILL, including on Windows?
