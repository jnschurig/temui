# 06 · Keyboard input and modes

> Seed prompt for `/spec-and-dev docs/roadmap/06-keyboard-input-and-modes.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Play games with the keyboard, with correct press and release handling, and switch between game mode and TUI mode with a leader key.

## Context
- D9 — kitty keyboard protocol where available; Windows console input API; timeout-guessed releases with a visible warning otherwise.
- D15 — modal interaction; the leader key is Esc when the kitty keyboard protocol is active, otherwise a configurable Ctrl key.

## In scope
- Enable, parse, and disable the kitty keyboard protocol (press/repeat/release, with the flags needed).
- Windows console input (`ReadConsoleInputW` key events).
- Legacy fallback: parse plain terminal input; guess key releases by timeout; show a warning in the overlay or status line.
- Game mode / TUI mode switch with the leader key; TUI mode is a minimal placeholder until item 08.
- **Hardcoded default game bindings** (keyboard → RetroPad) for SNES, NES and GB. Item 11 replaces them with configurable mapping.

## Out of scope
- Configurable game bindings and a remapping UI (item 11).
- Gamepads (item 15).
- The ROM browser and full TUI shell (item 08).

## Acceptance sketch
- In kitty, Ghostty, WezTerm and Rex, holding a direction key moves continuously and releasing it stops immediately.
- On Windows, the console input path does the same.
- In a terminal without the protocol, play works with guessed releases and the warning is shown.
- The leader key enters TUI mode and pauses or keeps running per the chosen behavior; pressing it again (or a documented key) returns to the game.

## Depends on
- [05](./05-play-loop.md) — the play loop that consumes input.

## Open questions for the cycle's interview
- Default fallback leader key: which Ctrl chord avoids clashes with shells, tmux (`C-b`), and screen (`C-a`)?
- Does entering TUI mode pause the game?
- Release-guess timeout value, and should it adapt to the terminal's key-repeat rate?
- How should keys pressed while switching modes be handled (avoid stuck keys)?
