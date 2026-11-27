#!/bin/sh
# Guided manual checks for roadmap 06 (keyboard input and modes), for the
# parts that need real key holds, focus changes, a paste or a terminal
# without the kitty keyboard protocol. Each run logs at debug level to
# .local/play-logs/06-<tag>/<run>.log. Build first: zig build -Doptimize=ReleaseFast
#   docs/bench/06-data/checklist.sh ghostty  [ROM]   # kitty path; ROM runs snes9x too
#   docs/bench/06-data/checklist.sh terminal         # Terminal.app: game input disabled
set -u
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1
TAG=${1:?usage: checklist.sh ghostty|terminal [ROM]}
L=$PWD/.local/play-logs/06-$TAG
mkdir -p "$L"
BIN=$PWD/zig-out/bin/temui
CORE=$PWD/zig-out/lib/temui_test_libretro.dylib
ROM=$PWD/testdata/testcore.rom
SNES=${SNES_CORE:-$HOME/Library/Application Support/RetroArch/cores/snes9x_libretro.dylib}

step() {
	printf '\n\033[1m== %s\033[0m\n' "$1"
	shift
	for line in "$@"; do printf '   %s\n' "$line"; done
	printf '   Press Enter to start. '
	read -r _
}
play() { name=$1; shift; "$BIN" play "$@" --verbose --log-file "$L/$name.log"; echo "   $name: exit $?" | tee -a "$L/results.txt"; }

: >"$L/results.txt"
if [ "$TAG" = terminal ]; then
	step "1/1 game input disabled" \
		"Expect: TUI mode, red GAME MODE DISABLED flag in the status line." \
		"Press i, then Enter, then Ctrl-]: each shows a 3-line notice for 3 s." \
		"Space opens the menu (no 'i' entry). Quit: Space q Enter."
	play disabled "$ROM" --core "$CORE"
	exit 0
fi

step "1/6 holds and modes (kitty path)" \
	"Hold e, s, d, f one at a time: each lights its box while held, clears at once on release." \
	"Hold two at once: both light." \
	"Esc -> TUI; p pauses, . steps, p resumes; o toggles detailed stats; Space opens the menu, Esc closes it; i -> game." \
	"Ctrl-] -> TUI; Enter -> game." \
	"Hold f, press Ctrl-]: its box clears. Release f, press i: still clear." \
	"Hold f and Cmd-Tab away: its box clears (focus-out). Come back." \
	"Copy some text with letters (e.g. 'eeee q') and paste it (Cmd-V): nothing happens." \
	"Ctrl-C once: 'Press Ctrl-C again to quit'. Let it time out." \
	"Quit: Ctrl-] Space q Enter."
play kitty "$ROM" --core "$CORE"

step "2/6 --keyboard legacy" \
	"Expect: game mode, LEGACY flag, no box." \
	"Tap e: its box lights for about 0.1 s. Hold e: it stays lit (repeats renew it)." \
	"Quit: Ctrl-] Space q Enter."
play legacy "$ROM" --core "$CORE" --keyboard legacy

step "3/6 input lost (--keyboard kitty, then the protocol turned off)" \
	"Once temui is up, in ANOTHER Ghostty window run:  printf '\\033[<u' > $(tty)" \
	"Back in temui press any game key. Expect: the game pauses, an input-lost box, GAME MODE DISABLED flag." \
	"Any key dismisses the box; p resumes; i shows the notice. Quit: Space q Enter."
play input-lost "$ROM" --core "$CORE" --keyboard kitty

step "4/6 watchdog" \
	"The test core hangs after 1 s (the picture freezes). Then press Ctrl-C twice." \
	"Expect: exit 130, 'temui: not responding; quit', terminal restored."
play hang "$ROM" --core "$CORE" --option temui_test_hang_after=60

step "5/6 raw sequences" \
	"For the recorded fixtures: press and release, in order: e, Esc, '.', Ctrl-], Enter, Ctrl-C," \
	"Space, q, an arrow key, Shift-z. Hold e for a second (repeats). Then quit: Ctrl-] Space q Enter."
play raw "$ROM" --core "$CORE"

if [ -n "${2:-}" ]; then
	step "6/6 snes9x" \
		"Play for a minute: walk, jump, hold directions. Holds should feel right, no stuck or dropped buttons." \
		"Try Esc/i and the menu in-game. Quit: Ctrl-] Space q Enter."
	play snes9x "$2" --core "$SNES"
else
	echo "6/6 snes9x skipped (pass a ROM as the second argument)"
fi
echo
cat "$L/results.txt"
echo "Logs: $L"
