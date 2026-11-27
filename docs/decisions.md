# temui — Architecture Decisions

temui is a single-binary, dependency-free, terminal-based [libretro](https://www.libretro.com/) frontend. It plays games interactively, and it also runs headless instances that can be attached, detached, sped up or slowed down, and scripted by bots or agents.

This document records the product-level decisions (D1–D15) and why they were made. Each decision names the [roadmap](roadmap.md) item(s) that implement it or retire its risks. Change a decision by editing it here in a dedicated cycle; roadmap seeds refer to decisions by number and do not copy them.

Status: accepted 2026-11-23. Facts marked *verified* were checked on that date (see [Verified facts](#verified-facts-2026-11-23)).

---

## D1: Language and toolchain — Zig, pinned by mise

**Decision.** Write temui in Zig. Pin the Zig version in a committed `mise.toml` at the repo root (currently `zig = "0.17.1"`). That file is the single source of truth: local development and CI (`jdx/mise-action`) both install from it. `minimum_zig_version` in `build.zig.zon` is kept in sync only as a guard. `zig build` compiles in the C dependencies: `libretro.h` (header only), stb_sprintf (formats the variadic core-log callback, which Zig 0.17.1 cannot define on aarch64-linux or x86_64-windows; added in 03), miniaudio, and SDL3 (gamepad subsystem only). TLS and zip extraction come from Zig's std, so there is no OpenSSL or zlib.

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

**Decision.** Load cores at runtime with `dlopen` / `LoadLibrary` (a small in-repo wrapper, `src/libretro/DynLib.zig`: Zig 0.17.1's `std.DynLib` has no Windows backend and drops `dlerror()`) and drive them through the libretro C API. Support only software framebuffers in 0RGB1555, RGB565 and XRGB8888. OpenGL/Vulkan hardware-rendered cores are out of scope.

**Rationale.** The libretro API gives access to dozens of emulators through one interface. A terminal can only show CPU-side pixels anyway, so hardware rendering would mean an offscreen GPU context plus readback, with a large dependency cost.

**Alternatives rejected.**
- *Linking cores statically:* GPL contamination (see D4), and a huge binary.
- *Embedding specific emulators directly:* loses libretro's reach.
- *Hardware rendering via readback:* needs GL/Vulkan loaders and a GPU on headless hosts.

**Risks / open questions.**
- Cores that keep global state cannot run twice in one process. Mitigation: one process per instance (D5).
- Which environment callbacks to implement: start minimal, and add more as each real core needs them.
- **Observed 2026-11-24** (`temui run --headless`, 600 frames, `--verbose`; both cores render correctly with the host from [03](roadmap/03-libretro-host-and-test-core.md)):
  - *snes9x 1.63* handled: `SET_VARIABLES`, `GET_VARIABLE`, `GET_VARIABLE_UPDATE` (every frame), `GET_CORE_OPTIONS_VERSION`, `SET_PIXEL_FORMAT` (RGB565), `SET_GEOMETRY`, `SET_INPUT_DESCRIPTORS`, `GET_LOG_INTERFACE`, `GET_SYSTEM_DIRECTORY`, `GET_SAVE_DIRECTORY`. Unsupported, no visible effect: `GET_AUDIO_VIDEO_ENABLE` (every frame), `GET_VFS_INTERFACE`, `GET_INPUT_BITMASKS`, `SET_SUBSYSTEM_INFO`, `SET_CONTROLLER_INFO`, `SET_PERFORMANCE_LEVEL`, `SET_SUPPORT_ACHIEVEMENTS`.
  - *Gambatte v0.5.0* handled: `SET_VARIABLES`, `GET_VARIABLE`, `GET_VARIABLE_UPDATE`, `GET_CORE_OPTIONS_VERSION`, `SET_PIXEL_FORMAT` (RGB565), `SET_INPUT_DESCRIPTORS`, `GET_LOG_INTERFACE`, `GET_SYSTEM_DIRECTORY`, `GET_CAN_DUPE`. Unsupported, no visible effect: `GET_VFS_INTERFACE`, `GET_INPUT_BITMASKS`, `GET_RUMBLE_INTERFACE`, `GET_LANGUAGE`, `GET_MESSAGE_INTERFACE_VERSION`, `SET_VARIABLE`, `SET_MEMORY_MAPS`, `SET_FASTFORWARDING_OVERRIDE`, `SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK`, `SET_PERFORMANCE_LEVEL`, `SET_SUPPORT_ACHIEVEMENTS`.
  - Likely next: `GET_INPUT_BITMASKS` (both ask; saves 16 `input_state` calls per frame) and `GET_AUDIO_VIDEO_ENABLE` (snes9x asks every frame; useful for run-ahead or skipping video in fast-forward).

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

- **Kitty graphics** (primary): sends frames at native resolution and lets the terminal scale them. Each instance alternates two image ids: it transmits and places frame N on one id, then deletes the other id's placement. Re-sending a single id flickers severely in Ghostty (a photosensitivity hazard), and alternating costs nothing measurable (02). The transport order is a per-terminal preference, keyed by XTVERSION. The default order is shared memory when local, then temp file, then inline zlib. In Rex the order is inline zlib first, because its shm and file paths cost about 2× the terminal CPU (02). Inline zlib is always in the chain (last by default, first in Rex) and is the only remote option. Raw inline RGB/RGBA is not used. Supported in kitty, Ghostty, WezTerm and Rex.
- **Half-block truecolor** (universal fallback): `▀` with foreground/background colors, two pixels per cell; only changed cells are redrawn.
- **ASCII**: a brightness ramp with optional color. Resolution is the terminal's size in character cells (font size doesn't matter). Meant to be cheap when many instances are visible.

Sixel and iTerm2 protocols are deferred, so Windows Terminal gets half-block or ASCII at first.

**Rationale.** Kitty graphics gives full resolution at the lowest CPU cost wherever it's supported. Measured in [spike 02](spikes/02-terminal-graphics.md) on an M2 Max at 256×224 and 60 fps, the total CPU per frame for temui plus the terminal was 3.7 ms for Ghostty with shm and 5.9 ms for Rex with zlib. Half-block works on any truecolor terminal. ASCII keeps a grid of many instances affordable.

**Alternatives rejected.**
- *Sixel first:* palette-limited, and encoding is CPU-heavy at 60 fps. Deferred to 17.
- *Scaling in temui:* wastes bandwidth when the terminal can scale.
- *Kitty Unicode placeholders:* unnecessary for full-pane rendering.
- *One global transport order* (rejected after 02): the cheapest transport differs by terminal (Ghostty shm, Rex inline zlib).
- *One image id per instance* (rejected after 02): flickers in Ghostty.

**Risks / open questions.**
- Throughput at 60 fps: measured in 02. Ghostty 1.4.0 and Rex 0.1.0-preview.19 pass 60 fps with every transport, and unpaced every kitty transport reaches 500 fps or more. Rex's reported slow frame rates did not reproduce, so half-block is not Rex's default. kitty, WezTerm, SSH and tmux are not measured; they use the default order until measured. Re-measured through the production renderer in 04 ([results](bench/04-renderers.md)): Ghostty with shm and Rex with zlib hold 60 fps with a p99 frame interval of about 20.5 ms, and temui's own cost is 0.3 and 0.6 ms per frame. Half-block also holds a paced 60 fps, but costs about 10 ms per frame for temui plus the terminal when every cell changes, about 3.5× kitty graphics.
- Detection: some terminals answer the kitty query but perform poorly. Allow a per-terminal override in config.
- tmux needs passthrough for kitty graphics (best-effort; half-block works).
- Boxes over a kitty image (05, extended in 06): each placement carries a z-index, keyed by XTVERSION like the transport order. The default is `-1073741825`, which puts the image below cells with a non-default background, so a box whose every cell has a non-default background (the leader menu and the centered boxes since 06, the stats overlay in 05) draws solidly on top. Half-block and ASCII keep clear of up to four rects at once, and repaint each one's cells when it closes. Verified in Ghostty 1.4.0 and Rex ([results](bench/05-play-loop.md)). A terminal that ignores the negative z gets `-1` as its per-terminal value; none needs it yet.

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
- Timer precision on Windows (default 15.6 ms tick). **Implemented in 05:** the wait uses a high-resolution waitable timer (`CreateWaitableTimerExW` with `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION`), and a unit test on the Windows CI runners checks that it wakes within tolerance. Not yet measured in a real Windows console.
- The wall-clock pacer (05) keeps an absolute schedule, so jitter doesn't accumulate: 18000 frames in 300.0 s in Ghostty and Rex ([results](bench/05-play-loop.md)). When it falls more than 100 ms behind (a stall, a slow present), it re-bases to now instead of bursting to catch up. Under unthrottled speed, emulation gets at least the last present's cost per loop, so slow presents don't starve it.

**Roadmap.** [05-play-loop](roadmap/05-play-loop.md), [09-audio](roadmap/09-audio.md), [13-attach-detach-viewer](roadmap/13-attach-detach-viewer.md).

---

## D9: Input — kitty keyboard protocol, Windows console input, SDL3 gamepads

**Decision.**
- **Keyboard:** the kitty keyboard protocol (press/repeat/release events) where the terminal supports it, and the console input API on Windows. **Game input needs release events:** where the terminal doesn't report them, game input is disabled and the rest of the UI still works (revised in 06; the first design guessed releases).
- **Gamepads:** through SDL3 (gamepad subsystem only, statically linked), mapped to the libretro RetroPad.
- **Bindings** are configurable.
- **Sources:** input can come from the attached viewer or from the control socket.

**Implemented in 06.** All three paths decode into one key model (key, modifiers, press/repeat/release). The kitty protocol is pushed with flags 15 (disambiguate, event types, alternate keys, all keys as escapes) on the alternate screen, and popped by the session's pre-built restore string, so a crash pops it too. Windows reads `KEY_EVENT` records with `ENABLE_VIRTUAL_TERMINAL_INPUT` cleared. Focus loss releases every button on every path.

- **Game input disabled** (no release events: tmux, Terminal.app, a detection timeout): `play` starts in TUI mode with a red `GAME MODE DISABLED` flag in the status line, and `i`, Enter and the mode key show a 3-s notice naming the terminals that work and `--keyboard kitty`. Pause, speed, stats, the menu and quitting all work. TUI keys are decoded from legacy bytes.
- **Input lost:** with flag 8 a kitty-protocol terminal never sends a key as a plain byte, so one arriving (after the push is acknowledged via `CSI ? u` and a DA1 sentinel) means the protocol is gone. temui releases every button, pauses, shows a modal box, and stays disabled for the rest of the run, so a button can't stick for want of a release.
- **Fixed hold, for automation only** (`--keyboard legacy`): each press holds its button for 100 ms, and a repeat or resend renews it. Scripts driving a pty get usable game input; people are pointed at a terminal with the protocol. A `LEGACY` flag shows in the status line. Esc isn't the mode key there (see D15).
- **Bracketed paste** is on during play on every POSIX path and off in the restore string. A paste is discarded, so pasted text never reads as key presses (and, on the kitty path, never as plain bytes that would trip *input lost*). If no pasted byte arrives for 500 ms before the end marker, the paste is ended and logged, so a lost marker can't lock out input. On Windows a paste arrives as ordinary key events.

**Rationale.** Games need held keys, which plain terminal input can't express. The kitty protocol and the Windows console API both report key releases. SDL3's gamepad database handles controller quirks.

**Alternatives rejected.**
- *Raw OS keyboard hooks (evdev, CGEventTap):* need permissions, and don't work over SSH.
- *Hand-rolled gamepad support per OS (hidraw / IOKit / XInput):* large surface; SDL3 already solves it.
- *Guessing releases from auto-repeat* (built first in 06, dropped after the manual run): a tap can't be told from a hold until the terminal's repeat delay has passed (250–800 ms; 660 ms by default on X11), so every tap held its button that long, and only one key can be held at a time, because a terminal repeats only the last key pressed. That is too imprecise for real-time play, and a warning box doesn't make it usable.

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

**Decision.** Log to a file, never to the TUI's stdout. `--verbose` raises the log level. A status line on the bottom row, outside the image, always shows the emulated fps and speed; detailed stats (presented fps, bytes/s, encode and write time, lag) are toggled into its center segment (`o`, `--overlay`). Since 06 this replaces 05's overlay drawn over the image.

**Rationale.** stdout carries the terminal graphics, so writing logs there would corrupt the display. The overlay's numbers are the ones that matter when tuning renderer performance.

**Alternatives rejected.**
- *stderr logging:* still shares the terminal.
- *A log pane in the TUI:* possible later, but the file log comes first.

**Risks / open questions.**
- Cores can write to stdout themselves: snes9x 1.63 `printf`s `Map_HiROMMap` while loading a HiROM game, which would corrupt the display. **Mitigated in 05 (POSIX):** before loading a core, the session `dup`s fd 1 to a private descriptor that carries all terminal output, and points fds 1 and 2 at a non-blocking pipe. The play loop drains the pipe and logs each line as `core: stdio: …`. With logging off, fds 1 and 2 point at the null device instead. A pipe rather than the log file itself, because the logger writes at its own tracked offset (not `O_APPEND`), so two writers to the file would overwrite each other. On exit temui `fflush`es C stdio (which block-buffers a core's stdout once fd 1 is a pipe), drains the pipe, then restores fds 1 and 2. A panic or signal restores them too, so traces and the exit summary reach the terminal. Verified with snes9x, a LoROM game in Ghostty and a HiROM game in Rex ([results](bench/05-play-loop.md)).
- **Not contained on Windows yet:** containment is a no-op there, so a core's output can still corrupt the display. A fix has to redirect the C runtime's stdout and stderr, not only the console handles.

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
- **The vim model (06):** game mode is insert mode, TUI mode is normal mode.
  - The **mode key** leaves game mode: Esc where a lone Esc is unambiguous (the kitty keyboard protocol, Windows console input), and a Ctrl chord on every path, Ctrl-] by default (`--mode-key`, config in 10). Without the protocol a plain Esc can't be told apart from the start of another key's escape code, so it does nothing in game mode there.
  - The **leader** is Space, in TUI mode only, and opens a which-key menu listing the TUI keys plus `q` quit. Item 08 extends the menu.
  - **Esc only backs out** one layer (quit prompt, then menu); with nothing open it does nothing.
  - **TUI mode keeps the game running**, with every button released on entry. A key held through the return to game mode acts only once pressed again.
  - **Quitting always needs a confirmation**, since nothing is saved yet: Space `q` then Enter, or a second Ctrl-C within 3 s (the first shows a transient prompt and keys keep working). A watchdog thread quits at once on two Ctrl-Cs when the loop has been outside its event wait for ≥ 1 s (a stuck core or a blocked terminal write): best-effort restore, a stderr line, `_exit(130)`.
- **TUI mode:** vim-style keys. `h`/`j`/`k`/`l` = left/down/up/right, `?` = help, `/` = search, plus Enter and arrow-key equivalents.
- **Launch:** `temui` with no arguments opens a ROM browser over the configured ROM directories, with search, and launches the selected ROM.
- **Game control mapping** (keyboard/gamepad → RetroPad, per-system defaults, remapping) is its own roadmap item.

**Rationale.** Games need every key, so frontend controls need a separate mode. The ambiguity of a bare Esc without the kitty protocol is a hard terminal constraint, not a preference.

**Alternatives rejected.**
- *Modifier chords for every frontend action (RetroArch-style hotkeys):* collide with game input and with terminal shortcuts.
- *A non-modal UI:* can't give a game full use of the keyboard.

**Risks / open questions.**
- ~~The default fallback leader key must not clash with common terminal or tmux bindings (Ctrl-B, Ctrl-A).~~ **Closed in 06:** Ctrl-] (telnet's escape, unbound in tmux and common terminals), changeable with `--mode-key`. On some non-US layouts it is awkward to type; the README says so.
- Quit prompts guard against losing progress. If 10 adds a resume save state on quit, they could be relaxed.

**Roadmap.** [06-keyboard-input-and-modes](roadmap/06-keyboard-input-and-modes.md), [08-tui-shell-and-rom-browser](roadmap/08-tui-shell-and-rom-browser.md), [11-game-control-mapping](roadmap/11-game-control-mapping.md), [14-grid-and-command-palette](roadmap/14-grid-and-command-palette.md), [22-multi-instance-input-broadcast](roadmap/22-multi-instance-input-broadcast.md).

---

## Terminal support tiers

| Tier | Terminals | Renderer | Input |
|---|---|---|---|
| 1 — full | kitty, Ghostty, WezTerm, Rex | kitty graphics, double-buffered; shm → file → inline zlib (inline zlib first in Rex) | kitty keyboard protocol |
| 2 — truecolor | any truecolor terminal (incl. Windows Terminal) | half-block | kitty protocol if present, or the Windows console API; otherwise game input is disabled (TUI keys only) |
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
| Kitty-graphics throughput at 60 fps per transport, in kitty / Ghostty / WezTerm / Rex | **retired for Ghostty and Rex** (all transports pass 60 fps; [results](spikes/02-terminal-graphics.md)); confirmed through the production renderer in 04 ([results](bench/04-renderers.md)); kitty, WezTerm, SSH, tmux not measured | [02](roadmap/02-spike-terminal-graphics.md), [04](roadmap/04-renderers.md) |
| Terminal capability detection is reliable | **implemented in 04**: DA1 sentinel plus a 500 ms hard timeout, kitty transports probed at startup; verified live in Ghostty 1.4.0 and Rex (`temui detect`); kitty, WezTerm, tmux and a dumb terminal covered by recorded-reply unit tests; not measured over SSH | [02](roadmap/02-spike-terminal-graphics.md), [04](roadmap/04-renderers.md) |
| Zig std TLS loads system certificates on Linux and Windows | verified on macOS only | [07](roadmap/07-core-acquisition.md) |
| `.sig` (`RACSIG01`) core signatures can be verified | open | [07](roadmap/07-core-acquisition.md) |
| Windows AF_UNIX works at runtime from Zig std | supported in source; untested | [12](roadmap/12-control-protocol-and-registry.md) (fallback: named pipes) |
| Cross-platform shared memory for frames | open | [12](roadmap/12-control-protocol-and-registry.md) |
| SDL3 gamepad-only static build on all six targets | open | [15](roadmap/15-gamepad.md) |
| Cores writing to stdout corrupt the display (snes9x does; D13) | **retired on POSIX in 05**: fds 1 and 2 go to a pipe drained into the log; verified with snes9x in Ghostty and Rex ([results](bench/05-play-loop.md)); **open on Windows** (containment is a no-op there) | [05](roadmap/05-play-loop.md) |
| Timer precision on Windows | **implemented in 05**: high-resolution waitable timer, wake tolerance unit-tested on the Windows CI runners; not measured in a real console | [05](roadmap/05-play-loop.md) |
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

**Rex.** Supports kitty graphics fully since mac 0.1.0-preview.19 / server preview.5, including file and shared-memory transport (the server rewrites local reads for remote clients). Supports the kitty keyboard protocol. There are open reports of lower kitty-graphics frame rates and high CPU on large animation frames, and inline images ≥10 MB are dropped. In spike 02, preview.19 passed 60 fps with every transport. Its shm and file paths cost about 2× the terminal CPU of inline zlib.

**Ghostty (1.4.0, spike 02).** Re-sending one kitty image id every frame flickers severely on inline raw frames. Alternating two ids fixes it.
