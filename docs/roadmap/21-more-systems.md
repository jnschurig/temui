# 21 · More systems

> Seed prompt for `/spec-and-dev docs/roadmap/21-more-systems.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **later**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Support GBA, Genesis and software-rendered PS1, including BIOS file handling.

## Context
- D3 — software framebuffer only; PS1 must use a software-rendering core.
- D4 — the system→core map and buildbot availability per target.

## In scope
- Choose cores per system and check buildbot availability on every target (e.g. mGBA, Genesis Plus GX, a software PS1 core).
- Extend the system→core map and ROM-extension detection.
- BIOS handling: where users put BIOS files, validating hashes, clear errors when missing.
- Default control mappings for each new system (item 11's system).

## Out of scope
- Hardware-rendered cores (project-wide out of scope).
- Disc-image formats beyond what the chosen PS1 core reads natively.

## Acceptance sketch
- Each new system has a mapped core, default controls, and plays a test ROM.
- A missing or wrong BIOS produces a clear message naming the expected file and hash.

## Depends on
- [03](./03-libretro-host-and-test-core.md) — core host.
- [07](./07-core-acquisition.md) — core acquisition.
- [11](./11-game-control-mapping.md) — control mapping.

## Open questions for the cycle's interview
- Which cores, given license, accuracy, and buildbot availability on aarch64?
- Multi-disc PS1 games (m3u)?
- Analog stick mapping for PS1 on keyboard?
