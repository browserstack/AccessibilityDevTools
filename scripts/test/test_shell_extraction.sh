#!/usr/bin/env bash
# Integration tests for the REAL download_binary() in scripts/{bash,zsh,fish}/cli.sh.
# The function body is extracted verbatim from the repo and run against a local server;
# only its hardcoded URL is redirected (via the curl shim). No mocks of bsdtar/head/curl.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FIXTURES="$HERE/fixtures"
# shellcheck source=lib/assert.sh
source "$HERE/lib/assert.sh"

export REAL_CURL="$(command -v curl)"
SHIM_DIR="$HERE/_shim"
chmod +x "$SHIM_DIR/curl"

WORK="$(mktemp -d)"
trap 'stop_server; rm -rf "$WORK"' EXIT

start_server "$FIXTURES" || exit 1

# Extracts the verbatim download_binary() from a variant's cli.sh into $WORK and sources it.
load_download_binary() {
  local variant="$1"
  local fn="$WORK/download_binary.$variant.sh"
  awk '/^download_binary\(\) \{/{p=1} p{print} /^\}/{if(p) p=0}' "$REPO/scripts/$variant/cli.sh" > "$fn"
  # Faithfulness: the extracted body must match the repo's, and must still call bsdtar+head.
  grep -q 'bsdtar -xvf "\$BINARY_ZIP_PATH" -O | head -c "\$max_decompressed"' "$fn" \
    || { bad "$variant: extracted function does not contain the guarded pipeline"; return 1; }
  # shellcheck disable=SC1090
  source "$fn"
}

# run_case <fixture> <expect-exit>  -> sets BINARY_PATH/BINARY_ZIP_PATH in a temp cache
run_case() {
  local fixture="$1"
  local cache; cache="$(mktemp -d "$WORK/cache.XXXX")"
  export OS=macos ARCH=arm64
  export BINARY_ZIP_PATH="$cache/browserstack-cli.zip"
  export BINARY_PATH="$cache/browserstack-cli"
  export TEST_DOWNLOAD_URL; TEST_DOWNLOAD_URL="$(url_for "$fixture")"
  ( PATH="$SHIM_DIR:$PATH"; download_binary ) >/dev/null 2>&1
  LAST_STATUS=$?
  LAST_CACHE="$cache"
}

for variant in bash zsh fish; do
  echo "── variant: $variant ───────────────────────────────"
  load_download_binary "$variant" || continue

  # 1. Legit binary: succeeds, runnable, executable bit set, bytes intact.
  run_case "legit.tar.gz"
  assert_status "$LAST_STATUS" 0 "$variant legit: exits 0"
  if [ -f "$LAST_CACHE/browserstack-cli" ]; then ok "$variant legit: binary present"; else bad "$variant legit: binary missing"; fi
  perms=$(stat -f '%Lp' "$LAST_CACHE/browserstack-cli" 2>/dev/null || stat -c '%a' "$LAST_CACHE/browserstack-cli" 2>/dev/null)
  assert_eq "$perms" "775" "$variant legit: chmod 0775 applied"
  "$LAST_CACHE/browserstack-cli" >/dev/null 2>&1; assert_status $? 0 "$variant legit: extracted binary runs"

  # 2. Decompression bomb (400 MB): aborts, partial binary removed.
  run_case "bomb.tar.gz"
  assert_status "$LAST_STATUS" 1 "$variant bomb: aborts with exit 1"
  assert_absent "$LAST_CACHE/browserstack-cli" "$variant bomb: partial binary cleaned up"

  # 3. Oversized download (>100 MB): curl --max-filesize rejects before extraction.
  run_case "oversized-download.bin"
  assert_status "$LAST_STATUS" 1 "$variant oversized-download: aborts with exit 1"
  assert_absent "$LAST_CACHE/browserstack-cli" "$variant oversized-download: no binary written"

  # 4. Corrupt archive: bsdtar fails, abort, cleanup.
  run_case "corrupt.tar.gz"
  assert_status "$LAST_STATUS" 1 "$variant corrupt: aborts with exit 1"

  # 5. 404 / network failure: abort, cleanup, no hang.
  run_case "does-not-exist.tar.gz"
  assert_status "$LAST_STATUS" 1 "$variant missing-url: aborts with exit 1"

  # 6. Many-files archive via -O: shell concatenates entries to one stream, so the
  #    entry-count vector cannot write per-entry files; result is bounded by head -c.
  run_case "manyfiles.tar.gz"
  assert_status "$LAST_STATUS" 0 "$variant many-files: succeeds (-O stream, nothing per-entry on disk)"

  # 7. Multi-file archive via -O: pre-existing concatenation behavior, unchanged by the fix.
  run_case "multifile.tar.gz"
  assert_status "$LAST_STATUS" 0 "$variant multi-file: succeeds (pre-existing -O concatenation)"
done

summary
