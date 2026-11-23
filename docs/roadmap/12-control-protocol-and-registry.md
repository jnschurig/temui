# 12 · Control protocol and registry

> Seed prompt for `/spec-and-dev docs/roadmap/12-control-protocol-and-registry.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **next**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Instances can be started headless, discovered, and driven by scripts and agents over a local socket, deterministically.

## Context
- D5 — one process per instance; self-registration in a per-user runtime directory (dir 0700, sockets 0600); liveness checks; no daemon.
- D6 — versioned NDJSON over AF_UNIX; command set; frame-numbered inputs; frame pixels over shared memory for local clients; the TUI and `ctl` send the same commands.
- D2 — Windows targets require `win10_rs4`; Zig 0.17.1 std implements Windows AF_UNIX via AFD (verified in source on 2026-11-23) but it has not been exercised at runtime.

## In scope
- Spike first: AF_UNIX listen/connect on Windows from Zig std on a CI runner; fall back to named pipes only if it fails.
- Protocol v1: message framing, request ids, errors, a version handshake, and the D6 command set (spawn, list, attach/detach, kill, pause/resume/step N, set speed, set input, save/load state, read/write RAM, grab frame, set viewer fps).
- Socket server in every instance, including `temui play` (retrofitting the deferred socket).
- Registry: runtime dir per OS, metadata file per instance, liveness check, stale-entry cleanup.
- `temui run --detach`, `temui ls`, `temui ctl <instance> <command>`.
- Frame-numbered input queue; frame grab via shared memory (`shm_open` / `CreateFileMapping`), with an inline fallback.
- Protocol encoding tests and a determinism test (same inputs → same frames).

## Out of scope
- Viewer attach UI (item 13).
- Grid and palette (item 14).
- TCP or remote control (project-wide out of scope).
- Python client (item 18).

## Acceptance sketch
- A script runs `run --detach`, steps 1000 frames with inputs, grabs frames, and gets identical results on a rerun.
- `ls` lists live instances and removes entries for killed ones.
- Another OS user cannot connect (permission test on POSIX).
- The protocol works on Windows CI.
- The protocol is documented in `docs/protocol.md`.

## Depends on
- [05](./05-play-loop.md) — the engine loop to control.

## Open questions for the cycle's interview
- Runtime dir per OS, and handling Unix socket path-length limits (~104 bytes on macOS)?
- Compatibility policy: how do clients and instances of different versions behave?
- RAM access addressing: libretro memory ids, memory maps, or both?
- Shared-memory lifetime and cleanup after crashes?
- Should `spawn` be served by an instance (forking a sibling) or only by the CLI?
