# temui

A single-binary, dependency-free, terminal-based [libretro](https://www.libretro.com/) frontend, written in Zig.

- Play SNES, NES and Game Boy games in your terminal, using kitty graphics where the terminal supports it and half-block or ASCII rendering everywhere else.
- Run headless instances that can be attached, detached, sped up, slowed down, and scripted by bots and agents over a local control socket.

The name combines **TUI** (terminal user interface) and **emu** (emulator).

## About

This section describes the design; see [Status](#status) for what works today.

temui is an emulator frontend: it doesn't emulate consoles itself. It loads [libretro cores](https://docs.libretro.com/guides/core-list/) (the emulators that RetroArch also uses) at runtime and drives them through the libretro C API. On first use it downloads the core it needs from the libretro buildbot, then keeps that version until you update it explicitly.

Everything else happens in the terminal:

- **Video:** each frame is drawn with the best method the terminal supports: kitty graphics, Unicode half-blocks, or ASCII. The method is chosen automatically and can be overridden.
- **Input:** the keyboard (via the kitty keyboard protocol where available, or the Windows console) and gamepads.
- **Audio:** audio plays through the system's sound output, with no extra libraries to install.
- **Modes:** in game mode, every key goes to the game. A mode key switches to TUI mode, which uses vim-style keys and a Space-leader menu. Running `temui` with no arguments opens a searchable ROM browser.
- **Instances:** each game runs as its own process, either in your terminal or headless in the background, and you can attach to it later. There is no daemon. Scripts and AI agents can drive any instance through a versioned JSON protocol over a local socket.

It ships as one binary for Linux, macOS and Windows on x86_64 and aarch64, with nothing else to install.

## Status

Pre-alpha: temui can play a game in the terminal with the keyboard, using a core you supply (see [Playing a game](#playing-a-game)). There is no audio or saving yet, and cores aren't downloaded for you. It can also run a core headless and dump frames to image files (see [Running a core headless](#running-a-core-headless)).

- [Architecture decisions](docs/decisions.md): what was chosen and why (D1–D15).
- [Roadmap](docs/roadmap.md): ordered work items, each with a seed prompt in [`docs/roadmap/`](docs/roadmap/).

## Building

The Zig version is pinned in [`mise.toml`](mise.toml); install it with [mise](https://mise.jdx.dev/).

```sh
mise install                              # install the pinned Zig
zig build                                 # native binary: zig-out/bin/temui
zig build test                            # unit tests
zig build cross -Doptimize=ReleaseSafe    # all six targets: zig-out/<os>-<arch>/
zig build bench                           # renderer benchmarks: zig-out/bin/temui-bench
```

`temui-bench encode` times each renderer backend without a terminal; `temui-bench live` draws in the current terminal at a paced 60 fps and reports frame rate, frame-interval p99 and CPU (`temui-bench --help`).

## Playing a game

`temui play` loads a core and a ROM and draws the game in the current terminal, using the renderer `temui detect` would pick. Emulation is paced to the core's frame rate by a wall-clock timer; drawing is decoupled from it, so at high speed temui emulates every frame but draws at most `--present-fps` of them.

```sh
temui play game.sfc --core snes9x_libretro.dylib
temui play game.sfc --core snes9x_libretro.dylib --speed 4 --present-fps 30 --overlay
temui play testdata/testcore.rom --core zig-out/lib/temui_test_libretro.dylib --renderer halfblock
```

| Option | |
| --- | --- |
| `--core <path>` | The libretro core to load (required) |
| `--speed <x>` | Starting speed: a multiple such as `0.25` or `4`, or `max` for unthrottled (default 1) |
| `--present-fps <f>` | Draw at most `<f>` frames per second (default: the core's fps) |
| `--overlay` | Start with the detailed stats in the status line: presented fps, bytes/s, encode and write time per second, and lag |
| `--paused` | Start paused, showing the first frame |
| `--duration <s>` | Quit after `<s>` seconds |
| `--renderer <name>` | `kitty`, `halfblock`, `ascii` or `auto` (default) |
| `--keyboard <mode>` | `auto` (default: the kitty keyboard protocol if the terminal reports it, else game input is disabled), `kitty` (push the protocol even if detection didn't see it) or `legacy` (game input without releases, for automation: see below). Ignored on Windows, which always uses console input |
| `--mode-key <chord>` | The chord that leaves game mode (default `ctrl-]`): `ctrl-a`…`ctrl-z`, `ctrl-]`, `ctrl-\` or `ctrl-^`, except `ctrl-c`, `ctrl-h`, `ctrl-i`, `ctrl-j` and `ctrl-m` |
| `--option`, `--system-dir`, `--save-dir` | As for `run` |

The bottom row is a status line: the mode (`GAME` or `TUI`, plus a flag: `LEGACY` with `--keyboard legacy`, or `GAME MODE DISABLED` in white on red), the ROM and core (or the detailed stats, toggled with `o`), and the emulated fps and speed.

### Keys

temui is modal, like vim. `play` starts in **game mode** (vim's insert mode), where keys go to the game. The **mode key** switches to **TUI mode** (normal mode), where the game keeps running and keys control temui. The mode key is Esc where the terminal reports key releases (the kitty keyboard protocol, the Windows console), and Ctrl-] everywhere. Esc only ever backs out one layer, so pressing it again is always safe.

Game mode, one RetroPad for SNES, NES and Game Boy alike (remapping arrives in roadmap 11):

| Key | RetroPad |
| --- | --- |
| `e` `s` `d` `f` | Up, Left, Down, Right |
| `l` `k` `i` `j` | A, B, X, Y (a SNES diamond: X top, Y left, B bottom, A right) |
| `a` `;` | L, R |
| `h` | Start |
| `g` | Select |

Keys are matched by the character they type, with Shift ignored, and never with Ctrl, Alt or Super held. On a non-US layout, Ctrl-] may be awkward to type or not reach the terminal at all: pick another chord with `--mode-key`.

TUI mode:

| Key | |
| --- | --- |
| `p` | Pause / resume |
| `.` | Step one frame (while paused) |
| `+` or `=`, `-`, `0` | Faster, slower, normal speed (0.25×, 0.5×, 1×, 2×, 4×, 8×, max) |
| `o` | Show / hide the detailed stats |
| `i`, Enter, the mode-key chord | Back to the game |
| Space | The leader menu: lists these keys and `q` quit; Space or Esc closes it |

Quitting always asks first, because nothing is saved yet: Space `q` then Enter, or Ctrl-C twice within 3 s from anywhere (the first shows a prompt; the game keeps running meanwhile). If temui stops responding (a core stuck in a loop, or a terminal that stopped reading), two Ctrl-Cs quit at once with exit code 130.

**Game input needs key releases.** Holding a button means knowing when the key goes up, and only the [kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) (Ghostty, kitty, WezTerm, Rex, foot) and the Windows console report releases. Elsewhere (tmux, Terminal.app, a terminal reached over a slow link) game input is **disabled**: `play` starts in TUI mode with a red `GAME MODE DISABLED` flag, and `i`, Enter and the mode key show a notice instead of entering game mode. Everything else (pause, speed, stats, the menu, quitting) works. If your terminal has the protocol but detection missed it, try `--keyboard kitty`. If the protocol stops working mid-game (keys start arriving without releases), temui releases every button, pauses, and says so in a box; it stays disabled for the rest of the run.

**`--keyboard legacy`** is for automation, such as scripted key presses into a pty: game input works without releases, each key press holding its button for a fixed 100 ms. To keep holding, resend the key within 100 ms (a held key's auto-repeat does this, but only for the last key pressed, and only after the repeat delay). A `LEGACY` flag shows in the status line. Esc isn't the mode key on this path; use Ctrl-].

**Pasting** does nothing on macOS and Linux: temui turns on bracketed paste and discards whatever is pasted, so pasted text never reads as key presses. On Windows a paste arrives as ordinary key events and does act on the game.

Holding and releasing keys was verified in Ghostty and Rex, and game input disabled in Terminal.app and under GNU screen ([results](docs/bench/06-keyboard.md)). kitty and WezTerm are covered by the protocol tests only.

On exit temui prints one summary line (`N frames in S s: emu X fps, presented Y fps`). Resizing the terminal refits the picture. Anything a core prints to stdout or stderr goes to the log (as `core: stdio: …`), never to the screen; snes9x, for example, prints `Map_HiROMMap` while loading a HiROM game. Pacing and decoupling were measured in Ghostty and Rex: see [the verification results](docs/bench/05-play-loop.md).

**Windows:** `play` is built and tested in CI only, not run in a real console. Pacing uses a high-resolution waitable timer, resizes come from console window events, and keys are read as console key events with real releases. Output that a core writes to stdout or stderr is **not** contained on Windows yet and can corrupt the display.

## Running a core headless

`temui run --headless` loads a core and a ROM, runs a fixed number of frames as fast as possible, and can write frames out as PPM images. It is a test harness for the libretro host, and you supply the core yourself.

```sh
temui run --headless --core snes9x_libretro.dylib --rom game.sfc --frames 600 \
    --dump-ppm frames/ --dump-every 60 --option snes9x_region=ntsc
```

It prints one summary line (core name and version, frames run, final geometry, pixel format). `temui --help` lists every option. `zig build` also builds a small test core, `zig-out/lib/temui_test_libretro.{dylib,so}` (`zig-out/bin/temui_test_libretro.dll` on Windows), which runs with `--rom testdata/testcore.rom`.

## Detecting the terminal

`temui detect` asks the terminal what it supports (kitty graphics and which of its transports work, truecolor, cell size) and prints the renderer temui would use: kitty graphics, half-block, or ASCII. `--json` prints the same as JSON. `--renderer kitty|halfblock|ascii|auto` overrides the choice (`detect` and `play` accept it).

```sh
temui detect
temui detect --json --renderer halfblock
```

The terminal is in raw mode only while the queries run (at most about a second, usually a millisecond). When stdin or stdout isn't a terminal, nothing is sent and `auto` picks ASCII without colour. Windows consoles aren't queried: temui uses half-block there.

If temui is killed with `SIGKILL` (`kill -9`) while it owns the screen, it can't restore the terminal. Run `reset` to recover. Other signals (`SIGINT`, `SIGTERM`, `SIGHUP`) and crashes restore it automatically.

## Logs

temui never logs to stdout (it carries the terminal graphics). Each process writes its own file, `temui-<UTC start>-<pid>.log`, into:

| OS | Directory |
| --- | --- |
| Linux | `$XDG_STATE_HOME/temui/logs` (default `~/.local/state/temui/logs`) |
| macOS | `~/Library/Logs/temui` |
| Windows | `%LOCALAPPDATA%\temui\logs` |

Files roll over at 5 MB, and the newest 20 (up to 50 MB in total) are kept. `--verbose` logs at debug level; `--log-file <path>` appends to one file instead. `temui --help` shows the directory.

## License

[MIT](LICENSE). temui never bundles or links libretro cores; they are downloaded separately and keep their own licenses.
