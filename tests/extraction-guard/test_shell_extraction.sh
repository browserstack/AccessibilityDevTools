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
  # The pre-emptive transfer abort. Behavioural assertions CANNOT cover this: the
  # explicit compressed_size backstop still rejects an oversized download without it,
  # so removing the flag leaves every assertion green. Only this grep catches it —
  # and without the flag a chunked/undeclared-length response can write unbounded
  # bytes to disk before any check runs, which is the whole point of having it.
  grep -q -- '--max-filesize "\$max_compressed"' "$fn" \
    || { bad "$variant: extracted code lost the pre-emptive --max-filesize abort"; return 1; }
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
#
# Read PER VARIANT, not once from bash: the three scripts are byte-identical in this
# region today, but reading bash's value for all three would check a zsh- or
# fish-only mode change against the wrong source (DEVA11Y-484 review).
read_expected_mode() {
  local variant="$1" mode
  mode="$(sed -n 's/.*chmod \(0[0-7][0-7][0-7]\) "${BINARY_PATH}.tmp".*/\1/p' \
    "$REPO/scripts/${variant}/cli.sh" | head -1)"
  mode="${mode#0}"
  [ -n "$mode" ] || { echo "FATAL: could not read expected chmod from ${variant}/cli.sh" >&2; exit 1; }
  printf '%s' "$mode"
}

for variant in bash zsh fish; do
  echo "── variant: $variant ───────────────────────────────"
  load_download_binary "$variant" || continue
  EXPECTED_MODE="$(read_expected_mode "$variant")"
  echo "  expected published mode, read from ${variant}/cli.sh: 0${EXPECTED_MODE}"

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

  # 3. Oversized download (>100 MB): rejected before bsdtar ever runs.
  #
  #    Be precise about what this proves, because an earlier version of this comment
  #    overclaimed. The compressed cap has TWO layers: `--max-filesize` aborts the
  #    transfer pre-emptively, and an explicit `compressed_size > max_compressed`
  #    check (cli.sh) backstops it for responses with no declared length. Removing
  #    the flag alone therefore does NOT move the failure to bsdtar — the backstop
  #    fires and emits "maximum allowed download size", which is the second pattern
  #    accepted below. So this assertion proves "rejected before extraction", NOT
  #    "the flag is present".
  #
  #    Coverage for the flag itself is the faithfulness grep in
  #    load_download_binary, which fails loudly if `--max-filesize` disappears.
  #    Against a local server the Content-Length is known up front, so curl aborts at
  #    ~0 bytes and the specific size wording is unreachable here — cli.sh branches on
  #    bytes-on-disk, not curl's exit code, because against the real endpoint curl
  #    aborts mid-receive with 56 rather than the documented 63.
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

  # 6. Many-files archive via -O: the shell path concatenates entries into one stream,
  #    so the entry-count vector writes nothing per-entry; bounded by head -c.
  #
  #    Read this as "no per-entry disk amplification", NOT "entry counts are capped".
  #    The shell path has NO entry-count ceiling at all, unlike the Swift path's
  #    maxArchiveEntries = 10_000; and because -O concatenates, a 20,000-entry archive
  #    of empty files publishes a 0-byte browserstack-cli chmod'd 0755. That asymmetry
  #    is pre-existing and outside DEVA11Y-484's remediation, but it is a real gap —
  #    do not let this passing assertion read as coverage of it.
  run_case "manyfiles.tar.gz"
  assert_status "$LAST_STATUS" 0 "$variant many-files: succeeds (-O stream, nothing per-entry on disk)"

  # 7. Multi-file archive via -O: pre-existing concatenation behaviour, unchanged.
  run_case "multifile.tar.gz"
  assert_status "$LAST_STATUS" 0 "$variant multi-file: succeeds (pre-existing -O concatenation)"

  # 7b. The format production ACTUALLY serves: a .zip. Every other fixture is
  #     .tar.gz, so without this the suite never exercises the real archive format.
  run_case "legit.zip"
  assert_status "$LAST_STATUS" 0 "$variant legit zip: exits 0 (real production format)"
  perms=$(stat -f '%Lp' "$LAST_CACHE/browserstack-cli" 2>/dev/null \
    || stat -c '%a' "$LAST_CACHE/browserstack-cli" 2>/dev/null)
  assert_eq "$perms" "$EXPECTED_MODE" "$variant legit zip: chmod 0${EXPECTED_MODE} applied"
  "$LAST_CACHE/browserstack-cli" >/dev/null 2>&1
  assert_status $? 0 "$variant legit zip: extracted binary runs"

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
