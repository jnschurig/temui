# Spike 02 — Terminal graphics throughput

Roadmap item [02](../roadmap/02-spike-terminal-graphics.md). Decision affected: [D7](../decisions.md#d7-rendering--one-renderer-interface-three-backends-auto-selected). Raw data and run notes: [`02-data/`](02-data/).

## Summary

- **Ghostty 1.4.0 and Rex 0.1.0-preview.19 both pass 60 fps with every transport**, at both resolutions, in both scenes: all 28 cells pass in each terminal. Unpaced, every kitty-graphics transport reaches 500 fps or more. Rex's reported slow kitty-graphics frame rates did not reproduce here.
- **Use two image ids and alternate between them.** If every frame re-sends the same image id, Ghostty flickers badly on the inline raw modes, bad enough to be a photosensitivity hazard. With two ids, where each frame goes to the other id and the previous placement is deleted afterwards, no flicker was seen and fps was unchanged.
- **Recommended transport:**
  - **Ghostty: shared memory**, falling back to temp file, then inline zlib. At 60 fps this is the cheapest option overall: 0.3 ms of termbench CPU plus 3.4 ms of terminal CPU per frame.
  - **Rex: inline zlib.** Rex's terminal CPU for shm and file is about twice zlib's (6.9–7.1 against 3.7 ms per frame). That reverses D7's order for Rex.
- **Raw inline RGB/RGBA is never the best choice.** It costs 2× the terminal CPU of zlib and 20× the bytes.
- **Half-block is not needed as Rex's default.** It passes everywhere, but kitty graphics gives full resolution at lower terminal CPU.
- **Detection:** both terminals answer every query (kitty graphics, kitty keyboard, DECRQSS, `CSI 14/16 t`, XTVERSION, DA1) in under 0.3 ms. The recommended detection timeout is 500 ms, ended early by a DA1 reply.

## Method

| | |
|---|---|
| Machine | Apple M2 Max (Mac14,6), macOS 26.7.3, other apps closed |
| Terminals | Rex 0.1.0-preview.19 (app + server); Ghostty 1.4.0 |
| Window | Rex 225×68 cells, 3375×1972 px; Ghostty 245×65 cells, 3432×2096 px. Ghostty ignored `--window-width/height`, so the sizes differ. Both exceed the 160×61 minimum, so half-block drew the same fixed cell area in both; kitty frames scale to a slightly different pixel area. |
| Benchmark | `spikes/termbench` (Zig 0.17.1, `ReleaseFast`), commit `fc90c6a` |
| Date | 2026-11-24 |

**What runs.** For each matrix cell (resolution × scene × transport), termbench pre-renders a 128-frame seamless loop. Then, for 10 s, it encodes and writes frames as fast as the terminal accepts them, following each frame with a `CSI 5 n` status request. The two resolutions are 256×224 and 320×240. The two scenes are `scroll`, a tiled background that moves 1 px per frame so every pixel changes, and `sprites`, a static background with 6 moving 32×32 sprites so about 10% of pixels change. The terminal answers the status requests in order; a reader thread timestamps each answer, and one answer counts as one acknowledged frame. The writer blocks when 8 frames are unacknowledged. Kitty frames are sent at native resolution and scaled by the terminal to fill the window. Half-block frames are downscaled 2:1 to a fixed cell area: 128×56 or 160×60.

- **fps:** acknowledged frames per second. Min and max are taken over 1-s windows. **PASS** means every 1-s window had at least 60 acknowledged frames.
- **p99 ms:** the 99th-percentile interval between acknowledgements, a stutter indicator.
- **CPU:** user+sys time from `proc_pid_rusage`. termbench's own time is shown for comparison. Terminal time is summed over the terminal's processes: Rex's server `rex` plus its app `Rex`, and Ghostty's `ghostty`.
- **MB/s:** bytes written to the pty, including status-bar updates of about 100 B at 4 Hz.

**Limits.**
- An acknowledgement means the terminal *parsed* the frame, not that it painted it. Unpaced, most frames are never painted, because the display refreshes far below 1,000 fps. Unpaced fps therefore measures parsing headroom, and unpaced ms/frame understates the cost at 60 fps.
- To fill that gap, the **paced** runs (`--fps 60 --double-buffer`, kitty transports, 256×224 scroll) measure the real cost when every frame is painted. **Use the paced numbers for CPU budgets.**
- GPU time is not measured.
- termbench's own CPU per frame is 4–6× higher paced than unpaced (zlib 2.1 against 0.6 ms; shm 0.3 against 0.05 ms). The likely cause is that the CPU clocks down between frames. A real renderer pays the paced cost.
- The paced runs scheduled frames on a fixed clock (`start + n × period`). After a hiccup, termbench sent the late frames back to back to catch up, so a short stall can still give 60 acks in its 1-s window. Paced min fps of 60 is therefore optimistic, and the p99 interval is the better stutter signal. termbench now drops missed slots instead (fixed after these runs).
- Each matrix cell ran once. Within each cell, the slowest 1-s window was within about 10% of the average, so cells were not repeated.

**Reproduce** (macOS only):

```sh
zig build termbench                      # → zig-out/bin/termbench (not built by `zig build`)
zig-out/bin/termbench detect --out detect.json
zig-out/bin/termbench --out run.jsonl    # full matrix, ~5 min; see --help for subsets
zig-out/bin/termbench --fps 60 --double-buffer --res 256x224 --scene scroll \
  --transport inline-rgb,inline-rgba,inline-zlib,file,shm --out paced.jsonl
```

> **Photosensitivity warning.** The default matrix sends a single image id unpaced, and in Ghostty that flashes rapidly. Use `--double-buffer`, `--fps 60`, or a small window when watching.

## Results at 60 fps (paced, every frame painted)

256×224 scroll, `--double-buffer`, 10 s per cell.

**Rex**

| Transport | Res | Scene | Avg fps | Min fps | p99 ms | termbench ms/f | Terminal CPU % | Terminal ms/f | MB/s | 60 fps |
|---|---|---|--:|--:|--:|--:|--:|--:|--:|---|
| inline-rgb | 256x224 | scroll | 60 | 60 | 21.44 | 1.89 | 41 | 6.81 | 13.8 | PASS |
| inline-rgba | 256x224 | scroll | 60 | 60 | 20.31 | 2.32 | 50 | 8.38 | 18.4 | PASS |
| inline-zlib | 256x224 | scroll | 60 | 60 | 20.46 | 2.17 | 22 | 3.68 | 0.7 | PASS |
| file | 256x224 | scroll | 60 | 60 | 21.33 | 1.15 | 43 | 7.11 | 0 | PASS |
| shm | 256x224 | scroll | 60 | 60 | 20.94 | 0.31 | 41 | 6.86 | 0 | PASS |

**Ghostty**

| Transport | Res | Scene | Avg fps | Min fps | p99 ms | termbench ms/f | Terminal CPU % | Terminal ms/f | MB/s | 60 fps |
|---|---|---|--:|--:|--:|--:|--:|--:|--:|---|
| inline-rgb | 256x224 | scroll | 60 | 60 | 20.45 | 2.08 | 39 | 6.54 | 13.8 | PASS |
| inline-rgba | 256x224 | scroll | 60 | 60 | 20.88 | 2.47 | 44 | 7.32 | 18.4 | PASS |
| inline-zlib | 256x224 | scroll | 60 | 60 | 21.18 | 2.14 | 20 | 3.26 | 0.7 | PASS |
| file | 256x224 | scroll | 60 | 60 | 20.04 | 1.24 | 23 | 3.85 | 0 | PASS |
| shm | 256x224 | scroll | 60 | 60 | 20.45 | 0.3 | 20 | 3.4 | 0 | PASS |

Total CPU per frame at 60 fps (termbench plus terminal, rounded):

| Transport | Rex | Ghostty |
|---|--:|--:|
| shm | 7.2 ms | **3.7 ms** |
| file | 8.3 ms | 5.1 ms |
| inline zlib | **5.9 ms** | 5.4 ms |
| inline RGB | 8.7 ms | 8.6 ms |
| inline RGBA | 10.7 ms | 9.8 ms |

In Rex, shm and file cost about as much terminal CPU as raw inline data. A likely explanation is that the Rex server reads the file or shared memory itself and passes the pixels to the app uncompressed: decisions.md records that the server rewrites local reads for remote clients. That explanation was not confirmed.

## Results unpaced (capacity)

10 s per cell, a single image id (the default), full matrix.

**Rex**

| Transport | Res | Scene | Avg fps | Min fps | p99 ms | termbench ms/f | Terminal CPU % | Terminal ms/f | MB/s | 60 fps |
|---|---|---|--:|--:|--:|--:|--:|--:|--:|---|
| inline-rgb | 256x224 | scroll | 969 | 929 | 1.81 | 0.6 | 142 | 1.47 | 222.9 | PASS |
| inline-rgba | 256x224 | scroll | 684 | 649 | 2.46 | 0.83 | 140 | 2.04 | 209.8 | PASS |
| inline-zlib | 256x224 | scroll | 1749 | 1682 | 0.69 | 0.56 | 69 | 0.4 | 20.8 | PASS |
| file | 256x224 | scroll | 3206 | 3057 | 0.59 | 0.15 | 305 | 0.95 | 0.6 | PASS |
| shm | 256x224 | scroll | 4214 | 4069 | 0.5 | 0.05 | 370 | 0.88 | 0.4 | PASS |
| half-full | 256x224 | scroll | 698 | 659 | 2.44 | 0.96 | 160 | 2.29 | 185.1 | PASS |
| half-diff | 256x224 | scroll | 655 | 561 | 2.55 | 0.99 | 162 | 2.47 | 173.7 | PASS |
| inline-rgb | 256x224 | sprites | 1022 | 943 | 1.75 | 0.58 | 139 | 1.36 | 235 | PASS |
| inline-rgba | 256x224 | sprites | 711 | 697 | 2.35 | 0.8 | 140 | 1.97 | 218 | PASS |
| inline-zlib | 256x224 | sprites | 1604 | 1555 | 0.75 | 0.61 | 81 | 0.5 | 24 | PASS |
| file | 256x224 | sprites | 3199 | 3155 | 0.59 | 0.15 | 302 | 0.94 | 0.6 | PASS |
| shm | 256x224 | sprites | 4073 | 3945 | 0.51 | 0.05 | 370 | 0.91 | 0.4 | PASS |
| half-full | 256x224 | sprites | 555 | 546 | 2.4 | 1.08 | 177 | 3.19 | 141 | PASS |
| half-diff | 256x224 | sprites | 5930 | 5731 | 0.26 | 0.12 | 192 | 0.32 | 113 | PASS |
| inline-rgb | 320x240 | scroll | 704 | 679 | 2.36 | 0.82 | 139 | 1.98 | 216.9 | PASS |
| inline-rgba | 320x240 | scroll | 515 | 499 | 3.12 | 1.1 | 141 | 2.74 | 211.4 | PASS |
| inline-zlib | 320x240 | scroll | 1294 | 1253 | 0.9 | 0.76 | 75 | 0.58 | 17.9 | PASS |
| file | 320x240 | scroll | 2569 | 2509 | 0.71 | 0.16 | 309 | 1.2 | 0.5 | PASS |
| shm | 320x240 | scroll | 3063 | 2969 | 0.7 | 0.06 | 360 | 1.17 | 0.3 | PASS |
| half-full | 320x240 | scroll | 427 | 412 | 3.56 | 1.45 | 178 | 4.17 | 151.7 | PASS |
| half-diff | 320x240 | scroll | 427 | 403 | 3.37 | 1.46 | 178 | 4.17 | 151.5 | PASS |
| inline-rgb | 320x240 | sprites | 768 | 698 | 2.33 | 0.78 | 137 | 1.78 | 236.4 | PASS |
| inline-rgba | 320x240 | sprites | 535 | 513 | 3.12 | 1.08 | 142 | 2.65 | 219.6 | PASS |
| inline-zlib | 320x240 | sprites | 1222 | 1171 | 0.97 | 0.8 | 83 | 0.68 | 20.9 | PASS |
| file | 320x240 | sprites | 2573 | 2522 | 0.7 | 0.16 | 311 | 1.21 | 0.5 | PASS |
| shm | 320x240 | sprites | 3060 | 2959 | 0.69 | 0.06 | 360 | 1.18 | 0.3 | PASS |
| half-full | 320x240 | sprites | 423 | 413 | 3.22 | 1.42 | 181 | 4.28 | 145.4 | PASS |
| half-diff | 320x240 | sprites | 5557 | 5363 | 0.27 | 0.13 | 190 | 0.34 | 112.3 | PASS |

**Ghostty**

| Transport | Res | Scene | Avg fps | Min fps | p99 ms | termbench ms/f | Terminal CPU % | Terminal ms/f | MB/s | 60 fps |
|---|---|---|--:|--:|--:|--:|--:|--:|--:|---|
| inline-rgb | 256x224 | scroll | 1298 | 1255 | 0.96 | 0.52 | 112 | 0.86 | 298.4 | PASS |
| inline-rgba | 256x224 | scroll | 980 | 951 | 1.24 | 0.68 | 111 | 1.13 | 300.3 | PASS |
| inline-zlib | 256x224 | scroll | 1702 | 1665 | 0.67 | 0.58 | 27 | 0.16 | 20.3 | PASS |
| file | 256x224 | scroll | 8716 | 8424 | 0.22 | 0.12 | 111 | 0.13 | 1.7 | PASS |
| shm | 256x224 | scroll | 25890 | 25202 | 0.1 | 0.04 | 149 | 0.06 | 2.6 | PASS |
| half-full | 256x224 | scroll | 830 | 802 | 1.7 | 0.92 | 235 | 2.83 | 220 | PASS |
| half-diff | 256x224 | scroll | 829 | 805 | 1.69 | 0.92 | 234 | 2.83 | 219.8 | PASS |
| inline-rgb | 256x224 | sprites | 1274 | 1246 | 0.97 | 0.52 | 112 | 0.88 | 293 | PASS |
| inline-rgba | 256x224 | sprites | 964 | 941 | 1.28 | 0.69 | 111 | 1.15 | 295.5 | PASS |
| inline-zlib | 256x224 | sprites | 1528 | 1478 | 0.79 | 0.64 | 31 | 0.2 | 22.9 | PASS |
| file | 256x224 | sprites | 8987 | 8872 | 0.18 | 0.11 | 110 | 0.12 | 1.8 | PASS |
| shm | 256x224 | sprites | 26026 | 25504 | 0.1 | 0.04 | 150 | 0.06 | 2.6 | PASS |
| half-full | 256x224 | sprites | 865 | 850 | 1.57 | 0.88 | 243 | 2.81 | 219.6 | PASS |
| half-diff | 256x224 | sprites | 7610 | 7405 | 0.29 | 0.11 | 239 | 0.31 | 145 | PASS |
| inline-rgb | 320x240 | scroll | 937 | 898 | 1.63 | 0.7 | 112 | 1.19 | 288.4 | PASS |
| inline-rgba | 320x240 | scroll | 711 | 685 | 2.28 | 0.92 | 111 | 1.56 | 292.1 | PASS |
| inline-zlib | 320x240 | scroll | 1278 | 1254 | 0.93 | 0.77 | 24 | 0.18 | 17.6 | PASS |
| file | 320x240 | scroll | 7974 | 7617 | 0.21 | 0.12 | 104 | 0.13 | 1.6 | PASS |
| shm | 320x240 | scroll | 21142 | 20856 | 0.13 | 0.05 | 141 | 0.07 | 2.1 | PASS |
| half-full | 320x240 | scroll | 628 | 608 | 1.9 | 1.21 | 225 | 3.58 | 223.1 | PASS |
| half-diff | 320x240 | scroll | 623 | 605 | 2 | 1.22 | 224 | 3.59 | 221.2 | PASS |
| inline-rgb | 320x240 | sprites | 959 | 940 | 1.28 | 0.69 | 111 | 1.15 | 295.4 | PASS |
| inline-rgba | 320x240 | sprites | 721 | 701 | 2.14 | 0.91 | 110 | 1.53 | 296.1 | PASS |
| inline-zlib | 320x240 | sprites | 1219 | 1164 | 0.92 | 0.8 | 26 | 0.21 | 20.8 | PASS |
| file | 320x240 | sprites | 8015 | 7672 | 0.21 | 0.12 | 104 | 0.13 | 1.6 | PASS |
| shm | 320x240 | sprites | 20536 | 20089 | 0.13 | 0.05 | 143 | 0.07 | 2.1 | PASS |
| half-full | 320x240 | sprites | 631 | 611 | 2.1 | 1.2 | 230 | 3.64 | 216.6 | PASS |
| half-diff | 320x240 | sprites | 6543 | 6228 | 0.31 | 0.12 | 231 | 0.35 | 132.3 | PASS |

**Ghostty with `--double-buffer`** (256×224 scroll, 5 s). Throughput is the same as with a single image id:

| Transport | Res | Scene | Avg fps | Min fps | p99 ms | termbench ms/f | Terminal CPU % | Terminal ms/f | MB/s | 60 fps |
|---|---|---|--:|--:|--:|--:|--:|--:|--:|---|
| inline-rgb | 256x224 | scroll | 1296 | 1257 | 0.99 | 0.51 | 113 | 0.88 | 298 | PASS |
| inline-rgba | 256x224 | scroll | 987 | 981 | 1.25 | 0.67 | 113 | 1.14 | 302.5 | PASS |

Notes on the unpaced numbers:
- **Ghostty shm and file (8,000–26,000 fps, 0.06–0.13 ms per frame):** Ghostty acknowledges a frame once it has read the data, so these figures measure parsing, not painting. The paced numbers are the real costs.
- **Half-block, changed cells only:** this pays off only in the `sprites` scene (5,500–7,600 fps). In `scroll` every cell changes, so it costs the same as a full redraw.
- **Half-block, full redraw:** it reaches 420–870 fps but writes 140–220 MB/s, and its terminal CPU per frame (2.3–4.3 ms unpaced) is already at or above paced kitty zlib. Half-block was not measured paced.

## Visual check

These are observations from a person watching the runs.

- **Rex:** smooth with no flicker in every cell, with a single image id. Unpaced rates are too fast to be pleasant to watch.
- **Ghostty, single image id:** inline-rgb and inline-rgba flickered severely, enough to be a seizure risk for photosensitive viewers. The other modes were fairly smooth.
- **Ghostty, `--double-buffer`:** much smoother, with no flicker seen. The visible stutter overrides those cells' PASS: in Ghostty, a single image id is not acceptable.
- **Paced 60 fps (`--fps 60 --double-buffer`):**
  - Rex: shm, inline-rgb and probably file looked a little stuttery; inline-zlib and inline-rgba looked smooth.
  - Ghostty: shm, inline-rgb and inline-zlib stuttered a tiny bit; file and inline-rgba looked smooth.
  - This matches the p99 frame interval of 20–21 ms against a nominal 16.7 ms in every paced cell.
  - Part of this jitter may come from termbench's own pacing, which sleeps to the next tick and is not vsync-aligned. One viewing cannot separate termbench's jitter from the terminal's. Item 04 should measure frame pacing with temui's real presentation loop.

## Recommendation

| Terminal | Renderer | Transport order | Notes |
|---|---|---|---|
| Ghostty | kitty graphics | shm → file → inline zlib | double-buffer required (two image ids) |
| Rex | kitty graphics | **inline zlib** first; shm/file not preferred | double-buffer anyway (cheap, and Rex may change); half-block not needed |
| kitty, WezTerm | kitty graphics | D7 default (shm → file → inline zlib) | **not measured** |
| SSH (any) | kitty graphics | inline zlib (shm and file are local-only) | **not measured** |
| tmux | — | — | **not measured** |

Why:
- In Rex, inline zlib is both the cheapest transport and one of the two that looked smooth when paced. In Ghostty, shm and zlib both stuttered a tiny bit, so the visual check doesn't separate them; shm keeps first place on cost.
- At 60 fps the cheapest transport differs by terminal: shm in Ghostty, zlib in Rex. So the transport order should be a per-terminal preference, not one global order.
- zlib is never far from the best (5.4–5.9 ms total per frame) and works remotely, so it should be the fallback everywhere.
- Raw inline RGB/RGBA is dominated by zlib in both terminals, so it should not be in the fallback chain.
- In Ghostty, a single image id flickers, which is a correctness and safety problem, not only a performance one. Double-buffering costs nothing measurable, so the renderer should always do it.

**Targets for item 04's benchmark** (256×224 at 60 fps on this machine):
- min fps 60 in every 1-s window
- p99 frame interval ≤ 25 ms (measured here: 20–21 ms)
- temui's encode CPU ≤ 2.5 ms/frame for zlib and ≤ 0.5 ms/frame for shm
- terminal CPU within 20% of the paced numbers above.

## Detection

Both terminals answered every query. Latencies are measured from the query to its reply.

| Query | Rex reply | Rex ms | Ghostty reply | Ghostty ms |
|---|---|--:|---|--:|
| da1 (baseline) | `\e[?62;22c` | 0.048 | `\e[?62;22;52c` | 0.255 |
| kitty graphics a=q | `\e_Gi=31;OK\e\` | 0.052 | `\e_Gi=31;OK\e\` | 0.12 |
| kitty keyboard CSI ? u | `\e[?0u` | 0.025 | `\e[?0u` | 0.06 |
| DECRQSS SGR truecolor | `\eP1$r0;48:2::1:2:3m\e\` | 0.036 | `\eP1$r0;48:2::1:2:3m\e\` | 0.091 |
| text area px CSI 14 t | `\e[4;1972;3375t` | 0.027 | `\e[4;2080;3430t` | 0.068 |
| cell px CSI 16 t | `\e[6;29;15t` | 0.029 | `\e[6;32;14t` | 0.04 |
| XTVERSION CSI > q | `\eP>\|rex 0.1.0-preview.19\e\` | 0.03 | `\eP>\|ghostty 1.4.0\e\` | 0.054 |

Environment: Rex sets `TERM=xterm-256color`, `TERM_PROGRAM=rex`, `COLORTERM=truecolor`. Ghostty sets `TERM=xterm-ghostty`, `TERM_PROGRAM=ghostty`, `COLORTERM=truecolor`. `TIOCGWINSZ` pixel sizes match `CSI 14 t` exactly in Rex. In Ghostty they differ by 2×16 px (3432×2096 against 3430×2080), probably window padding.

Notes for item 04:
- **Identify the terminal with XTVERSION** (`rex …`, `ghostty …`). It answers even when `TERM_PROGRAM` isn't passed through, for example over SSH, so use it to pick the per-terminal transport preference.
- **Use `CSI 16 t` for the cell size.** `TIOCGWINSZ` gives only the whole-window pixel size, so the cell size has to be divided out, and Ghostty's then comes out fractional (14.0×32.2).
- **Kitty keyboard:** both answer `CSI ? u` with flags 0, meaning supported but not enabled.
- **Timeout:** send all queries followed by DA1, and stop at the DA1 reply. The worst latency observed was 0.26 ms (Ghostty's DA1). Use **500 ms** as the hard timeout: about 2,000× the local worst case, with room for SSH round trips. Over SSH, latency is **not measured**.

## Not measured

- kitty and WezTerm: not installed on the measuring machine.
- SSH, and tmux passthrough.
- GPU time, and other machines.
- Half-block at a paced 60 fps.
