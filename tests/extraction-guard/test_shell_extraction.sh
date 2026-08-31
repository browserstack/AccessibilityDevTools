#!/usr/bin/env bash
# Integration tests for the REAL download_binary() in scripts/{bash,zsh,fish}/cli.sh.
#
# The functions are extracted VERBATIM from the repo and run against a local
# server; only the hardcoded api.browserstack.com URL is redirected, via the curl
# shim. bsdtar, head, curl and the guarded pipeline are never mocked — if the
# shipped guard regresses, these tests fail.
#
# Lives under tests/ rather than scripts/ on purpose: the
# verify-selfupdate-checksums workflow globs scripts/**/*.sh and requires a
# committed .sha256 sidecar for every match. Test scripts are not self-updated,
# so they must not enter that glob.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIXTURES="$HERE/fixtures"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

REAL_CURL="$(command -v curl)"
export REAL_CURL
SHIM_DIR="$HERE/_shim"
chmod +x "$SHIM_DIR/curl"

WORK="$(mktemp -d)"
trap 'stop_server; rm -rf "$WORK"' EXIT

start_server "$FIXTURES" || exit 1

# download_binary() calls three sibling functions. Extracting only download_binary
# leaves them undefined, and the function then dies with exit 127 on the first call
# — which looks exactly like a guard rejection and would make every abort assertion
# pass for the wrong reason. Load the whole dependency set.
DEPS=(_self_update_sha256 strip_quarantine verify_binary_integrity download_binary)

load_download_binary() {
  local variant="$1"
  local src="$REPO/scripts/$variant/cli.sh"
  local fn="$WORK/functions.$variant.sh"
  : > "$fn"

  local dep
  for dep in "${DEPS[@]}"; do
    awk -v name="$dep" '
      $0 ~ "^" name "\\(\\) \\{" { p = 1 }
      p { print }
      /^\}/ { if (p) { p = 0 } }
    ' "$src" >> "$fn"
    grep -q "^${dep}() {" "$fn" || { bad "$variant: could not extract ${dep}()"; return 1; }
  done

  # Faithfulness guards: the extracted code must still contain the security-relevant
  # pipeline and both caps. If cli.sh is refactored so these no longer match, the
  # suite must fail loudly rather than silently testing something else.
  grep -q 'bsdtar -xvf "\$BINARY_ZIP_PATH" -O | head -c "\$max_decompressed"' "$fn" \
    || { bad "$variant: extracted code lost the guarded bsdtar|head pipeline"; return 1; }
  grep -q 'max_compressed=104857600' "$fn" \
    || { bad "$variant: extracted code lost the 100 MB compressed cap"; return 1; }
  grep -q 'max_decompressed=209715200' "$fn" \
    || { bad "$variant: extracted code lost the 200 MB decompressed cap"; return 1; }

  # shellcheck disable=SC1090
  source "$fn"
}

# run_case <fixture> -> sets LAST_STATUS / LAST_CACHE / LAST_STDERR
#
# stderr is captured, not discarded, because exit status alone cannot tell WHICH
# guard fired. A decompression bomb trips both the size check and extract_status
# (bsdtar takes SIGPIPE when `head -c` closes the pipe), so asserting only
# "exit 1" still passes with the size guard deleted — verified by mutation test.
# The two paths emit different messages, so the message is the discriminator.
run_case() {
  local fixture="$1"
  local cache
  cache="$(mktemp -d "$WORK/cache.XXXX")"
  export OS=macos ARCH=arm64
  export BINARY_ZIP_PATH="$cache/browserstack-cli.zip"
  export BINARY_PATH="$cache/browserstack-cli"
  TEST_DOWNLOAD_URL="$(url_for "$fixture")"
  export TEST_DOWNLOAD_URL
  local errfile="$cache/stderr.txt"
  ( PATH="$SHIM_DIR:$PATH"; download_binary ) >/dev/null 2>"$errfile"
  LAST_STATUS=$?
  LAST_CACHE="$cache"
  LAST_STDERR="$(cat "$errfile" 2>/dev/null)"
}

# The mode download_binary applies before publishing the binary. Read it from the
# shipped script instead of hardcoding: main tightened this from 0775 to 0755, and
# a hardcoded expectation silently rotted.
EXPECTED_MODE="$(sed -n 's/.*chmod \(0[0-7][0-7][0-7]\) "${BINARY_PATH}.tmp".*/\1/p' \
  "$REPO/scripts/bash/cli.sh" | head -1)"
EXPECTED_MODE="${EXPECTED_MODE#0}"
[ -n "$EXPECTED_MODE" ] || { echo "FATAL: could not read expected chmod from cli.sh" >&2; exit 1; }
echo "Expected published mode, read from cli.sh: 0${EXPECTED_MODE}"

for variant in bash zsh fish; do
  echo "── variant: $variant ───────────────────────────────"
  load_download_binary "$variant" || continue

  # 1. Legit binary: succeeds, runnable, correct mode, bytes intact.
  run_case "legit.tar.gz"
  assert_status "$LAST_STATUS" 0 "$variant legit: exits 0"
  if [ -f "$LAST_CACHE/browserstack-cli" ]; then
    ok "$variant legit: binary present"
  else
    bad "$variant legit: binary missing"
  fi
  perms=$(stat -f '%Lp' "$LAST_CACHE/browserstack-cli" 2>/dev/null \
    || stat -c '%a' "$LAST_CACHE/browserstack-cli" 2>/dev/null)
  assert_eq "$perms" "$EXPECTED_MODE" "$variant legit: chmod 0${EXPECTED_MODE} applied"
  "$LAST_CACHE/browserstack-cli" >/dev/null 2>&1
  assert_status $? 0 "$variant legit: extracted binary runs"

  # 2. Decompression bomb (400 MB): aborts via the SIZE cap specifically, partial
  #    binary removed. The message assertion is load-bearing — see run_case.
  run_case "bomb.tar.gz"
  assert_status "$LAST_STATUS" 1 "$variant bomb: aborts with exit 1"
  assert_contains "$LAST_STDERR" "maximum allowed decompressed size" \
    "$variant bomb: rejected by the DECOMPRESSED-SIZE cap (not merely SIGPIPE)"
  assert_absent "$LAST_CACHE/browserstack-cli" "$variant bomb: partial binary cleaned up"

  # 3. Oversized download (>100 MB): rejected at the DOWNLOAD stage by
  #    curl --max-filesize, before bsdtar ever runs.
  #
  #    The discriminator is the stage, not the wording. cli.sh branches on how many
  #    bytes landed on disk rather than on curl's exit code (deliberately: against the
  #    real endpoint curl aborts mid-receive with 56, not the documented 63). Against a
  #    local server the Content-Length is known up front, so curl aborts at ~0 bytes and
  #    the "maximum allowed download size" wording is unreachable here. What still
  #    discriminates: with the cap removed, 105 MB downloads fine and the failure moves
  #    to bsdtar. So asserting the failure came from curl proves the cap is present.
  run_case "oversized-download.bin"
  assert_status "$LAST_STATUS" 1 "$variant oversized-download: aborts with exit 1"
  case "$LAST_STDERR" in
    *"curl exited"*|*"maximum allowed download size"*)
      ok "$variant oversized-download: rejected at the DOWNLOAD stage by --max-filesize" ;;
    *)
      bad "$variant oversized-download: not rejected during download (stderr: ${LAST_STDERR})" ;;
  esac
  assert_absent "$LAST_CACHE/browserstack-cli" "$variant oversized-download: no binary written"

  # 4. Corrupt archive: bsdtar fails, abort. Must NOT be misreported as a size
  #    rejection — that would mean the size branch is swallowing unrelated failures.
  run_case "corrupt.tar.gz"
  assert_status "$LAST_STATUS" 1 "$variant corrupt: aborts with exit 1"
  case "$LAST_STDERR" in
    *"maximum allowed decompressed size"*)
      bad "$variant corrupt: misreported as a size rejection" ;;
    *) ok "$variant corrupt: not misreported as a size rejection" ;;
  esac

  # 5. 404 / network failure: abort, no hang.
  run_case "does-not-exist.tar.gz"
  assert_status "$LAST_STATUS" 1 "$variant missing-url: aborts with exit 1"

  # 6. Many-files archive via -O: the shell path concatenates entries into one
  #    stream, so the entry-count vector writes nothing per-entry; bounded by head -c.
  run_case "manyfiles.tar.gz"
  assert_status "$LAST_STATUS" 0 "$variant many-files: succeeds (-O stream, nothing per-entry on disk)"

  # 7. Multi-file archive via -O: pre-existing concatenation behaviour, unchanged.
  run_case "multifile.tar.gz"
  assert_status "$LAST_STATUS" 0 "$variant multi-file: succeeds (pre-existing -O concatenation)"

  # 8. A rejected download must not destroy an already-good cached binary.
  run_case "legit.tar.gz"
  printf 'sentinel' > "$LAST_CACHE/browserstack-cli"
  GOOD_CACHE="$LAST_CACHE"
  export BINARY_ZIP_PATH="$GOOD_CACHE/browserstack-cli.zip"
  export BINARY_PATH="$GOOD_CACHE/browserstack-cli"
  TEST_DOWNLOAD_URL="$(url_for bomb.tar.gz)"
  export TEST_DOWNLOAD_URL
  ( PATH="$SHIM_DIR:$PATH"; download_binary ) >/dev/null 2>&1
  assert_status $? 1 "$variant cached-binary: bomb still rejected"
  assert_eq "$(cat "$GOOD_CACHE/browserstack-cli" 2>/dev/null)" "sentinel" \
    "$variant cached-binary: existing good binary left intact"
done

summary
