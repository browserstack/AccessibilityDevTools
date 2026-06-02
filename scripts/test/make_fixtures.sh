#!/usr/bin/env bash
# Generates real .tar.gz fixtures for the DEVA11Y-484 extraction-guard tests.
# Everything is bounded: even if a guard regressed and failed to abort, no fixture
# decompresses beyond ~400 MB, so a test run can never exhaust the disk.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
mkdir -p "$DIR"
cd "$DIR"

log() { printf '  %s\n' "$*"; }

# A real, small, runnable host binary to stand in for browserstack-cli.
REAL_BIN="/usr/bin/true"
[ -x "$REAL_BIN" ] || REAL_BIN="/bin/echo"

# --- 1. legit: a single real Mach-O binary (extracted artifact actually runs) ---
make_legit() {
  rm -rf _legit && mkdir _legit
  cp "$REAL_BIN" _legit/browserstack-cli
  bsdtar -czf legit.tar.gz -C _legit browserstack-cli
  rm -rf _legit
  log "legit.tar.gz                ($(wc -c < legit.tar.gz) bytes compressed)"
}

# --- 2. bomb: small compressed, ~400 MB decompressed single file (bounded) ---
make_bomb() {
  rm -rf _bomb && mkdir _bomb
  # 400 MB of zeros compresses to a few hundred KB.
  dd if=/dev/zero bs=1048576 count=400 of=_bomb/browserstack-cli 2>/dev/null
  bsdtar -czf bomb.tar.gz -C _bomb browserstack-cli
  rm -rf _bomb
  log "bomb.tar.gz                 ($(wc -c < bomb.tar.gz) bytes compressed -> 400 MB decompressed)"
}

# --- 3. many-files: lots of tiny entries, small total bytes (entry-count bomb) ---
make_manyfiles() {
  rm -rf _many && mkdir _many
  # 20k empty files: trivial bytes, entry count well past the 10k ceiling.
  ( cd _many && touch $(seq -f 'f%.0f' 1 20000) )
  bsdtar -czf manyfiles.tar.gz -C _many .
  rm -rf _many
  log "manyfiles.tar.gz            (20,000 entries, ~0 bytes each)"
}

# --- 4. multi-file: a binary plus an extra file (structure, not a bomb) ---
make_multifile() {
  rm -rf _multi && mkdir _multi
  cp "$REAL_BIN" _multi/browserstack-cli
  printf 'license text\n' > _multi/LICENSE
  bsdtar -czf multifile.tar.gz -C _multi browserstack-cli LICENSE
  rm -rf _multi
  log "multifile.tar.gz            (binary + LICENSE)"
}

# --- 5. oversized-download: a payload larger than the 100 MB curl --max-filesize cap ---
# curl aborts on download size before bsdtar ever runs, so the bytes need not form a
# valid archive; 105 MB of zeros is enough and is cheap to produce.
make_oversized_download() {
  dd if=/dev/zero bs=1048576 count=105 of=oversized-download.bin 2>/dev/null
  log "oversized-download.bin      ($(wc -c < oversized-download.bin) bytes > 100 MB cap)"
}

# --- 6. corrupt: not a valid archive (bsdtar should fail cleanly) ---
make_corrupt() {
  head -c 4096 /dev/urandom > corrupt.tar.gz
  log "corrupt.tar.gz              (random bytes, not a real archive)"
}

echo "Generating fixtures in $DIR ..."
make_legit
make_bomb
make_manyfiles
make_multifile
make_oversized_download
make_corrupt
echo "Done."
