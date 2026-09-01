#!/usr/bin/env bash
# DEVA11Y-484 decompression-bomb guard — regression suite (shell launchers).
#
# Covers the shell half of the guard: the real download_binary() in
# scripts/{bash,zsh,fish}/cli.sh, exercised against locally generated archives
# through a curl shim. No network, no credentials, no mocks of bsdtar/head/curl.
#
# The Swift half (extractLocalArchive + the extraction watchdog) is NOT covered
# here. It is private on a private struct inside a plugin-only package with no
# library target, so it cannot be imported by a test. Making it testable requires
# the library extraction tracked in DEVA11Y-761.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rc=0

echo "════════════════════════════════════════════════════════"
echo " DEVA11Y-484 extraction guard — shell regression suite"
echo "════════════════════════════════════════════════════════"

for tool in bsdtar curl python3 awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "FATAL: required tool '$tool' not found on PATH." >&2
    exit 1
  }
done

# Gate on the completion marker, NOT on any individual fixture. legit.tar.gz is
# written first, so gating on it lets a concurrent run start reading while the later
# fixtures are still being written — measured: 5 of 51 assertions failed that way.
if [ ! -f "$HERE/fixtures/.complete" ]; then
  echo
  echo "▶ Generating fixtures (~106 MB, gitignored)"
  bash "$HERE/make_fixtures.sh" || exit 1
fi

if [ ! -f "$HERE/fixtures/.complete" ]; then
  echo "FATAL: fixtures incomplete after generation." >&2
  exit 1
fi

echo
echo "▶ Shell launcher tests (bash / zsh / fish)"
bash "$HERE/test_shell_extraction.sh" || rc=1

echo
if [ "$rc" -eq 0 ]; then
  echo "DEVA11Y-484 shell suite: ALL GREEN"
else
  echo "DEVA11Y-484 shell suite: FAILURES (see above)"
fi
exit "$rc"
