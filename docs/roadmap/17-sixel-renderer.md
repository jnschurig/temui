# 17 · Sixel renderer

> Seed prompt for `/spec-and-dev docs/roadmap/17-sixel-renderer.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **later**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Show real graphics in terminals that support sixel but not kitty graphics, such as Windows Terminal, foot and xterm.

## Context
- D7 — sixel was deferred; it plugs into the renderer interface from item 04.
- Terminal tiers: this moves Windows Terminal, foot and xterm up from half-block.

## In scope
- Sixel encoder with palette quantization fast enough for game frames.
- Detection (DA1 response) and the `--renderer sixel` override.
- Golden tests and a benchmark.

## Out of scope
- iTerm2 inline images (could be a follow-up item).

## Acceptance sketch
- The sixel backend passes golden tests.
- It is detected automatically in Windows Terminal and foot.
- The benchmark shows an acceptable frame rate (target set during the cycle).

## Depends on
- [04](./04-renderers.md) — the renderer interface.

## Open questions for the cycle's interview
- Palette size and quantization method (fixed palette vs. per-frame)?
- Should iTerm2 be included in the same cycle?
