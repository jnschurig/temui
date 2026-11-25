# Item 04 — Renderer benchmark

Roadmap item [04](../roadmap/04-renderers.md). Decisions: [D7](../decisions.md#d7-rendering--one-renderer-interface-three-backends-auto-selected), [D14](../decisions.md#d14-testing--an-in-repo-test-core-golden-images-benchmarks). Targets come from [spike 02](../spikes/02-terminal-graphics.md). Raw data: [`04-data/`](04-data/).

## Summary

- **Every target is met.** Using the transport that detection picked (Ghostty: shm, Rex: inline zlib), the production renderer held 60 fps in every 1-s window. The p99 frame interval was 20.4–20.5 ms, against a 25 ms target. temui's CPU was 0.31 ms/frame for shm and 0.60 ms/frame for zlib, against targets of 0.5 and 2.5 ms.
- **Terminal CPU was 26–43 % *below* spike 02's paced numbers.** This is not a like-for-like comparison: these windows had 24–40 % of spike 02's pixel area. A same-pane A/B run against termbench shows temui costs the same as the spike's code. See [Comparison with spike 02](#comparison-with-spike-02).
- **Half-block, paced at 60 fps** (not measured in spike 02), passes in both terminals. In the worst-case scene, where every cell changes, it costs about 10 ms of CPU per frame for temui plus the terminal. That is about 3.5× kitty graphics, which supports D7's order: half-block is the fallback, not a peer.

## Method

| | |
|---|---|
| Machine | Apple M2 Max, the same machine as spike 02 |
| Terminals | Ghostty 1.4.0 (181×85 cells, 1268×1374 px, 7×16 px cells); Rex 0.1.0-preview.19 (283×78 cells, 2264×1170 px, 8×15 px cells) |
| Tool | `temui-bench` (`zig build bench`, ReleaseFast), on branch `renderers` |
| Date | 2026-11-24 |

`temui-bench live` puts the terminal into the same session temui uses (raw mode, alternate screen) and runs temui's own detection. It then draws through the production `Renderer` into the whole window, or into a fixed cell area with `--cells`. Frames are the 256×224 `scroll` scene ported from termbench: a tiled background that moves 1 px per frame, so every pixel changes. They are paced at 60 fps on a fixed schedule; a slot is dropped only if it is missed entirely, and no catch-up bursts are sent. A `CSI 5 n` status request follows each frame, and a reader thread timestamps the terminal's in-order replies. The metrics are spike 02's: min fps over 1-s windows, the p99 interval between acknowledgements, and CPU from `getrusage` (temui) and `proc_pid_rusage` (the terminal's processes). Each run lasts 10 s and was run once.

`temui-bench encode` times `Renderer.present` for 600 frames per backend into an in-memory writer. The rect is 128×56 cells at 10×20 px cells. For shm and file, the objects are unlinked after each frame, outside the timed section.

**Reproduce:**

```sh
zig build bench
zig-out/bin/temui-bench encode --source scroll  --out encode-scroll.jsonl
zig-out/bin/temui-bench encode --source testcore --out encode-testcore.jsonl
# in each terminal, full-screen window:
zig-out/bin/temui-bench live --out <terminal>-kitty.jsonl
zig-out/bin/temui-bench live --renderer halfblock --cells 128x56 --out <terminal>-halfblock.jsonl
```

## Results against spike 02's targets

256×224 scroll at 60 fps, kitty graphics with the auto-selected transport, image drawn across the whole window.

| Terminal | Transport | Avg fps | Min fps | p99 ms | temui ms/f | Terminal ms/f | Terminal CPU % | Bytes/frame | Result |
|---|---|--:|--:|--:|--:|--:|--:|--:|---|
| Ghostty | shm | 60 | 60 | 20.36 | 0.31 | 2.52 | 15 | 128 | PASS |
| Rex | inline zlib | 60 | 60 | 20.53 | 0.60 | 2.10 | 13 | 11,931 | PASS |

| Target | Ghostty (shm) | Rex (zlib) |
|---|---|---|
| min fps 60 in every 1-s window | 60 ✓ | 60 ✓ |
| p99 interval ≤ 25 ms | 20.36 ✓ | 20.53 ✓ |
| temui encode ≤ 0.5 ms/f (shm), ≤ 2.5 ms/f (zlib) | 0.31 ✓ | 0.60 ✓ |
| terminal CPU ≤ 1.2 × spike 02 paced | 2.52 vs 3.40 (−26 %) ✓\* | 2.10 vs 3.68 (−43 %) ✓\* |

\* Met, but the windows were smaller than spike 02's; see below.

No run fell back from its first transport, and no slots were dropped. Every frame was acknowledged, and no stray input arrived.

## Half-block at a paced 60 fps

The `scroll` scene in a 128×56 cell area. This is spike 02's half-block area, a 2:1 downscale. Every cell changes in every frame, so this is the worst case for changed-cell redraw.

| Terminal | Avg fps | Min fps | p99 ms | temui ms/f | present+write ms/f | Terminal ms/f | Terminal CPU % | Bytes/frame | MB/s | Result |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| Ghostty | 60 | 60 | 21.59 | 2.30 | 3.61 | 7.82 | 47 | 232,467 | 13.9 | PASS |
| Rex | 60 | 60 | 20.15 | 1.23 | 1.81 | 8.54 | 51 | 249,076 | 14.9 | PASS |

- Total CPU per frame (temui plus terminal): half-block 10.1 ms (Ghostty) and 9.8 ms (Rex), against kitty's 2.8 and 2.7 ms.
- Encoding alone takes 0.44 ms/frame (see below). The rest of "present+write" is time spent blocked writing about 240 KB per frame into the pty while the terminal drains it. Ghostty drains more slowly than Rex here.
- Real games change far fewer cells than this scene. For the test core, half-block writes 902 bytes per frame (see below).

## Encode cost (no terminal)

600 frames into a 128×56-cell rect at 10×20 px cells. These are unpaced, so read them as relative costs; the live numbers above are the paced ones.

| Backend | Variant | scroll ms/f | scroll bytes/f | testcore ms/f | testcore bytes/f |
|---|---|--:|--:|--:|--:|
| kitty | shm | 0.048 | 124 | 0.048 | 124 |
| kitty | file | 0.120 | 215 | 0.121 | 215 |
| kitty | inline zlib | 0.527 | 11,926 | 0.542 | 7,413 |
| half-block | truecolor | 0.437 | 265,581 | 0.134 | 902 |
| ASCII | truecolor | 0.256 | 136,735 | 0.117 | 763 |
| ASCII | 256-colour | 0.195 | 43,246 | 0.129 | 542 |
| ASCII | none | 0.137 | 11,800 | 0.114 | 200 |

The temp-file transport's worst frame was 0.7–1.8 ms, against a mean of 0.12 ms: a filesystem write occasionally stalls. shm has no such tail, which is another reason it comes first where the terminal handles it well.

## Comparison with spike 02

The terminal-CPU target compares against spike 02's paced runs, but those ran in larger windows. The terminal scales each frame to the placement's pixel area, so its cost depends on that area:

| | Spike 02 window | This run | Pixel area |
|---|---|---|--:|
| Ghostty | 3432×2096 px (15×32 px cells) | 1268×1374 px (7×16) | 24 % |
| Rex | 3375×1972 px (15×29) | 2264×1170 px (8×15) | 40 % |

temui's own CPU was also lower than termbench's in spike 02 (zlib 0.60 against 2.17 ms/frame), although both use the same zlib level (`.fastest`). To tell a code difference from an environment difference, termbench and temui-bench ran back to back in the same visible Rex pane (156×42 cells, 1248×630 px), with paced inline zlib:

| Same Rex pane | Min fps | p99 ms | Own CPU ms/f | Terminal ms/f |
|---|--:|--:|--:|--:|
| termbench (`--fps 60 --double-buffer --no-overlay`) | 50 | 20.86 | 0.59 | 2.25 |
| temui-bench | 60 | 20.57 | 0.59 | 2.29 |

- **temui costs the same as the spike's code** for both its own CPU and the terminal's. The differences from spike 02 come from the environment: window pixel area for the terminal, and the machine's state for the encoder. Spike 02 saw a 4–6× paced-versus-unpaced gap in termbench's CPU and attributed it to the CPU clocking down. Today temui's paced and unpaced zlib costs are almost equal (0.60 against 0.53 ms). Why the two days differ is not known.
- **termbench's pacing has a drift bug**, which explains its 50 fps here. After spike 02, its "drop missed slots" fix re-bases the schedule on the current time (`max(due, now) + period`), so every late wake-up pushes all later frames back. temui-bench keeps the schedule's phase and drops only whole missed slots. Spike 02's published paced runs predate that fix, so they are unaffected.
- A like-for-like terminal-CPU check needs a run in spike 02's window sizes. It isn't required: the terminal-CPU target depends on the terminal, and both terminals came in under it.

## Not measured

- kitty, WezTerm, tmux and SSH (not available). Detection for kitty, WezTerm, tmux and a dumb terminal is covered by unit tests on recorded replies.
- The ASCII backend live, and the `sprites` and `testcore` sources live. Encode numbers only.
- GPU time, and other machines.
- No visual (smoothness) check was recorded for these runs.

## Re-running after item 05

Since item 05, every kitty placement carries a z-index (`z=-1073741825` by default; [D7](../decisions.md#d7-rendering--one-renderer-interface-three-backends-auto-selected)), so the play loop's overlay can draw over the image. `temui-bench` builds its renderer from the same detected choice, so its kitty runs send the `z=` key too, while the numbers above were measured without it. The key adds a few bytes per frame; whether a terminal composites a negative-z image differently, and so changes its CPU cost, has not been measured. Bear that in mind before comparing a new run with these results.
