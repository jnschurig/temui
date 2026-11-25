#!/bin/sh
# Step 10 verification runs for roadmap 05 (temui play). Unattended except
# for the resize segment. Run from anywhere:
#   docs/bench/05-data/verify.sh ghostty
#   docs/bench/05-data/verify.sh ghostty signals   # resume at the signal runs
# Logs and results land in .local/play-logs/<tag>/. About 7 minutes.
set -u
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1
TAG=${1:?usage: verify.sh TAG (e.g. ghostty or rex)}
L=$PWD/.local/play-logs/$TAG
mkdir -p "$L"
BIN=$PWD/zig-out/bin/temui
CORE=$PWD/zig-out/lib/temui_test_libretro.dylib
ROM=$PWD/testdata/testcore.rom
R=$L/results.txt
FROM=${2:-speed}
[ "$FROM" = speed ] && : >"$R"

say() { printf '%s\n' "$*" | tee -a "$R"; }
banner() { printf '\n\033[1m== %s\033[0m\n' "$*"; sleep "${2:-2}"; }
play() { name=$1; shift; "$BIN" play "$ROM" --core "$CORE" --log-file "$L/$name.log" "$@"; }
# The run's summary and last stats, from its log.
record() {
	sum=$(grep -o 'summary: .*' "$L/$1.log" | tail -1)
	fin=$(grep -o 'final stats: .*' "$L/$1.log" | tail -1)
	say "$1 rc=$2 | $sum | $fin"
}
run() { name=$1; shift; play "$name" "$@"; record "$name" $?; }
ttystate() { stty -a </dev/tty | tr ' ' '\n' | grep -E '^-?(icanon|echo|isig)$' | tr '\n' ' '; }

if [ "$FROM" = speed ]; then
banner "temui $TAG: speed runs (8 s each)"
run speed-4x --overlay --speed 4 --duration 8
run speed-max --overlay --speed max --duration 8
run speed-4x-p30 --overlay --speed 4 --present-fps 30 --duration 8
run speed-max-p30 --overlay --speed max --present-fps 30 --duration 8

banner "RESIZE: drag-resize the window during each of the next three runs (20 s each). Shrink it tiny once, then grow it back." 6
for b in kitty halfblock ascii; do
	banner "resize: $b" 1
	run "resize-$b" --overlay --renderer "$b" --duration 20
done
fi

banner "signals: SIGINT then SIGTERM after 3 s each"
# temui runs in the foreground (stdin stays the terminal itself; a
# background job would get /dev/null, or /dev/tty, which macOS can't poll,
# and would ignore SIGINT); a background killer sends the signal.
for s in INT TERM; do
	(sleep 3; pkill -"$s" -f "$L/sig-$s.log") &
	play "sig-$s" --overlay --duration 30
	rc=$?
	wait
	say "sig-$s rc=$rc tty after: $(ttystate)"
	sleep 1
done

banner "pacing: test core, 300 s at 1x"
run pace-300 --overlay --duration 300
grep -o 'stats: emu [0-9.]*' "$L/pace-300.log" | awk '{print $3}' | sort -n |
	awk 'NR==1{min=$1} {max=$1; n++} END{printf "pace-300 per-second emu: min %s max %s over %d samples\n", min, max, n}' | tee -a "$R"

banner "done: results in $R" 0
cat "$R"
