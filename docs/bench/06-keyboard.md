# Item 06 — Keyboard input and modes verification

Roadmap item [06](../roadmap/06-keyboard-input-and-modes.md). Decisions: [D9](../decisions.md#d9-input--kitty-keyboard-protocol-windows-console-input-sdl3-gamepads), [D13](../decisions.md#d13-observability--file-logs-optional-stats-overlay), [D15](../decisions.md#d15-interaction-model--modal-game-mode--tui-mode). Raw data: [`06-data/`](06-data/).

## Summary

- **Holds are exact on the kitty path in Rex.** A held key's button stays down until its release event arrives, and no longer. Two keys held at once both stay down. A mode switch releases every button, and a key held through the return to game mode stays released until it is pressed again.
- **The modes work as specified.** Esc and Ctrl-] enter TUI mode, `i` and Enter go back, Space opens the menu and Esc closes it, `p`, `.` and `o` act, and quitting needs Space `q` Enter or two Ctrl-Cs. Focus-out releases held buttons.
- **`--keyboard legacy`** shows the `LEGACY` flag, and a tap holds its button briefly: lit in a shot taken right after it, clear 0.3 s later.
- **Game input disabled** (Rex through GNU screen, which doesn't answer the kitty query): `play` starts in TUI mode with the red `GAME MODE DISABLED` flag. `i`, Enter and Ctrl-] show the notice, which expires after 3 s. Ctrl-C replaces it, and the menu has no `i` entry.
- **The watchdog** quits a hung test core on two Ctrl-Cs: exit 130, `temui: not responding; quit` on stderr, and the terminal is back on the primary screen with the cursor visible.
- **Ghostty matches Rex** on the same checks, by hand with real key holds. A Cmd-Tab while holding releases every button, and a Cmd-V paste is discarded (`paste: 17 bytes discarded`). Turning the protocol off from outside (`printf '\033[<u' > tty`) gives the input-lost box on the next key: buttons released, game paused, game mode refused after. snes9x 1.63 with Super Mario World played for 2.5 minutes with no stuck or dropped buttons.
- **Terminal.app** starts with game input disabled (no reply to the kitty query, half-block renderer), refuses game mode with the notice, and its menu and quit work.
- **The watchdog in Ghostty** quits a hung core the same way (exit 130, the stderr line, the terminal restored). The first checklist run passed a value the test core doesn't accept (`temui_test_hang_after=120`; it takes 0, 1, 30, 60 or 300), so the core never hung and the two Ctrl-Cs took the normal quit path (exit 0). It was rerun with 60, which the checklist now uses.

## Method

| | |
|---|---|
| Machine | Apple M2 Max, macOS 26.7.3 |
| Terminals | Ghostty 1.4.0 (kitty keyboard flags 15 acknowledged); Terminal.app (macOS 26.7.3; no kitty query reply); Rex (server 0.1.0-preview.19, app 0.1.0-preview.35; kitty keyboard flags 15 acknowledged; 72×68 cells); Rex through GNU screen 4.00 for the disabled path (screen doesn't answer the kitty query, so detection times out, and the renderer falls back to half-block) |
| Build | `zig build -Doptimize=ReleaseFast`, branch `keyboard-input` |
| Core | The in-repo test core. It lights one box per RetroPad button in the bottom row, so a screenshot shows exactly which buttons the core sees as down |
| Date | 2026-11-26 to 2026-11-27 |

**Rex** runs were driven by [`06-data/rex-drive.sh`](06-data/rex-drive.sh). It starts `temui play --verbose` in a pane split beside the caller's, sends keys with `rex send-key` (`--action press` and `--action release` for holds, so the kitty path sees real press and release events), moves focus with `rex focus`, and takes a screenshot of the Rex window after each action with `screencapture -l`. The montages in `06-data/rex-*.jpg` show each scenario's shots in order. The logs (`06-data/rex-*.log`, home paths redacted) record each raw read (`input: "…"`) and each decoded key.

**Ghostty and Terminal.app** were checked by hand with [`06-data/checklist.sh`](06-data/checklist.sh), which runs each scenario and says what to press and what to expect.

**Reproduce:** `zig build -Doptimize=ReleaseFast`. In Rex, run `docs/bench/06-data/rex-drive.sh OUTDIR WINDOW SCENARIO [play args]`, where `WINDOW` is the Rex window's CGWindowID and `SCENARIO` is `basic`, `legacy` (add `--keyboard legacy`), `disabled` (set `WRAP="screen -q"`), `hang` (add `--option temui_test_hang_after=60`) or `focus`. Elsewhere, run `docs/bench/06-data/checklist.sh ghostty [ROM]` or `checklist.sh terminal`.

## Results

### Rex, kitty path

| Check | Result | Shot ([`rex-basic.jpg`](06-data/rex-basic.jpg)) |
|---|---|---|
| Hold `e` 0.8 s: Up's box lit | ✓ | 2 |
| Release `e`: cleared at once | ✓ | 3 |
| Hold `e` and `f`: both lit | ✓ | 4 |
| Esc: TUI mode, `TUI  Space: menu` | ✓ | 5 |
| `p`: paused; `.`: one frame; `p`: resumed | ✓ | 6, 7 |
| `o`: detailed stats in the status line | ✓ | 8 |
| Space: menu (`p . + - 0 o i q`); Esc closes it | ✓ | 9, 10 |
| `i`: game mode | ✓ | 11 |
| Ctrl-]: TUI mode; Enter: game mode | ✓ | 12 |
| Hold `j`, Ctrl-]: Y's box cleared; release, `i`: still clear | ✓ | 13, 14 |
| Ctrl-C: `Press Ctrl-C again to quit`; the game keeps running | ✓ | 15 |
| Space `q`: `Quit? Enter to confirm, any other key cancels`; Enter quits, exit 0 | ✓ | 17 |
| Focus-out while holding `e` releases it (`focus lost: releasing every button`) | ✓ | [`rex-focus.log`](06-data/rex-focus.log) |

Rex sends two focus-out reports when focus moves to another pane. Both are handled, and the second does nothing.

### Rex, `--keyboard legacy` ([`rex-legacy.jpg`](06-data/rex-legacy.jpg))

The `LEGACY` flag shows in game mode with no box. A tap of `e` (Rex sends a plain `e` byte, since nothing was pushed) is lit in a shot taken right after it and clear 0.3 s later (the hold is 100 ms; the shots can't time it more finely). Ctrl-] enters TUI mode, and Space `q` Enter quits.

### Rex through screen, game input disabled ([`rex-disabled.jpg`](06-data/rex-disabled.jpg))

| Check | Result | Shot |
|---|---|---|
| Starts in TUI mode with the white-on-red `GAME MODE DISABLED` flag; `keyboard: disabled` and the warn line logged | ✓ | 1 |
| `i` shows the three-line notice | ✓ | 2 |
| The notice expires after 3 s | ✓ | 3 |
| Ctrl-] (and Enter, logged) show it again | ✓ | 4 |
| Ctrl-C replaces it with the Ctrl-C prompt | ✓ | 5 |
| Space: the menu, without `i` | ✓ | 6 |

The image is garbled under screen 4.00, which doesn't pass half-block truecolor cells through cleanly; that is screen's limitation, not temui's. An earlier run found that Esc followed at once by Ctrl-] decodes as Ctrl-Alt-]. That is the usual legacy rule (ESC then a byte within the timeout is Alt), and it isn't the mode-key chord.

### Rex, watchdog ([`rex-hang.jpg`](06-data/rex-hang.jpg))

`--option temui_test_hang_after=60` hangs the core at frame 60. Two Ctrl-Cs 0.2 s apart, then the process exits 130 and `temui: not responding; quit` is on the pane.

### Ghostty (by hand, [`checklist.sh`](06-data/checklist.sh))

| Check | Result |
|---|---|
| Holds of `e` `s` `d` `f`, one and two at once: lit while held, clear on release | ✓ |
| Esc, Ctrl-], `i`, Enter, `p`, `.`, `o`, the menu, the Ctrl-C prompt | ✓ |
| A key held through Ctrl-] stays released after the return | ✓ |
| Cmd-Tab while holding: `focus lost: releasing every button` | ✓ |
| Cmd-V: `paste: 17 bytes discarded`, nothing acted | ✓ |
| `--keyboard legacy`: `LEGACY` flag, a tap flashes its box, a hold stays lit | ✓ |
| Input lost (`--keyboard kitty`, then `CSI < u` written to the tty from another window): the next key gives `the kitty keyboard protocol isn't active`, the input-lost box, a pause, and `GAME MODE DISABLED`; `i` is refused after | ✓ |
| snes9x 1.63, Super Mario World, 153.8 s: holds and releases feel right; 9243 frames, 60.10 fps | ✓ |
| Watchdog (`temui_test_hang_after=60`, two Ctrl-Cs): exit 130, `temui: not responding; quit`, terminal usable after; the log ends at load, as `_exit` leaves it | ✓ |

Ghostty sends repeats as `;1:2u` (hundreds in a held run), and often several events in one read (a repeat and the next key's press, or a modifier's release and a focus report). Both are in the recorded fixture.

### Terminal.app (by hand)

`keyboard: disabled (no kitty keyboard protocol detected)` and the warn line are logged. The renderer is half-block. `play` starts in TUI mode with the red flag, `i` shows the notice each time (refused 18 times in the run), Space opens the menu, and Space `q` Enter quits (exit 0).

## Recorded fixtures

The raw reads from these runs are in the decoder tests (`src/term/key_decoder.zig`, `recorded: …`): Ghostty with flags 15 (repeats, several events in one read, Shift with an alternate key, right Ctrl, focus reports, a paste), Rex with flags 15 (press and release of letters, Esc, `.`, Ctrl-], Enter, Ctrl-C, two keys in one read, focus reports), and Rex through screen (legacy bytes).

## Findings

None that needed a code change in this step. The checklist script's hang value was wrong at first (above).
