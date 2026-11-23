# 19 · libtemui embed

> Seed prompt for `/spec-and-dev docs/roadmap/19-libtemui-embed.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **later**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Expose the engine as a C-ABI library so other programs can embed temui directly instead of going through the socket.

## Context
- D5 — the engine is already a library internally.
- D6 — the library's API should mirror the protocol's command set.
- Project-wide: libtemui is a backlog item, not part of the MVP.

## In scope
- A C header and shared/static library built by `zig build`.
- API: create instance, load core and ROM, step, set input, get frame, save/load state, read/write RAM.
- A C example and tests.

## Out of scope
- Language bindings other than C.

## Acceptance sketch
- A C program links libtemui and steps the test core.
- The library builds for all six targets.

## Depends on
- [12](./12-control-protocol-and-registry.md) — the command set the API mirrors.

## Open questions for the cycle's interview
- Library license implications (still MIT; cores remain separate)?
- Threading model: may callers drive instances from several threads?
- API and ABI stability guarantees?
