#!/bin/sh
# Drives temui in a Rex pane beside the caller's (REX_SESSION/REX_BLOCK) through
# the rex CLI, taking screenshots of the Rex window. Usage:
#   rex-drive.sh OUTDIR REX_WINDOW_NUMBER SCENARIO [temui play args...]
# Scenarios are the functions below. Logs: OUTDIR/SCENARIO.log, shots: OUTDIR/SCENARIO-NN-name.png.
set -u
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1
OUT=$1 WIN=$2 SC=$3; shift 3
mkdir -p "$OUT"
BIN=$PWD/zig-out/bin/temui CORE=$PWD/zig-out/lib/temui_test_libretro.dylib ROM=$PWD/testdata/testcore.rom
n=0
shot() { n=$((n + 1)); screencapture -x -o -l "$WIN" "$OUT/$SC-$(printf %02d $n)-$1.png"; }
key() { rex send-key -s "$REX_SESSION" -b "$B" "$@"; }
pause() { perl -e "select(undef,undef,undef,$1)"; }
B=$(rex split -s "$REX_SESSION" -b "$REX_BLOCK" --split=right --ratio 60 --focus=false --keep-open --json -c "$PWD" -- ${WRAP:-} \
	"$BIN" play "$ROM" --core "$CORE" --verbose --log-file "$OUT/$SC.log" "$@" | jq -r '.block_ids[0]') || exit 1
echo "block $B"
pause 2

basic() {
	shot start
	key --action press e; pause 0.8; shot hold-e
	key --action release e; pause 0.1; shot release-e
	key --action press e; key --action press f; pause 0.5; shot hold-e-f
	key --action release e; key --action release f; pause 0.3
	key escape; pause 0.4; shot tui-esc
	key p; pause 0.4; shot paused
	key "[Period]"; pause 0.3; shot stepped; key p; pause 0.3
	key o; pause 0.4; shot stats
	key o; key space; pause 0.4; shot menu
	key escape; pause 0.3; shot menu-closed
	key i; pause 0.3; shot back-game-i
	key ctrl+]; pause 0.4; shot tui-ctrl-bracket
	key enter; pause 0.3
	key --action press j; pause 0.3; key ctrl+] ; pause 0.4; shot held-through-switch
	key --action release j; key i; pause 0.4; shot back-after-held
	key ctrl+c; pause 0.4; shot ctrl-c-prompt
	key escape; pause 0.4; shot after-esc
	key space q; pause 0.4; shot quit-prompt
	key enter; pause 1
}
legacy() {
	shot start
	key e; pause 0.04; shot tap-e-40ms
	pause 0.3; shot tap-e-340ms
	key ctrl+]; pause 0.4; shot tui
	key space q enter; pause 1
}
disabled() {
	shot start
	key i; pause 0.4; shot notice-i
	pause 3.2; shot notice-expired
	key enter; pause 3.4
	key ctrl+]; pause 0.4; shot notice-ctrl-bracket
	key ctrl+c; pause 0.4; shot ctrl-c-replaces
	key space; pause 0.4; shot menu
	key q enter; pause 1
}
focus() {
	# Focus-out releases held buttons; a real paste (Rex's pane.paste, needs
	# Remote Control) is discarded. Saves and restores the clipboard.
	clip=$(pbpaste)
	rex focus -s "$REX_SESSION" "$B"; pause 0.4
	key --action press e; pause 0.5; shot hold-e-focused
	rex focus -s "$REX_SESSION" "$REX_BLOCK"; pause 0.4; shot focus-out
	key --action release e
	rex focus -s "$REX_SESSION" "$B"; pause 0.4
	printf 'eeee q\r\003\003' | pbcopy
	if [ -n "${REX_CLIENT_ID:-}" ]; then rex -C "$REX_CLIENT_ID" do pane.paste; pause 0.6; shot pasted; fi
	printf '%s' "$clip" | pbcopy
	rex focus -s "$REX_SESSION" "$REX_BLOCK"
	key ctrl+] space q enter; pause 1
}
hang() {
	pause 1.5; shot hung
	key ctrl+c; pause 0.2; key ctrl+c; pause 1.5; shot after-ctrl-c
}
"$SC"
rex block call -s "$REX_SESSION" -b "$B" process | jq -c '{running, last_exit}'
rex capture -s "$REX_SESSION" -b "$B" --trim | tail -5
rex block call -s "$REX_SESSION" -b "$B" modes | jq -c . 
rex block close -s "$REX_SESSION" "$B"
