# 10 · Persistence and config

> Seed prompt for `/spec-and-dev docs/roadmap/10-persistence-and-config.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Game saves survive restarts, save states work, and settings live in a config file in the platform's standard location.

## Context
- D11 — SRAM autosave; numbered save-state slots; platform config paths; the config format is chosen in this cycle.
- D15 — the leader key is configurable.
- D7 — per-terminal renderer override belongs in config.

## In scope
- SRAM load on start and autosave (on an interval and on exit), written atomically (temp file + rename).
- Save-state slots: save, load, select slot; files named per ROM and slot.
- Platform paths: XDG on Linux, Application Support on macOS, AppData on Windows; for config, saves, and states.
- Choose the config format and write the loader with validation and clear error messages.
- Config keys: ROM directories, leader key, renderer override, default speed and presentation fps, log level.

## Out of scope
- Control mappings in config (item 11, which builds on this loader).
- Cloud sync.
- Rewind (project-wide out of scope).

## Acceptance sketch
- Killing the process mid-game loses at most one autosave interval of SRAM; the save file is never left corrupted.
- States save and load in every slot, and survive a restart.
- Config is read from the standard path on each OS; an invalid config produces a clear error with the file and line.
- ROM directories from config appear in the browser.

## Depends on
- [05](./05-play-loop.md) — the running game and core host.
- [06](./06-keyboard-input-and-modes.md) — the leader key.
- [08](./08-tui-shell-and-rom-browser.md) — the ROM browser that reads ROM directories.

## Open questions for the cycle's interview
- Config format: ZON, TOML (needs a parser), or JSON? Trade-offs: comments, std support, user familiarity.
- Autosave interval, and whether to keep a backup of the previous SRAM file.
- Save-state format: raw `retro_serialize` output plus a header (core name, version, ROM hash)? Thumbnails?
- Should save files live next to ROMs as an option?
