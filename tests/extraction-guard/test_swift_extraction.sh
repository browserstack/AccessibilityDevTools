#!/usr/bin/env bash
# Integration tests for the Swift plugin's extraction guard, exercised through the
# mirror harness (see check_drift.sh for why a mirror). Drives real curl/bsdtar.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIXTURES="$HERE/fixtures"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

MB=$((1024*1024))
CAP_SMALL=$((50*MB))     # small byte cap for bomb tests (bounds blast radius)
CAP_BIG=$((200*MB))      # production byte cap
ENTRIES=10000            # production entry cap

echo "Building Swift harness..."
( cd "$HERE/swift-harness" && swift build ) >/dev/null 2>&1 || { echo "harness build failed"; exit 1; }
HARNESS="$HERE/swift-harness/.build/debug/ExtractionHarness"
[ -x "$HARNESS" ] || HARNESS="$(cd "$HERE/swift-harness" && swift build --show-bin-path)/ExtractionHarness"

WORK="$(mktemp -d)"
trap 'stop_server; rm -rf "$WORK"' EXIT
start_server "$FIXTURES" || exit 1

# jget <json> <field> — extract a field via python3
jget() { python3 -c 'import sys,json; print(json.load(sys.stdin)[sys.argv[1]])' "$2" <<<"$1"; }

# run_remote <fixture> <maxBytes> <maxEntries> [maxCompressed]
run_remote() {
  local dest; dest="$(mktemp -d "$WORK/dest.XXXX")"; rm -rf "$dest"
  OUT=$("$HARNESS" remote "$(url_for "$1")" "$dest" "$2" "$3" "${4:-$((100*MB))}" 2>/dev/null)
  DEST="$dest"
}
run_local() {
  local dest; dest="$(mktemp -d "$WORK/dest.XXXX")"; rm -rf "$dest"
  OUT=$("$HARNESS" local "$FIXTURES/$1" "$dest" "$2" "$3" 2>/dev/null)
  DEST="$dest"
}

echo "── Swift extraction guard (via mirror harness) ──────────"

# 1. Legit remote download: not flagged, binary present + runs, dir kept.
run_remote "legit.tar.gz" "$CAP_BIG" "$ENTRIES"
assert_eq "$(jget "$OUT" exceeded)" "False" "legit: not flagged as exceeded"
assert_eq "$(jget "$OUT" bsdtarStatus)" "0" "legit: bsdtar exits 0"
if [ -f "$DEST/browserstack-cli" ]; then ok "legit: binary extracted"; else bad "legit: binary missing"; fi
"$DEST/browserstack-cli" >/dev/null 2>&1; assert_status $? 0 "legit: extracted binary runs"

# 2. Decompression bomb (remote), small byte cap: flagged, terminated mid-stream, removed.
#    The 400 MB fixture is ~8x the 50 MB cap, so a working LIVE watchdog must SIGTERM
#    bsdtar (status 15) well before it finishes — asserting that catches a regression
#    where only the post-extraction check works (which would let a huge bomb fill the disk).
run_remote "bomb.tar.gz" "$CAP_SMALL" "$ENTRIES"
assert_eq "$(jget "$OUT" exceeded)" "True" "bomb: flagged as exceeded"
assert_contains "$(jget "$OUT" reason)" "decompressed size" "bomb: reason cites size"
assert_eq "$(jget "$OUT" bsdtarStatus)" "15" "bomb: bsdtar SIGTERM'd mid-stream (live watchdog fired)"
bomb_peak_mb=$(( $(jget "$OUT" bytes) / MB ))
assert_le "$bomb_peak_mb" 350 "bomb: peak disk bounded below the 400 MB fixture (=${bomb_peak_mb}MB)"
assert_absent "$DEST" "bomb: extraction dir removed"

# 3. Entry-count bomb (20k tiny files), generous byte cap: flagged on entries.
run_remote "manyfiles.tar.gz" "$CAP_BIG" "$ENTRIES"
assert_eq "$(jget "$OUT" exceeded)" "True" "many-files: flagged as exceeded"
assert_contains "$(jget "$OUT" reason)" "entries" "many-files: reason cites entry count"
assert_absent "$DEST" "many-files: extraction dir removed"

# 4. Multi-file archive: not a bomb, extracts fine, binary present.
run_remote "multifile.tar.gz" "$CAP_BIG" "$ENTRIES"
assert_eq "$(jget "$OUT" exceeded)" "False" "multi-file: not flagged"
if [ -f "$DEST/browserstack-cli" ]; then ok "multi-file: binary present alongside extras"; else bad "multi-file: binary missing"; fi

# 5. Oversized download (>100 MB): curl --max-filesize rejects before extraction.
run_remote "oversized-download.bin" "$CAP_BIG" "$ENTRIES" "$((100*MB))"
if [ "$(jget "$OUT" curlStatus)" != "0" ]; then ok "oversized-download: curl rejected over-cap download (status $(jget "$OUT" curlStatus))"; else bad "oversized-download: curl did not reject"; fi

# 6. Local-file bomb path (extractLocalArchive), small cap: flagged + removed.
run_local "bomb.tar.gz" "$CAP_SMALL" "$ENTRIES"
assert_eq "$(jget "$OUT" exceeded)" "True" "local bomb: flagged as exceeded"
assert_absent "$DEST" "local bomb: extraction dir removed"

# 7. Corrupt archive (local): bsdtar fails, not a false bomb-positive.
run_local "corrupt.tar.gz" "$CAP_BIG" "$ENTRIES"
assert_eq "$(jget "$OUT" exceeded)" "False" "corrupt: not flagged as bomb"
if [ "$(jget "$OUT" bsdtarStatus)" != "0" ]; then ok "corrupt: bsdtar reports failure"; else bad "corrupt: bsdtar unexpectedly succeeded"; fi

summary
