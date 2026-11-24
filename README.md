# temui

A single-binary, dependency-free, terminal-based [libretro](https://www.libretro.com/) frontend, written in Zig.

- Play SNES, NES and Game Boy games in your terminal, using kitty graphics where the terminal supports it and half-block or ASCII rendering everywhere else.
- Run headless instances that can be attached, detached, sped up, slowed down, and scripted by bots and agents over a local control socket.

## Status

Pre-alpha: the build, CLI skeleton, file logging and CI are in place; nothing plays games yet.

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
