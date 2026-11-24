# temui — Architecture Decisions

temui is a single-binary, dependency-free, terminal-based [libretro](https://www.libretro.com/) frontend. It plays games interactively, and it also runs headless instances that can be attached, detached, sped up or slowed down, and scripted by bots or agents.

This document records the product-level decisions (D1–D15) and why they were made. Each decision names the [roadmap](roadmap.md) item(s) that implement it or retire its risks. Change a decision by editing it here in a dedicated cycle; roadmap seeds refer to decisions by number and do not copy them.

Status: accepted 2026-11-23. Facts marked *verified* were checked on that date (see [Verified facts](#verified-facts-2026-11-23)).

---

## D1: Language and toolchain — Zig, pinned by mise

**Decision.** Write temui in Zig. Pin the Zig version in a committed `mise.toml` at the repo root (currently `zig = "0.17.1"`). That file is the single source of truth: local development and CI (`jdx/mise-action`) both install from it. `minimum_zig_version` in `build.zig.zon` is kept in sync only as a guard. `zig build` compiles in the C dependencies: `libretro.h` (header only), miniaudio, and SDL3 (gamepad subsystem only). TLS and zip extraction come from Zig's std, so there is no OpenSSL or zlib.

**Rationale.** Zig cross-compiles C and Zig code for all six targets from a single host, with no per-target sysroots. It interoperates with C headers directly (translated to Zig by the build system's translate-C), so the libretro ABI is used without bindings. It has no GC and no runtime, which suits frame-paced emulation. The author already knows it.

**Alternatives rejected.**
- *Rust:* slow compiles, and cross-building C dependencies (SDL3, miniaudio) per target is more work.
- *Go:* cgo complicates cross-compiling; purego is awkward for callback-heavy C APIs like libretro; GC pauses can cause stutter at 60 fps.
- *C/C++:* no built-in cross-compiling build system; more memory-safety burden.

**Risks / open questions.**
- Zig is pre-1.0. std APIs change between minor versions (0.16 → 0.17 reworked I/O around `std.Io`). Mitigation: pin with mise and upgrade deliberately in a dedicated cycle.

**Roadmap.** [01-scaffold](roadmap/01-scaffold.md) (mise, build); [09-audio](roadmap/09-audio.md) (miniaudio); [15-gamepad](roadmap/15-gamepad.md) (SDL3).

---

## D2: Targets — six OS/architecture pairs

**Decision.** Build for linux, macos and windows, each on x86_64 and aarch64.
- **Linux** links dynamically against a baseline glibc (`-target x86_64-linux-gnu.2.28`, `aarch64-linux-gnu.2.28`), because a fully static musl binary cannot `dlopen` the glibc-built cores.
- **Windows** sets the minimum OS version to `win10_rs4` (1803, e.g. `x86_64-windows.win10_rs4`). Zig's std enables AF_UNIX sockets only at that minimum (needed by D6).
- **windows-aarch64 is tier-2.** The buildbot publishes no cores for it. It is built and released, but cores must be supplied by local path (D4).

**Rationale.** These six cover nearly every desktop user. glibc 2.28 (2018) runs on every mainstream distribution that is still supported.

**Alternatives rejected.**
- *Static musl:* cannot load glibc `.so` cores, and those are the only ones the buildbot ships.
- *Dropping windows-aarch64:* the binary costs nothing to build, and users with their own cores can still use it.

**Risks / open questions.**
- Tests run only on targets with native CI runners. The others are cross-compiled but never executed in CI.

**Roadmap.** [01-scaffold](roadmap/01-scaffold.md), [07-core-acquisition](roadmap/07-core-acquisition.md) (windows-aarch64 message), [16-release-pipeline](roadmap/16-release-pipeline.md).

---

## D3: Cores — runtime-loaded, software framebuffer only

**Decision.** Load cores at runtime with `dlopen` / `LoadLibrary` (Zig `std.DynLib`) and drive them through the libretro C API. Support only software framebuffers in 0RGB1555, RGB565 and XRGB8888. OpenGL/Vulkan hardware-rendered cores are out of scope.

**Rationale.** The libretro API gives access to dozens of emulators through one interface. A terminal can only show CPU-side pixels anyway, so hardware rendering would mean an offscreen GPU context plus readback, with a large dependency cost.

**Alternatives rejected.**
- *Linking cores statically:* GPL contamination (see D4), and a huge binary.
- *Embedding specific emulators directly:* loses libretro's reach.
- *Hardware rendering via readback:* needs GL/Vulkan loaders and a GPU on headless hosts.

**Risks / open questions.**
- Cores that keep global state cannot run twice in one process. Mitigation: one process per instance (D5).
- Which environment callbacks to implement: start minimal, and add more as each real core needs them.

**Roadmap.** [03-libretro-host-and-test-core](roadmap/03-libretro-host-and-test-core.md).

---

## D4: Core acquisition — nightly buildbot, pinned on first download

**Decision.** Download cores on demand from the libretro buildbot **nightly** channel (`https://buildbot.libretro.com/nightly/{platform}/latest/{core}_libretro.{so,dylib,dll}.zip`) into a per-user cache, and extract them with `std.zip`. A core is **pinned** on first download: its hash is recorded then, and the installed core changes only through an explicit `temui core update`. The user can always override with a local path. On platforms with no buildbot cores (windows-aarch64), download fails with a message pointing to the local-path option.

A built-in system→core map covers the first systems:

| System | Default core | Alternative |
|---|---|---|
| SNES | snes9x | — |
| NES | fceumm | nestopia |
| GB / GBC | gambatte | sameboy (not on linux-aarch64) |

Cores are never bundled with temui.

**Rationale.** Never bundling cores keeps the MIT binary free of GPL obligations (most cores are GPL). Nightly is the only channel with a separate download per core: each is a deflate zip, which Zig's std can extract. Nightly files are rebuilt daily, so pinning keeps a working setup from changing underneath the user.

**Alternatives rejected.**
- *Stable channel:* ships only one `RetroArch_cores.7z` bundle of every core per platform. It has no macOS or arm64 builds, and Zig has no 7z decoder (verified).
- *Bundling cores:* GPL obligations and binary size.
- *Re-downloading the latest nightly on every launch:* not reproducible, and slow.

**Risks / open questions.**
- Each nightly core has a `.sig` file (magic `RACSIG01`, 139 bytes), which looks like RetroArch's core signatures. If the public key and format can be found, verify signatures instead of relying on trust-on-first-download. → 07.
- Zig std TLS loading the system certificates on Linux and Windows (verified on macOS only). → 07.
- The buildbot's layout or availability could change. Mitigation: the local-path override; the mirror URL is a config setting.

**Roadmap.** [07-core-acquisition](roadmap/07-core-acquisition.md).

---

## D5: Process model — hybrid, one OS process per instance, no daemon

**Decision.** The engine is a library inside the binary.
- `temui play <rom>`: engine and viewer in one process; it still serves a control socket.
- `temui run --detach`: starts a headless instance.
- `temui attach`, `temui grid`, `temui ls`: connect as viewers or clients.

Every instance is a separate OS process. Instances register themselves in a per-user runtime directory (one socket plus one metadata file each), so there is no central daemon. The directory is created with mode `0700` and sockets with `0600`, so only the owning user can connect. `ls` and the grid check that each listed process is alive (connect or pid check) and remove entries left behind by crashed instances.

**Rationale.** Process isolation keeps cores with global state from interfering with each other, and a crashing core doesn't take down the viewer. Self-registration avoids the lifecycle problems of a daemon (who starts it, what happens when it dies). Everyday play stays a single command.

**Alternatives rejected.**
- *Central daemon:* extra lifecycle, and a single point of failure.
- *Multiple instances in one process:* unsafe because of core globals.
- *Separate viewer and engine processes even for `play`:* needless IPC in the common case.

**Risks / open questions.**
- Runtime directory location per OS (`$XDG_RUNTIME_DIR`, `$TMPDIR`, `%LOCALAPPDATA%`), and Unix socket path length limits (~104 bytes on macOS). → 12.
- Until item 12 lands, `play` runs without a control socket (see 05).

**Roadmap.** [05-play-loop](roadmap/05-play-loop.md), [12-control-protocol-and-registry](roadmap/12-control-protocol-and-registry.md), [13-attach-detach-viewer](roadmap/13-attach-detach-viewer.md), [14-grid-and-command-palette](roadmap/14-grid-and-command-palette.md).

---

## D6: Control protocol — versioned NDJSON over a local Unix socket

**Decision.** Versioned, line-delimited JSON over a local AF_UNIX socket, with one code path on every OS (Windows 10 1803+ supports AF_UNIX). Commands:

- spawn, list, attach / detach, kill
- pause / resume / step N, set speed
- set input, save / load state
- read / write RAM, grab frame
- set viewer frame rate

Frame pixels travel over shared memory when the client is local. Inputs sent over the socket take effect on a specific frame number, so a given sequence of steps and inputs always replays to the same result (assuming the core itself is deterministic). The TUI command palette and `temui ctl` send the same commands, so a person in the TUI and an outside agent or script have the same power. For example, either can spawn an instance and see it appear in the other's view.

**Rationale.** NDJSON can be debugged with `socat` and `jq`, and any language can speak it without a code generator. Unix sockets carry filesystem permissions (D5). Frame-numbered inputs are what RL and test harnesses need to be reproducible.

**Alternatives rejected.**
- *TCP:* network exposure and auth to design. Control is local-only.
- *gRPC / protobuf:* code generation and a large dependency.
- *MessagePack:* not readable for debugging. Bulk data (frames) already bypasses JSON via shared memory.
- *Windows named pipes:* a second code path; kept only as a fallback.

**Risks / open questions.**
- AF_UNIX on Windows at runtime. Zig std supports it (verified in source), but it hasn't been exercised yet. Fallback: named pipes. → 12.
- Cross-platform shared-memory API (`shm_open` / `CreateFileMapping`) and its lifetime. → 12.
- Protocol versioning and compatibility policy. → 12.

**Roadmap.** [12-control-protocol-and-registry](roadmap/12-control-protocol-and-registry.md); used by 13, 14, [18-python-client](roadmap/18-python-client.md), [19-libtemui-embed](roadmap/19-libtemui-embed.md), [22-multi-instance-input-broadcast](roadmap/22-multi-instance-input-broadcast.md).

---

## D7: Rendering — one renderer interface, three backends, auto-selected

**Decision.** One renderer interface. The backend is chosen automatically by querying the terminal and can be overridden with a flag.

- **Kitty graphics** (primary): sends frames at native resolution and lets the terminal scale them, reusing one image id per instance. Transport is shared memory when local, falling back to a temp file, then to inline data (zlib). Supported in kitty, Ghostty, WezTerm and Rex.
- **Half-block truecolor** (universal fallback): `▀` with foreground/background colors, two pixels per cell; only changed cells are redrawn.
- **ASCII**: a brightness ramp with optional color. Resolution is the terminal's size in character cells (font size doesn't matter). Meant to be cheap when many instances are visible.

Sixel and iTerm2 protocols are deferred, so Windows Terminal gets half-block or ASCII at first.

**Rationale.** Kitty graphics gives full resolution at the lowest CPU cost wherever it's supported. Half-block works on any truecolor terminal. ASCII keeps a grid of many instances affordable.

**Alternatives rejected.**
- *Sixel first:* palette-limited, and encoding is CPU-heavy at 60 fps. Deferred to 17.
- *Scaling in temui:* wastes bandwidth when the terminal can scale.
- *Kitty Unicode placeholders:* unnecessary for full-pane rendering.

**Risks / open questions.**
- Throughput at 60 fps for each transport, in each terminal. Rex has an active report of kitty-graphics frame rates much lower than kitty or Ghostty, plus reports of high CPU on large animation frames. Half-block may be the better default in Rex. → 02.
- Detection: some terminals answer the kitty query but perform poorly. Allow a per-terminal override in config.
- tmux needs passthrough for kitty graphics (best-effort; half-block works).

**Roadmap.** [02-spike-terminal-graphics](roadmap/02-spike-terminal-graphics.md), [04-renderers](roadmap/04-renderers.md), [17-sixel-renderer](roadmap/17-sixel-renderer.md).

---

## D8: Timing and speed — decoupled emulation and presentation

**Decision.**
- **Pacing:** at 1× speed, the audio buffer sets the pace in the process that plays audio. Headless instances and instances without audio are paced by a high-resolution wall-clock timer.
- **Speed controls:** fast-forward at N× or unthrottled; slow motion, pause and single-step.
- **Presentation:** decoupled from emulation. Frameskip means presenting fewer frames than are emulated, and each viewer sets its own presentation rate (e.g. 60 fps, 1 fps, or one frame per 5 s).

**Rationale.** Pacing on audio avoids drift and crackle when sound is on. A wall clock is the only option when there is none. Terminals cannot keep up with every emulated frame at high speed, so presentation has to be independent.

**Alternatives rejected.**
- *Vsync:* a terminal has no vsync.
- *Always wall-clock:* audio buffer underruns and overruns cause crackle.
- *Dynamic rate control (RetroArch-style resampling):* more complex. Revisit if audio-paced timing proves insufficient.

**Risks / open questions.**
- Timer precision on Windows (default 15.6 ms tick); may need high-resolution waitable timers. → 05.

**Roadmap.** [05-play-loop](roadmap/05-play-loop.md), [09-audio](roadmap/09-audio.md), [13-attach-detach-viewer](roadmap/13-attach-detach-viewer.md).

---

## D9: Input — kitty keyboard protocol, Windows console input, SDL3 gamepads

**Decision.**
- **Keyboard:** the kitty keyboard protocol (press/repeat/release events) where the terminal supports it, and the console input API on Windows. Where key releases aren't reported, a timeout guesses releases and the user sees a warning.
- **Gamepads:** through SDL3 (gamepad subsystem only, statically linked), mapped to the libretro RetroPad.
- **Bindings** are configurable.
- **Sources:** input can come from the attached viewer or from the control socket.

**Rationale.** Games need held keys, which plain terminal input can't express. The kitty protocol and the Windows console API both report key releases. SDL3's gamepad database handles controller quirks.

**Alternatives rejected.**
- *Raw OS keyboard hooks (evdev, CGEventTap):* need permissions, and don't work over SSH.
- *Hand-rolled gamepad support per OS (hidraw / IOKit / XInput):* large surface; SDL3 already solves it.

**Risks / open questions.**
- The SDL3 gamepad-only static build on all six targets. → 15.
- Over SSH, gamepads attach to the remote host (same limitation as audio).

**Roadmap.** [06-keyboard-input-and-modes](roadmap/06-keyboard-input-and-modes.md), [11-game-control-mapping](roadmap/11-game-control-mapping.md), [15-gamepad](roadmap/15-gamepad.md).

---

## D10: Audio — miniaudio, one audible process

**Decision.** Use miniaudio, which loads OS audio backends at runtime and so adds no link-time dependencies. Audio is resampled to the device rate. Only one process plays audio: the instance in foreground play, or one attached with `--audio`. Headless instances are silent. Audio is muted at speeds other than 1×. Over SSH, audio plays on the remote host; this is a documented limitation.

**Rationale.** miniaudio is a single C file (public domain / MIT-0) that covers every target. A single audible process avoids a cacophony when many instances run.

**Alternatives rejected.**
- *SDL3 audio:* would pull in more of SDL than the gamepad subsystem.
- *cubeb / PortAudio:* heavier builds.
- *Pitch-shifting audio at non-1× speeds:* unneeded complexity.

**Risks / open questions.** None blocking.

**Roadmap.** [09-audio](roadmap/09-audio.md), [13-attach-detach-viewer](roadmap/13-attach-detach-viewer.md) (`--audio` handoff).

---

## D11: Persistence — SRAM autosave, save-state slots, platform config dirs

**Decision.** SRAM is saved automatically. Save states go in numbered slots. The config file lives in the platform's standard location: XDG on Linux, Application Support on macOS, AppData on Windows. The config format is chosen in the config cycle.

**Rationale.** Matches user expectations from other emulators. Standard paths keep files where users and backup tools expect them.

**Alternatives rejected.**
- *A single `~/.temui` directory:* ignores platform conventions.
- *Fixing the config format now:* better decided alongside the config's actual contents.

**Risks / open questions.**
- Config format (candidates: ZON, TOML, JSON); Zig std parses ZON and JSON natively. → 10.
- SRAM write safety: write to a temp file and rename atomically, so a crash can't corrupt a save. → 10.

**Roadmap.** [10-persistence-and-config](roadmap/10-persistence-and-config.md).

---

## D12: Distribution — GitHub Releases from a CI cross-compile matrix

**Decision.** Publish GitHub Releases built by a CI cross-compile matrix, with checksums. Homebrew and Scoop come later, as do macOS signing and notarization.

**Rationale.** One CI host can cross-compile all six targets with Zig. Releases with checksums are the minimum trustworthy channel.

**Alternatives rejected.**
- *Package managers first:* each needs its own maintenance. They come after the release pipeline is stable.

**Risks / open questions.**
- Unsigned macOS binaries are quarantined by Gatekeeper. Document `xattr -d com.apple.quarantine` until 20.

**Roadmap.** [01-scaffold](roadmap/01-scaffold.md) (CI), [16-release-pipeline](roadmap/16-release-pipeline.md), [20-packaging](roadmap/20-packaging.md).

---

## D13: Observability — file logs, optional stats overlay

**Decision.** Log to a file, never to the TUI's stdout. `--verbose` raises the log level. An optional overlay shows emulation fps, presented fps, and bytes/s written to the terminal.

**Rationale.** stdout carries the terminal graphics, so writing logs there would corrupt the display. The overlay's numbers are the ones that matter when tuning renderer performance.

**Alternatives rejected.**
- *stderr logging:* still shares the terminal.
- *A log pane in the TUI:* possible later, but the file log comes first.

**Risks / open questions.** None.

**Roadmap.** [01-scaffold](roadmap/01-scaffold.md) (file logging), [05-play-loop](roadmap/05-play-loop.md) (overlay).

---

## D14: Testing — an in-repo test core, golden images, benchmarks

**Decision.** A tiny, permissively licensed test core written in Zig inside the repo, so CI never downloads anything. Golden-image tests for each renderer, unit tests for pixel-format conversion and protocol encoding, and a throughput benchmark for each renderer.

**Rationale.** Real cores are GPL, large, and fetched over the network, so CI that depends on them is slow and flaky. A test core gives deterministic frames, audio, input echo, SRAM and serialization.

**Alternatives rejected.**
- *Downloading real cores in CI:* network-dependent, slow, and the cores change daily.
- *Committing real cores to the repo:* GPL obligations and binary bloat.

**Risks / open questions.**
- Real-core behavior (environment-callback coverage) is verified manually per cycle, not in CI.

**Roadmap.** [01-scaffold](roadmap/01-scaffold.md) (`zig build test`), [03-libretro-host-and-test-core](roadmap/03-libretro-host-and-test-core.md), [04-renderers](roadmap/04-renderers.md).

---

## D15: Interaction model — modal (game mode / TUI mode)

**Decision.**
- **Game mode:** all input goes to the focused (primary) instance. A later item lets game mode attach to N instances and send the same input to all of them at once.
- **Leaving game mode:** a leader key switches to TUI mode. The default is Esc when the kitty keyboard protocol is active; otherwise a configurable Ctrl key, because without the protocol a plain Esc can't be told apart from the start of another key's escape code.
- **TUI mode:** vim-style keys. `h`/`j`/`k`/`l` = left/down/up/right, `?` = help, `/` = search, plus Enter and arrow-key equivalents.
- **Launch:** `temui` with no arguments opens a ROM browser over the configured ROM directories, with search, and launches the selected ROM.
- **Game control mapping** (keyboard/gamepad → RetroPad, per-system defaults, remapping) is its own roadmap item.

**Rationale.** Games need every key, so frontend controls need a separate mode. The ambiguity of a bare Esc without the kitty protocol is a hard terminal constraint, not a preference.

**Alternatives rejected.**
- *Modifier chords for every frontend action (RetroArch-style hotkeys):* collide with game input and with terminal shortcuts.
- *A non-modal UI:* can't give a game full use of the keyboard.

**Risks / open questions.**
- The default fallback leader key must not clash with common terminal or tmux bindings (Ctrl-B, Ctrl-A). → 06.

**Roadmap.** [06-keyboard-input-and-modes](roadmap/06-keyboard-input-and-modes.md), [08-tui-shell-and-rom-browser](roadmap/08-tui-shell-and-rom-browser.md), [11-game-control-mapping](roadmap/11-game-control-mapping.md), [14-grid-and-command-palette](roadmap/14-grid-and-command-palette.md), [22-multi-instance-input-broadcast](roadmap/22-multi-instance-input-broadcast.md).

---

## Terminal support tiers

| Tier | Terminals | Renderer | Input |
|---|---|---|---|
| 1 — full | kitty, Ghostty, WezTerm, Rex | kitty graphics (half-block in Rex if 02 shows it is faster) | kitty keyboard protocol |
| 2 — truecolor | any truecolor terminal (incl. Windows Terminal) | half-block | kitty protocol if present; otherwise timeout-guessed key releases, or the Windows console API |
| 3 — basic | anything else | ASCII | as tier 2 |

tmux is best-effort: kitty graphics needs `allow-passthrough`, and half-block works.

## Project-wide constraints

- Runtime prerequisites: nothing beyond the OS, a terminal, and network access the first time a core is fetched.
- MIT license. No GPL code is linked into the binary.

## Out of scope (project-wide, until revisited)

- Hardware-rendered cores (N64, hardware-rendered PS1, etc.), shaders, netplay, RetroAchievements, rewind, box-art/ROM scraping.
- Network (TCP) control; control is local-only.
- The embeddable `libtemui` C-ABI library and Python/Gym wrappers are backlog items ([18](roadmap/18-python-client.md), [19](roadmap/19-libtemui-embed.md)) built on top of the control protocol, not part of the MVP.

## Risk register

| Risk | Status | Retired by |
|---|---|---|
| Kitty-graphics throughput at 60 fps per transport, in kitty / Ghostty / WezTerm / Rex | open (Rex has an active slow-frame-rate report) | [02](roadmap/02-spike-terminal-graphics.md) |
| Terminal capability detection is reliable | open | [02](roadmap/02-spike-terminal-graphics.md), [04](roadmap/04-renderers.md) |
| Zig std TLS loads system certificates on Linux and Windows | verified on macOS only | [07](roadmap/07-core-acquisition.md) |
| `.sig` (`RACSIG01`) core signatures can be verified | open | [07](roadmap/07-core-acquisition.md) |
| Windows AF_UNIX works at runtime from Zig std | supported in source; untested | [12](roadmap/12-control-protocol-and-registry.md) (fallback: named pipes) |
| Cross-platform shared memory for frames | open | [12](roadmap/12-control-protocol-and-registry.md) |
| SDL3 gamepad-only static build on all six targets | open | [15](roadmap/15-gamepad.md) |
| Timer precision on Windows | open | [05](roadmap/05-play-loop.md) |
| Buildbot coverage of the six targets | **verified** — see below | — |

## Verified facts (2026-11-23)

**Buildbot.** The stable channel (`/stable/1.22.2/`) ships one `RetroArch_cores.7z` per platform (linux/x86_64, windows/x86_64) and no per-core zips. It has no macOS cores and no arm64 builds. The nightly channel has one deflate zip per core:

| target (buildbot dir) | snes9x | fceumm | nestopia | gambatte | sameboy |
|---|---|---|---|---|---|
| linux-x86_64 (`linux/x86_64`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| linux-aarch64 (`linux/aarch64`) | ✓ | ✓ | ✓ | ✓ | ✗ |
| macos-x86_64 (`apple/osx/x86_64`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| macos-aarch64 (`apple/osx/arm64`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| windows-x86_64 (`windows/x86_64`) | ✓ | ✓ | ✓ | ✓ | ✓ |
| windows-aarch64 | — no platform directory — | | | | |

Each nightly directory also has `.index-extended` (date, CRC32, filename) and per-core `.sig` files.

**Zig.** Latest stable is 0.17.1. In its std:
- `std.zip` extracts store and deflate entries.
- `std.http.Client.fetch` downloaded `snes9x_libretro.so.zip` from the buildbot over HTTPS on macOS (200, 988,900 bytes, identical to curl).
- `std.Io` implements AF_UNIX listen/connect on Windows through AFD, gated on a minimum target of `win10_rs4`.

**Rex.** Supports kitty graphics fully since mac 0.1.0-preview.19 / server preview.5, including file and shared-memory transport (the server rewrites local reads for remote clients). Supports the kitty keyboard protocol. There are open reports of lower kitty-graphics frame rates and high CPU on large animation frames, and inline images ≥10 MB are dropped.
