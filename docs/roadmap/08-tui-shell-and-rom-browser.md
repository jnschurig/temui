# 08 · TUI shell and ROM browser

> Seed prompt for `/spec-and-dev docs/roadmap/08-tui-shell-and-rom-browser.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Running `temui` with no arguments opens a TUI that browses the user's ROMs and launches them, with vim-style navigation.

## Context
- D15 — TUI mode keys (`h`/`j`/`k`/`l`, `?`, `/`, Enter, arrows); `temui` with no arguments opens the ROM browser.
- D4 — launching a ROM uses the system→core map and installs the core if missing.

## In scope
- The TUI shell framework (screen layout, key dispatch, redraw) that later items extend (grid, palette, remapping).
- ROM browser over configured ROM directories (a flag or env var until item 10's config exists), grouped or filtered by system based on file extension.
- `/` incremental search; `?` help overlay listing current bindings.
- Launching a ROM: resolve the system and core, install the core if needed, enter game mode; the leader key returns to the browser.
- Status line showing the current mode.

## Out of scope
- Config file (item 10).
- Multi-instance grid and command palette (item 14).
- Box art and metadata scraping (project-wide out of scope).

## Acceptance sketch
- `temui` lists ROMs from the configured directories; `j`/`k` and arrows move; Enter launches.
- `/` filters as you type; Esc or Enter leaves search.
- `?` shows the help overlay.
- From a game, the leader key returns to the browser with the selection preserved.

## Depends on
- [05](./05-play-loop.md) — play loop.
- [06](./06-keyboard-input-and-modes.md) — modes and the leader key.
- [07](./07-core-acquisition.md) — core lookup and install.

## Open questions for the cycle's interview
- Does returning to the browser stop the game, or keep it running in the background?
- System detection: by extension only, or also by header? How to handle `.zip`'d ROMs?
- Is a recent/favorites list part of this item or later?
- Build the TUI framework in-house, or adopt a small Zig TUI library (license and dependency policy)?
