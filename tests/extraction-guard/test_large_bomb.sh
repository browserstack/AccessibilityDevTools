#!/usr/bin/env bash
# DEEP test (opt-in): proves the watchdog bounds peak disk for a bomb FAR larger than
# the cap — the real disk-exhaustion scenario. Skipped by default because it writes/reads
# a multi-GB archive; enable with DEVA11Y_DEEP=1. Blast radius is bounded: if the guard
# regressed entirely, it writes the bomb's full size once (a few GB) then cleans up.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

if [ "${DEVA11Y_DEEP:-0}" != "1" ]; then
  echo "test_large_bomb: skipped (set DEVA11Y_DEEP=1 to run the multi-GB bomb test)"
  exit 0
fi

MB=$((1024*1024))
BOMB_MB=${BOMB_MB:-2048}        # bomb decompressed size
CAP_MB=${CAP_MB:-200}           # production byte cap
PEAK_BUDGET_MB=${PEAK_BUDGET_MB:-700}  # generous ceiling proving we stop far below the bomb

echo "Building Swift harness..."
( cd "$HERE/swift-harness" && swift build ) >/dev/null 2>&1 || { echo "harness build failed"; exit 1; }
HARNESS="$(cd "$HERE/swift-harness" && swift build --show-bin-path)/ExtractionHarness"

WORK="$(mktemp -d)"
trap 'stop_server; rm -rf "$WORK"' EXIT
echo "Generating ${BOMB_MB} MB bomb..."
( cd "$WORK" && dd if=/dev/zero bs=1048576 count="$BOMB_MB" of=cli 2>/dev/null && bsdtar -czf bomb-big.tar.gz cli && rm cli )

start_server "$WORK" || exit 1

echo "── Large-bomb watchdog test (${BOMB_MB} MB bomb, ${CAP_MB} MB cap) ──"
dest="$(mktemp -d "$WORK/dest.XXXX")"; rm -rf "$dest"
OUT=$("$HARNESS" remote "$(url_for bomb-big.tar.gz)" "$dest" "$((CAP_MB*MB))" 10000 "$((100*MB))" 2>/dev/null)
echo "  outcome: $OUT"
peak_mb=$(( $(python3 -c 'import sys,json;print(json.load(sys.stdin)["bytes"])' <<<"$OUT") / MB ))
status=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["bsdtarStatus"])' <<<"$OUT")

assert_eq "$(python3 -c 'import sys,json;print(json.load(sys.stdin)["exceeded"])' <<<"$OUT")" "True" "large bomb: flagged as exceeded"
assert_eq "$status" "15" "large bomb: bsdtar SIGTERM'd mid-stream"
assert_le "$peak_mb" "$PEAK_BUDGET_MB" "large bomb: peak disk (${peak_mb}MB) bounded far below bomb size (${BOMB_MB}MB)"
assert_absent "$dest" "large bomb: extraction dir removed"

summary
