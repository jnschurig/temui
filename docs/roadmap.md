# temui — Roadmap

Work items are listed in dependency order. Each is sized for one `/spec-and-dev` cycle and has a seed prompt in [`roadmap/`](roadmap/). Decisions are referenced by number (D1–D15) from [decisions.md](decisions.md).

## How to run an item

1. Read [decisions.md](decisions.md).
2. Pick the first item below whose status is ☐ and whose dependencies are all ☑.
3. Run `/spec-and-dev docs/roadmap/NN-slug.md`. The seed becomes the starting prompt for Phase 1, and its open questions drive the requirements interview.
4. When the cycle finishes, change the item's status here from ☐ to ☑ (and add the date). If the cycle changed a decision, update `decisions.md` in the same commit.

Spike items (02, and the spikes inside 07, 12 and 15) exist to retire risks before the work that depends on them. Their output can change a decision; if it does, amend `decisions.md` before starting the dependent item.

## Overview

| # | Item | Tier | Depends on | Status |
|---|---|---|---|---|
| 01 | [Scaffold and build matrix](roadmap/01-scaffold.md) | MVP | — | ☐ |
| 02 | [Spike: terminal graphics throughput](roadmap/02-spike-terminal-graphics.md) | MVP | 01 | ☐ |
| 03 | [libretro host and test core](roadmap/03-libretro-host-and-test-core.md) | MVP | 01 | ☐ |
| 04 | [Renderers](roadmap/04-renderers.md) | MVP | 02, 03 | ☐ |
| 05 | [Play loop](roadmap/05-play-loop.md) | MVP | 03, 04 | ☐ |
| 06 | [Keyboard input and modes](roadmap/06-keyboard-input-and-modes.md) | MVP | 05 | ☐ |
| 07 | [Core acquisition](roadmap/07-core-acquisition.md) | MVP | 01, 03 | ☐ |
| 08 | [TUI shell and ROM browser](roadmap/08-tui-shell-and-rom-browser.md) | MVP | 05, 06, 07 | ☐ |
| 09 | [Audio](roadmap/09-audio.md) | MVP | 05 | ☐ |
| 10 | [Persistence and config](roadmap/10-persistence-and-config.md) | MVP | 05, 06, 08 | ☐ |
| 11 | [Game control mapping](roadmap/11-game-control-mapping.md) | MVP | 06, 10 | ☐ |
| 12 | [Control protocol and registry](roadmap/12-control-protocol-and-registry.md) | next | 05 | ☐ |
| 13 | [Attach / detach viewer](roadmap/13-attach-detach-viewer.md) | next | 09, 12 | ☐ |
| 14 | [Grid and command palette](roadmap/14-grid-and-command-palette.md) | next | 08, 12, 13 | ☐ |
| 15 | [Gamepad](roadmap/15-gamepad.md) | next | 11 | ☐ |
| 16 | [Release pipeline](roadmap/16-release-pipeline.md) | next | 01 | ☐ |
| 17 | [Sixel renderer](roadmap/17-sixel-renderer.md) | later | 04 | ☐ |
| 18 | [Python client](roadmap/18-python-client.md) | later | 12 | ☐ |
| 19 | [libtemui embed](roadmap/19-libtemui-embed.md) | later | 12 | ☐ |
| 20 | [Packaging](roadmap/20-packaging.md) | later | 16 | ☐ |
| 21 | [More systems](roadmap/21-more-systems.md) | later | 03, 07, 11 | ☐ |
| 22 | [Multi-instance input broadcast](roadmap/22-multi-instance-input-broadcast.md) | later | 12, 13, 14 | ☐ |

---

## MVP — playable SNES / NES / GB in a terminal

### 01 · Scaffold and build matrix
- **Goal:** a repo that builds an empty `temui` binary for all six targets and runs tests in CI.
- **Scope:** `mise.toml` (Zig 0.17.1); `build.zig` + `build.zig.zon` with the 6-target matrix (glibc 2.28, `win10_rs4`); vendored `libretro.h`; file logging with `--verbose`; GitHub Actions using mise-action that cross-compiles every target and runs `zig build test` on native runners; `.gitignore`.
- **Decisions:** D1, D2, D12, D13, D14.
- **Acceptance sketch:** `mise install && zig build` succeeds locally. CI is green, with artifacts for all six targets. `temui --version` runs. Logs go to the platform log path, never to stdout.
- **Seed:** [roadmap/01-scaffold.md](roadmap/01-scaffold.md)

### 02 · Spike: terminal graphics throughput
- **Goal:** numbers that confirm or revise D7 before the renderers are built.
- **Scope:** a throwaway benchmark of kitty graphics (inline, inline+zlib, temp file, shared memory) and half-block at 60 fps in Ghostty, kitty, WezTerm and Rex. Prototype terminal capability detection.
- **Decisions:** D7, D9 (keyboard-protocol detection).
- **Acceptance sketch:** a results table (fps achieved, CPU, bytes/s per terminal × transport) in `docs/spikes/02-terminal-graphics.md`, and a recommended default renderer per terminal. `decisions.md` is amended if the results disagree with D7.
- **Seed:** [roadmap/02-spike-terminal-graphics.md](roadmap/02-spike-terminal-graphics.md)

### 03 · libretro host and test core
- **Goal:** load a core, run it headless, and get correct pixels out.
- **Scope:** a Zig test core (pattern video, a tone, echoed input, SRAM, serialize); the host (`std.DynLib` load, a minimal set of environment callbacks, conversion of the three pixel formats); `temui run --headless --frames N --dump-ppm`.
- **Decisions:** D3, D14.
- **Acceptance sketch:** the test core runs N frames and its PPM matches a golden image. Pixel-format unit tests pass. A real nightly snes9x core, loaded by local path, runs a ROM headless.
- **Seed:** [roadmap/03-libretro-host-and-test-core.md](roadmap/03-libretro-host-and-test-core.md)

### 04 · Renderers
- **Goal:** the production renderer interface with three backends.
- **Scope:** the renderer interface; automatic detection plus an override flag; kitty graphics (shared memory → file → inline); half-block that redraws only changed cells; ASCII. Golden-image tests and a throughput benchmark per renderer.
- **Decisions:** D7, D14.
- **Acceptance sketch:** each backend renders the test core correctly (golden output). Detection picks the expected backend in each tier-1 terminal. The benchmark meets the targets set by 02.
- **Seed:** [roadmap/04-renderers.md](roadmap/04-renderers.md)

### 05 · Play loop
- **Goal:** `temui play <rom> --core <path>` shows a running game.
- **Scope:** wall-clock pacing; pause / fast-forward / slow motion / step; presentation decoupled from emulation (frameskip, per-viewer fps); resize handling; the stats overlay. No control socket yet (that comes in 12).
- **Decisions:** D5, D8, D13.
- **Acceptance sketch:** the test core holds 60.0 emulated fps at 1×. N× speed and unthrottled mode work. The overlay shows emulated fps, presented fps and bytes/s. Resizing the terminal doesn't crash or corrupt the display.
- **Seed:** [roadmap/05-play-loop.md](roadmap/05-play-loop.md)

### 06 · Keyboard input and modes
- **Goal:** play with the keyboard, and switch between game mode and TUI mode.
- **Scope:** the kitty keyboard protocol; Windows console input; timeout-based key-release fallback with a warning; the leader key (Esc with the kitty protocol, a configurable Ctrl key otherwise); hardcoded default game bindings (replaced in 11).
- **Decisions:** D9, D15.
- **Acceptance sketch:** held keys register as held in a game. The leader key enters TUI mode and returns to game mode. The fallback warning appears when key releases aren't reported.
- **Seed:** [roadmap/06-keyboard-input-and-modes.md](roadmap/06-keyboard-input-and-modes.md)

### 07 · Core acquisition
- **Goal:** `temui core install snes` fetches a working core.
- **Scope:** per-core zips from the nightly buildbot over std TLS; `std.zip` extraction; per-user cache; pinning on first download and `core update`; investigating `.sig` verification; the system→core map; `temui core install/list/update`; the local-path override; a clear message on windows-aarch64.
- **Decisions:** D2, D4.
- **Acceptance sketch:** install works on macOS, Linux and Windows CI runners (TLS certificates verified on each). A second install is a no-op. A changed upstream file requires `core update`. The `.sig` outcome is recorded in `decisions.md`.
- **Seed:** [roadmap/07-core-acquisition.md](roadmap/07-core-acquisition.md)

### 08 · TUI shell and ROM browser
- **Goal:** `temui` with no arguments opens a browser and launches games.
- **Scope:** the TUI shell; vim-style navigation; the `?` help overlay; `/` search; browsing the configured ROM directories; launching a ROM with its mapped core (installing the core if missing).
- **Decisions:** D15, D4.
- **Acceptance sketch:** pick a ROM with `j`/`k` and Enter, play it, press the leader key, and return to the browser. Search filters the list as you type. `?` lists the key bindings.
- **Seed:** [roadmap/08-tui-shell-and-rom-browser.md](roadmap/08-tui-shell-and-rom-browser.md)

### 09 · Audio
- **Goal:** sound at 1×, with audio-paced timing.
- **Scope:** miniaudio; resampling to the device rate; audio paces the loop at 1×; muted at other speeds; falls back to wall-clock pacing when no device is available.
- **Decisions:** D8, D10.
- **Acceptance sketch:** the test core's tone plays without crackle for 10 minutes. Switching speed mutes and unmutes audio cleanly. Headless runs are silent.
- **Seed:** [roadmap/09-audio.md](roadmap/09-audio.md)

### 10 · Persistence and config
- **Goal:** saves survive restarts, and settings live in a config file.
- **Scope:** SRAM autosave (atomic writes); save-state slots; platform config paths; choosing the config format; ROM directories, leader key and renderer override in config.
- **Decisions:** D11, D15.
- **Acceptance sketch:** killing the process mid-game loses no more than the autosave interval. Slots save and load. The config is read from the standard path on each OS.
- **Seed:** [roadmap/10-persistence-and-config.md](roadmap/10-persistence-and-config.md)

### 11 · Game control mapping
- **Goal:** sensible per-system keyboard controls that users can remap.
- **Scope:** per-system default keyboard → RetroPad maps; a remapping UI in TUI mode; mappings stored in config. Designed to take gamepad mappings in 15.
- **Decisions:** D9, D15, D11.
- **Acceptance sketch:** SNES, NES and GB each have defaults. A remap made in the UI persists across restarts. The hardcoded bindings from 06 are gone.
- **Seed:** [roadmap/11-game-control-mapping.md](roadmap/11-game-control-mapping.md)

## Next — headless, multi-instance, gamepads, releases

### 12 · Control protocol and registry
- **Goal:** scripts and agents can drive instances.
- **Scope:** socket server; NDJSON v1; registry with 0700/0600 permissions and liveness checks; `run --detach`, `ls`, `ctl`; frame-numbered inputs; frame grab over shared memory. Includes the Windows AF_UNIX spike (fallback: named pipes).
- **Decisions:** D5, D6.
- **Acceptance sketch:** a scripted step/input sequence replays to identical frames. `ls` shows live instances and removes stale ones. Another user cannot connect. CI passes on Windows.
- **Seed:** [roadmap/12-control-protocol-and-registry.md](roadmap/12-control-protocol-and-registry.md)

### 13 · Attach / detach viewer
- **Goal:** watch and control a headless instance, then leave it running.
- **Scope:** `temui attach`; per-viewer fps; speed control; `--audio` handoff; input forwarding; detaching without killing the instance.
- **Decisions:** D5, D6, D8, D10.
- **Acceptance sketch:** attach to a `run --detach` instance, play, detach, and reattach; the game state persists. Two viewers at different fps rates work at the same time.
- **Seed:** [roadmap/13-attach-detach-viewer.md](roadmap/13-attach-detach-viewer.md)

### 14 · Grid and command palette
- **Goal:** see many instances at once, and do anything `ctl` can from the TUI.
- **Scope:** tiled multi-instance view; a command palette that sends the same commands as `ctl`; instances spawned from outside appear live.
- **Decisions:** D5, D6, D7 (ASCII for dense grids), D15.
- **Acceptance sketch:** a 3×3 grid stays responsive. An instance spawned by `ctl` appears without a refresh. Every palette command has a `ctl` equivalent.
- **Seed:** [roadmap/14-grid-and-command-palette.md](roadmap/14-grid-and-command-palette.md)

### 15 · Gamepad
- **Goal:** play with a controller.
- **Scope:** SDL3 built statically with only the gamepad subsystem on all six targets (spike first); gamepad mappings added to 11's mapping system; hotplug.
- **Decisions:** D1, D9.
- **Acceptance sketch:** all six targets still cross-compile. A connected controller plays a game, and unplugging and replugging it works.
- **Seed:** [roadmap/15-gamepad.md](roadmap/15-gamepad.md)

### 16 · Release pipeline
- **Goal:** tagged releases users can download.
- **Scope:** pushing a tag publishes a GitHub Release with six archives and checksums; install docs; a note on macOS quarantine.
- **Decisions:** D12, D2.
- **Acceptance sketch:** pushing `v0.1.0` produces a release whose checksums verify, and the downloaded binary runs on macOS and Linux.
- **Seed:** [roadmap/16-release-pipeline.md](roadmap/16-release-pipeline.md)

## Later

### 17 · Sixel renderer
- **Goal:** graphics in Windows Terminal, foot and xterm. **Decisions:** D7. **Acceptance sketch:** a sixel backend passes golden tests and is detected automatically. **Seed:** [roadmap/17-sixel-renderer.md](roadmap/17-sixel-renderer.md)

### 18 · Python client
- **Goal:** a Python client over the control protocol, plus an optional Gym wrapper. **Decisions:** D6. **Acceptance sketch:** a Gym env steps a headless instance deterministically. **Seed:** [roadmap/18-python-client.md](roadmap/18-python-client.md)

### 19 · libtemui embed
- **Goal:** the engine as a C-ABI library. **Decisions:** D5, D6. **Acceptance sketch:** a C program links libtemui and steps a core. **Seed:** [roadmap/19-libtemui-embed.md](roadmap/19-libtemui-embed.md)

### 20 · Packaging
- **Goal:** Homebrew, Scoop, and macOS signing/notarization. **Decisions:** D12. **Acceptance sketch:** `brew install` and `scoop install` work; a notarized binary passes Gatekeeper. **Seed:** [roadmap/20-packaging.md](roadmap/20-packaging.md)

### 21 · More systems
- **Goal:** GBA, Genesis, and software-rendered PS1 (handling BIOS files). **Decisions:** D3, D4. **Acceptance sketch:** each system has a mapped core, default controls, and BIOS handling where needed. **Seed:** [roadmap/21-more-systems.md](roadmap/21-more-systems.md)

### 22 · Multi-instance input broadcast
- **Goal:** game mode attached to N selected instances, sending each input to all of them at once. **Decisions:** D6, D15. **Acceptance sketch:** one keypress reaches every instance in the group, and the group is visible in the grid. **Seed:** [roadmap/22-multi-instance-input-broadcast.md](roadmap/22-multi-instance-input-broadcast.md)
