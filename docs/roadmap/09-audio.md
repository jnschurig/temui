# 09 · Audio

> Seed prompt for `/spec-and-dev docs/roadmap/09-audio.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Games have sound, and at 1× speed the audio device paces emulation.

## Context
- D10 — miniaudio; resample to the device rate; one audible process; headless is silent; muted at non-1× speeds; over SSH audio plays on the remote host.
- D8 — at 1×, audio paces the loop in the process playing audio; otherwise wall-clock.

## In scope
- Vendor miniaudio and compile it in via `zig build` on all six targets.
- Ring buffer between the core's `audio_sample_batch` and the device callback.
- Resampling from the core's rate to the device rate.
- Pacing at 1× from the audio buffer's fill level; fall back to wall-clock when no device is available.
- Mute and unmute on speed changes, pause, and mode switches.

## Out of scope
- `--audio` handoff between processes (item 13).
- Pitch-preserving fast-forward.
- Audio over SSH to the local machine.

## Acceptance sketch
- The test core's tone plays for 10 minutes without crackle or drift.
- A real SNES game's audio sounds correct.
- Switching to 2× mutes; returning to 1× unmutes without a pop.
- Headless runs and machines with no audio device run normally.
- All six targets still cross-compile.

## Depends on
- [05](./05-play-loop.md) — the play loop and pacing hooks.

## Open questions for the cycle's interview
- Which resampler (miniaudio's built-in linear, or something better)?
- Target audio latency and buffer size?
- Dynamic rate control if the core's reported fps and the audio rate drift apart?
