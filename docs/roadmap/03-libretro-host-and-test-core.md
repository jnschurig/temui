# 03 · libretro host and test core

> Seed prompt for `/spec-and-dev docs/roadmap/03-libretro-host-and-test-core.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Load a libretro core at runtime, run it headless, and get correct pixels out. Also build the in-repo test core that every later test uses.

## Context
- D3 — runtime loading through `std.DynLib`; software framebuffer only (0RGB1555, RGB565, XRGB8888); no hardware-rendered cores.
- D14 — a tiny, permissively licensed test core written in Zig, so CI never downloads anything.
- D5 — one instance per process; the host is an engine library used later by `play`, `run`, and the control socket.

## In scope
- Test core (Zig, built as a shared library by `zig build`): deterministic pattern video in each of the three pixel formats, a sine tone, input echoed to the screen, SRAM via `retro_get_memory_data`, `retro_serialize`/`unserialize`.
- Host: load a core by path; resolve the `retro_*` symbols; implement a minimal set of environment callbacks (pixel format, system/save directories, variables, log interface, input descriptors); load a ROM; run N frames.
- Pixel-format conversion from the three formats to one internal RGB format, with unit tests.
- `temui run --headless --core <path> --rom <path> --frames N --dump-ppm <dir>`.

## Out of scope
- Rendering to the terminal (item 04).
- Timing and pacing (item 05).
- Downloading cores (item 07).
- Audio output (item 09; buffer audio samples but don't play them).

## Acceptance sketch
- The test core runs N frames headless and the dumped PPM matches a committed golden image byte for byte.
- Pixel-format conversion unit tests pass for all three formats.
- Manual check: a real nightly snes9x core, given by local path, runs a ROM headless and dumps sensible frames.
- An unknown environment callback is logged once and returns false rather than crashing.

## Depends on
- [01](./01-scaffold.md) — build, logging, CI.

## Open questions for the cycle's interview
- Which environment callbacks does each initial real core (snes9x, fceumm, gambatte) actually require?
- Internal pixel format: XRGB8888, RGB888, or RGBA8888 (what the renderers want)?
- How should the test core be built and located in tests (build step output path)?
- How are core options (variables) exposed before item 10's config exists?
