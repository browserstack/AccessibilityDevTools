#!/usr/bin/env bash
# DEVA11Y-484 extraction-guard regression suite.
# Generates fixtures (if missing), verifies the plugin/harness guard is in sync, then
# runs the real-process integration tests for both the shell wrappers and the Swift plugin.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

echo "════════════════════════════════════════════════════════"
echo " DEVA11Y-484 decompression-bomb guard — regression suite"
echo "════════════════════════════════════════════════════════"

if [ ! -f "$HERE/fixtures/legit.tar.gz" ] || [ ! -f "$HERE/fixtures/oversized-download.bin" ]; then
  echo "▶ Generating fixtures..."
  bash "$HERE/make_fixtures.sh" || exit 1
fi

echo; echo "▶ Drift check (plugin guard vs harness mirror)"
bash "$HERE/check_drift.sh" || rc=1

echo; echo "▶ Shell wrapper tests (bash / zsh / fish)"
bash "$HERE/test_shell_extraction.sh" || rc=1

echo; echo "▶ Swift plugin guard tests (via mirror harness)"
bash "$HERE/test_swift_extraction.sh" || rc=1

echo
if [ "$rc" -eq 0 ]; then
  echo "✅ DEVA11Y-484 suite: ALL GREEN"
else
  echo "❌ DEVA11Y-484 suite: FAILURES (see above)"
fi
exit "$rc"
