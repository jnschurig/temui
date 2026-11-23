# 01 · Scaffold and build matrix

> Seed prompt for `/spec-and-dev docs/roadmap/01-scaffold.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Create the repository skeleton: an empty `temui` binary that builds for all six targets with a pinned toolchain, logs to a file, and has CI. Every later item builds on this.

## Context
- D1 — Zig, pinned by a committed `mise.toml` (Zig 0.17.1 at the time of writing); `minimum_zig_version` in `build.zig.zon` is only a guard.
- D2 — six targets; Linux against glibc 2.28; Windows minimum `win10_rs4`; windows-aarch64 is tier-2.
- D12 — CI is the future release builder, so the matrix set up here is reused by item 16.
- D13 — log to a file, never stdout; `--verbose`.
- D14 — `zig build test` is the test entry point; CI never downloads cores.

## In scope
- `mise.toml` pinning Zig; `build.zig` and `build.zig.zon`.
- A build option or step that cross-compiles all six targets: `x86_64-linux-gnu.2.28`, `aarch64-linux-gnu.2.28`, `x86_64-macos`, `aarch64-macos`, `x86_64-windows.win10_rs4`, `aarch64-windows.win10_rs4`.
- Vendored `libretro.h` (MIT) under a `vendor/` or `include/` dir, with its license and upstream revision recorded.
- `temui --version` and `temui --help` (argument parsing skeleton).
- File logging to the platform's log/state directory, with `--verbose` and a `--log-file` override.
- GitHub Actions using `jdx/mise-action`: **cross-compile all 6 targets, but run `zig build test` only on targets that have a native GitHub runner.** Upload build artifacts.
- `.gitignore` for `zig-out/`, `.zig-cache/`.

## Out of scope
- Any emulation, rendering, or input code.
- Release publishing (item 16).
- Fetching or loading cores.

## Acceptance sketch
- `mise install && zig build` works on a fresh macOS checkout.
- `zig build -Dall-targets` (or equivalent) produces six binaries; `file` shows the expected format and architecture for each.
- CI is green: six cross-compiles plus `zig build test` on every native runner.
- Running `temui --verbose` writes to the log file and nothing to stdout except intended output.

## Depends on
- Nothing. This is the first item.

## Open questions for the cycle's interview
- Which of the six targets have native GitHub-hosted runners today (e.g. `ubuntu-24.04-arm`, `windows-11-arm`, an Intel macOS image)? Test on all of those.
- How to verify the Linux binary's glibc floor in CI (e.g. `objdump -T` symbol versions ≤ 2.28)?
- Log file location per OS, and log rotation or size cap?
- Argument-parsing approach: hand-rolled or a small vendored library?
- Project layout: `src/engine/`, `src/cli/`, `src/render/`… decide now or grow it?
