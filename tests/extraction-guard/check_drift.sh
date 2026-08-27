#!/usr/bin/env bash
# Fails if the DEVA11Y-484 EXTRACTION GUARD block in the SPM plugin has drifted from
# the mirrored copy the Swift harness compiles. SwiftPM command plugins can't be
# imported by a test target, so the harness mirrors the guard verbatim; this check is
# what keeps the mirror honest.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PLUGIN="$REPO/Plugins/BrowserStackAccessibilityLint/BrowserStackAccessibilityLint.swift"
MIRROR="$HERE/swift-harness/Sources/ExtractionHarness/Guard.swift"

block() {
  awk '/=== DEVA11Y-484 EXTRACTION GUARD: shared block ===/,/=== END DEVA11Y-484 EXTRACTION GUARD ===/' "$1"
}

tmp_plugin="$(mktemp)"; tmp_mirror="$(mktemp)"
trap 'rm -f "$tmp_plugin" "$tmp_mirror"' EXIT
block "$PLUGIN" > "$tmp_plugin"
block "$MIRROR" > "$tmp_mirror"

if [ ! -s "$tmp_plugin" ]; then echo "DRIFT CHECK ERROR: guard markers not found in plugin"; exit 2; fi
if [ ! -s "$tmp_mirror" ]; then echo "DRIFT CHECK ERROR: guard markers not found in mirror"; exit 2; fi

if diff -u "$tmp_plugin" "$tmp_mirror"; then
  echo "drift check: OK — plugin guard and harness mirror are identical ($(wc -l < "$tmp_plugin" | tr -d ' ') lines)"
else
  echo
  echo "DRIFT DETECTED: the harness mirror no longer matches the plugin guard block."
  echo "Re-sync by copying the block between the markers, then re-run the tests."
  exit 1
fi
