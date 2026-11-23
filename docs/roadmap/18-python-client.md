# 18 · Python client

> Seed prompt for `/spec-and-dev docs/roadmap/18-python-client.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **later**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Python programs, especially RL agents, can drive temui instances, with an optional Gym-style environment.

## Context
- D6 — the client speaks the NDJSON control protocol, including frame-numbered inputs and shared-memory frame grabs.
- Project-wide: Python wrappers are backlog items built on the control protocol, not linked into temui.

## In scope
- A pure-Python package (no compiled extension) wrapping spawn, step, input, frame grab, RAM read/write, and save/load state.
- Frames as NumPy arrays via shared memory.
- An optional Gymnasium environment wrapper.
- Examples and tests against the test core.

## Out of scope
- Training algorithms.
- A C-ABI library (item 19).

## Acceptance sketch
- A Gym environment steps a headless instance deterministically: the same seed and actions give the same observations.
- Steps per second are measured and documented.

## Depends on
- [12](./12-control-protocol-and-registry.md) — control protocol.

## Open questions for the cycle's interview
- Package name and where it lives (this repo or a separate one)?
- Python version floor and packaging tool (uv)?
- Is NumPy a hard dependency?
