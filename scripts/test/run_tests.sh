#!/usr/bin/env bash
# DEVA11Y-484 decompression-bomb guard — full regression suite.
#   1. Swift unit tests against the REAL BrowserStackCLIKit library (swift run cli-kit-tests)
#   2. Shell wrapper integration tests for scripts/{bash,zsh,fish}/cli.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
rc=0

echo "════════════════════════════════════════════════════════"
echo " DEVA11Y-484 decompression-bomb guard — regression suite"
echo "════════════════════════════════════════════════════════"

echo; echo "▶ Swift library unit tests (real bsdtar + crafted bombs)"
( cd "$REPO" && swift run cli-kit-tests ) || rc=1

echo; echo "▶ Shell wrapper tests (bash / zsh / fish)"
if [ ! -f "$HERE/fixtures/legit.tar.gz" ]; then bash "$HERE/make_fixtures.sh" || exit 1; fi
bash "$HERE/test_shell_extraction.sh" || rc=1

echo
if [ "$rc" -eq 0 ]; then
  echo "✅ DEVA11Y-484 suite: ALL GREEN"
else
  echo "❌ DEVA11Y-484 suite: FAILURES (see above)"
fi
exit "$rc"
