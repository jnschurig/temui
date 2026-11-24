# Spike 02 — run notes (2026-11-24 UTC)

Machine: Apple M2 Max (Mac14,6), macOS 26.7.3. termbench built `-Dtermbench-optimize` default (`fast`).
Other apps closed during runs.

| File | Terminal | Window | Notes |
|---|---|---|---|
| `rex-detect.json`, `rex-run.jsonl` | Rex 0.1.0-preview.19 | 225×68 cells, 3375×1972 px | full matrix, 10 s cells, started via `rex` CLI in a watched tab |
| `ghostty-detect.json`, `ghostty-run.jsonl` | Ghostty 1.4.0 | 245×65 cells, 3432×2096 px | full matrix, 10 s cells, `open -na Ghostty.app --args -e …` |
| `ghostty-double-buffer.jsonl` | Ghostty 1.4.0 | 245×65 cells | `--double-buffer`, inline-rgb + inline-rgba, 256×224 scroll, 5 s |

Window sizes differ because Ghostty ignored `--window-width/--window-height` (likely restored window state).
Both exceed the 160×61 minimum, so half-block cells drew the same fixed cell area; kitty cells scale to a slightly different pixel area.

## Visual observations (user watching)

- **Rex:** smooth, no flicker, in every cell. At unpaced rates (hundreds to thousands of fps) the animation is too fast to be pleasant to watch; most frames are never painted, since the display refreshes at a much lower rate.
- **Ghostty, single image id (default):** the inline raw modes (inline-rgb, inline-rgba) flickered badly, severe enough to be a photosensitive-seizure risk. Other modes were fairly smooth.
- **Ghostty, `--double-buffer`** (alternate image ids 1/2, delete the previous placement after placing the new one): much smoother, no flicker noticed. Throughput unchanged (inline-rgb 1295 vs 1297 fps; inline-rgba 986 vs 979 fps).

## Not done

- Run-to-run repeat of surprising cells (Ghostty shm 256×224 scroll at ~26k fps; Rex half-diff 256×224 scroll min 561 vs avg 655): skipped; within-cell 1-s windows are tight.

## Paced runs (`--fps 60 --double-buffer`, 256×224 scroll, kitty transports, 10 s)

- `rex-paced.jsonl` (Rex, 225×68) and `ghostty-paced.jsonl` (Ghostty, 245×65): every transport held 60 fps. These give the per-frame cost when every frame is painted; see the results doc.
- Visual (user watching): Rex: shm, inline-rgb and (probably) file a little stuttery; zlib and rgba smooth. Ghostty: shm, inline-rgb and inline-zlib stuttered a tiny bit; file and rgba smooth. p99 intervals were 20–21 ms everywhere (nominal 16.7 ms); termbench's sleep-based pacing may contribute.

## Incident

At 20:20 local time a termbench run started in Ghostty (245×65) with the original Rex command, probably recalled from shell history, and overwrote `rex-detect.json` / `rex-run.jsonl`. It was interrupted after one cell. The files were restored from commit `fc90c6a` (the real Rex run).
