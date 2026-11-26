# Item 05 — Play loop verification

Roadmap item [05](../roadmap/05-play-loop.md). Decisions: [D5](../decisions.md#d5-process-model--hybrid-one-os-process-per-instance-no-daemon), [D7](../decisions.md#d7-rendering--one-renderer-interface-three-backends-auto-selected), [D8](../decisions.md#d8-timing-and-speed--decoupled-emulation-and-presentation), [D13](../decisions.md#d13-observability--file-logs-optional-stats-overlay). Raw data: [`05-data/`](05-data/).

## Summary

- **Pacing is exact.** Over 300 s at 1× with the test core, both terminals ran **18000 frames in 300.0 s** (60.00 fps emulated and presented). The per-second rate stayed between 60.0 and 60.9 in all 300 one-second samples, and the schedule never re-based. (A 1-s window can catch a 61st frame, so 60.9 is sampling, not drift.)
- **Emulation and presentation are decoupled.** At 4× the emulated rate is 240.0 fps and at `max` about 10,700–11,000 fps. Meanwhile the presented rate stays at 60.0, or 30.0 with `--present-fps 30`, within ±0.12.
- **Pause, step, resize and signals behave as specified** in both terminals. The overlay's background is solid over the kitty image in both, so the default z-index (`-1073741825`) is kept, with no per-terminal fallback.
- **Three problems were found and fixed during this step.** Under `max`, slow presents starved emulation. Encode time wasn't visible. And `temui` hung when stdin was `/dev/tty` on macOS. See [Findings](#findings).

## Method

| | |
|---|---|
| Machine | Apple M2 Max, macOS 26.7.3 |
| Terminals | Ghostty 1.4.0 (245×65 cells, 14×32 px cells; kitty with shm); Rex 0.1.0-preview.19 (110×32 cells, 15×29 px cells; kitty with inline zlib) |
| Build | `zig build -Doptimize=ReleaseFast`, branch `play-loop` |
| Core | The in-repo test core (256×224 at 60 fps) for every measured run; snes9x 1.63 with real ROMs for the containment check |
| Date | 2026-11-25 |

[`05-data/verify.sh`](05-data/verify.sh) runs the measured set in each terminal and records each run's exit code, logged summary and final stats line. The set is: four 8-s speed runs, three 20-s resize runs (one per backend), SIGINT and SIGTERM sent after 3 s, and a 300-s pacing run. In Ghostty the resizes were done by hand. In Rex the pane borders were moved through the Rex API (seven sizes, from 110×46 down to 110×5 cells), and the pause/step and key checks were driven with `rex send-key`. Screenshots were taken mid-run and after each resize cycle. Terminal state after each exit was checked with `stty` (both terminals) and with Rex's terminal-mode query (alternate screen, cursor visibility).

**Reproduce:** `zig build -Doptimize=ReleaseFast`, then in each terminal run `docs/bench/05-data/verify.sh <terminal>` and drag-resize the window when it prompts.

## Results

### Pacing (300 s, 1×, `--overlay`)

| Terminal | Frames | Seconds | Emu fps | Pres fps | Per-second min / max | Re-bases | Bytes/s | enc ms/s | wr ms/s |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| Ghostty | 18000 | 300.0 | 60.00 | 60.00 | 60.0 / 60.9 | 0 | 14.8 kB | 20 | 2.9 |
| Rex | 18000 | 300.0 | 60.00 | 60.00 | 60.0 / 60.9 | 0 | 457.8 kB | 100 | 14 |

Rex's bytes and encode time are higher because detection picks inline zlib for Rex (D7). Each frame is compressed and sent inline, where Ghostty gets a shared-memory reference of about 250 bytes.

### Speed and presentation rate (8 s each)

| Run | Ghostty emu / pres | Rex emu / pres |
|---|--:|--:|
| 4× | 240.10 / 60.12 | 239.99 / 60.00 |
| `max` | 10896.70 / 60.12 | 10751.87 / 60.12 |
| 4×, `--present-fps 30` | 240.07 / 30.12 | 239.99 / 30.00 |
| `max`, `--present-fps 30` | 10768.41 / 30.12 | 10956.32 / 30.12 |

All runs exited 0. Write time stayed at or below 16 ms/s in Rex and 2.9 ms/s in Ghostty.

### Pause and step (Rex)

- **Step:** `--paused`, then `.` ten times, then `q`: the summary reads **11 frames** (the first frame plus 10 steps).
- **Pause and resume:** after 4 s paused, the resume second reads 40 fps (a partial second), then a steady 60, with no re-base and no catch-up burst.

### Resize

Each backend (kitty, half-block, ASCII) ran 20–22 s while the size changed repeatedly. Every run kept 60/60 fps and exited 0, with no warnings. Screenshots after each Rex cycle show no stale cells or images, and the overlay intact. In Ghostty, the drag-resizes looked clean by eye. The smallest size reached was 110×5 cells (Rex), which drew a small image and recovered. A sub-1×1 window wasn't reachable through either terminal; skipping drawing there is covered by unit tests.

### Signals and exit

| Exit | Ghostty | Rex |
|---|---|---|
| `q` / Ctrl-C key | — | rc 0, primary screen, cursor visible |
| SIGINT | rc 130, `icanon isig echo` | rc 130, `icanon isig echo`, primary screen, cursor visible |
| SIGTERM | rc 143, `icanon isig echo` | rc 143, `icanon isig echo`, primary screen, cursor visible |

### Core stdout containment (snes9x 1.63, D13)

snes9x `printf`s its memory map while loading. With Super Metroid (LoROM, Ghostty) the log has `info(core): stdio: Map_LoROMMap`, and with Secret of Mana (HiROM, Rex) it has `Map_HiROMMap`. Nothing appeared on screen in either case. The game, overlay and speed keys all worked.

## Findings

1. **`max` collapsed when presents were slow.** In Rex, with a Debug build, compressing Secret of Mana frames (about 34 KB each) took about one present period. Every present was then overdue, and the engine's time per loop fell to its 1 ms minimum, so `max` ran at about 60 fps. **Fix:** `play.engineBudget` now gives the engine at least as long as the last present took, capped at 20 ms. Same Debug build and zlib on a 121×65 pty: about 500 fps (was about 60). ReleaseFast: about 2,700–3,100 fps.
2. **Encode time was invisible.** `wr` measured only the write to the terminal, which hid the zlib cost. The overlay and log now show `enc … ms/s` (`Stats.encoded`) as well.
3. **`temui play </dev/tty` hung on macOS.** macOS reports `POLLNVAL` immediately for `poll()` on `/dev/tty`, and the following `read` blocked in detection. **Fix:** detection checks the input with `session.pollable` first, and `play` exits 1 with an explicit message. The wait layer also treats `POLLNVAL` as an error. A normal launch, where stdin is the terminal itself, was never affected.

**Not a defect, noted:** at 1× in Rex, `enc` reads 100–120 ms/s (about 1.8 ms per frame), but only about 0.5 ms per frame at `max` with the same scene. The likely cause is CPU frequency scaling: at 1× the process is mostly idle and runs on slow clocks. It agrees with item 04's 0.6 ms/frame (measured under load).
