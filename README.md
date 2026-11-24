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
- **Modes:** in game mode, every key goes to the game. A leader key switches to TUI mode, which uses vim-style keys. Running `temui` with no arguments opens a searchable ROM browser.
- **Instances:** each game runs as its own process, either in your terminal or headless in the background, and you can attach to it later. There is no daemon. Scripts and AI agents can drive any instance through a versioned JSON protocol over a local socket.

It ships as one binary for Linux, macOS and Windows on x86_64 and aarch64, with nothing else to install.

## Status

Pre-alpha: temui can load a libretro core and run it headless, dumping frames to image files (see [Running a core headless](#running-a-core-headless)); nothing is drawn in the terminal yet.

- [Architecture decisions](docs/decisions.md): what was chosen and why (D1–D15).
- [Roadmap](docs/roadmap.md): ordered work items, each with a seed prompt in [`docs/roadmap/`](docs/roadmap/).

## Building

The Zig version is pinned in [`mise.toml`](mise.toml); install it with [mise](https://mise.jdx.dev/).

```sh
mise install                              # install the pinned Zig
zig build                                 # native binary: zig-out/bin/temui
zig build test                            # unit tests
zig build cross -Doptimize=ReleaseSafe    # all six targets: zig-out/<os>-<arch>/
```

## Running a core headless

`temui run --headless` loads a core and a ROM, runs a fixed number of frames as fast as possible, and can write frames out as PPM images. It is a test harness for the libretro host; there is no display or input yet, and you supply the core yourself.

```sh
temui run --headless --core snes9x_libretro.dylib --rom game.sfc --frames 600 \
    --dump-ppm frames/ --dump-every 60 --option snes9x_region=ntsc
```

It prints one summary line (core name and version, frames run, final geometry, pixel format). `temui --help` lists every option. `zig build` also builds a small test core, `zig-out/lib/temui_test_libretro.{dylib,so}` (`zig-out/bin/temui_test_libretro.dll` on Windows), which runs with `--rom testdata/testcore.rom`.

## Detecting the terminal

`temui detect` asks the terminal what it supports (kitty graphics and which of its transports work, truecolor, cell size) and prints the renderer temui would use: kitty graphics, half-block, or ASCII. `--json` prints the same as JSON. `--renderer kitty|halfblock|ascii|auto` overrides the choice; for now it is accepted only by `detect`.

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
