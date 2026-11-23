# 02 · Spike: terminal graphics throughput

> Seed prompt for `/spec-and-dev docs/roadmap/02-spike-terminal-graphics.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Measure, before building production renderers, how fast each terminal can display 60 fps game frames with each transport, and how reliably temui can detect terminal capabilities. The code is throwaway; the numbers are the deliverable.

## Context
- D7 — the renderer design this spike confirms or revises (kitty graphics with shared memory → file → inline+zlib fallback; half-block; ASCII).
- D9 — kitty keyboard protocol detection is prototyped here too.
- Known risk: Rex supports kitty graphics (including file and shared-memory transport), but there are open reports of much lower frame rates than kitty or Ghostty, high CPU on large animation frames, and inline images ≥10 MB being dropped.

## In scope
- A benchmark binary (in the repo, behind a build step, or in a `spikes/` dir) that pushes synthetic 256×224 and 320×240 frames at 60 fps.
- Transports: kitty inline (raw RGB/RGBA), inline + zlib (`o=z`), temp file (`t=t`), shared memory (`t=s`); half-block truecolor with full redraw vs. changed cells only.
- Terminals: kitty, Ghostty, WezTerm, Rex (local); optionally Rex or kitty over SSH, and tmux with passthrough.
- Measure achieved presented fps, temui CPU, terminal CPU, and bytes/s written.
- Prototype detection: kitty graphics query (`a=q`), kitty keyboard query (`CSI ? u`), truecolor (`COLORTERM`, DECRQSS), cell pixel size (`CSI 14 t` / `16 t`), with a timeout.

## Out of scope
- Production renderer code (item 04).
- Sixel and iTerm2 (item 17).
- Windows Terminal (no kitty graphics; half-block only).

## Acceptance sketch
- `docs/spikes/02-terminal-graphics.md` holds a results table: terminal × transport → fps, CPU, bytes/s.
- A recommended default renderer and transport per terminal, including Rex.
- Detection notes: which queries each terminal answers, and the timeout needed.
- If the results disagree with D7, `docs/decisions.md` is amended in the same cycle.

## Depends on
- [01](./01-scaffold.md) — build setup and CI.

## Open questions for the cycle's interview
- Is 60 fps the bar, or is 30 fps acceptable for some transports or terminals?
- Which machine(s) to measure on, and how to measure terminal CPU repeatably?
- Should the benchmark binary be kept as a permanent tool, or deleted after the spike?
- If Rex is much slower with kitty graphics, should half-block be Rex's default, or should temui present at a lower rate there?
