#!/usr/bin/env bash
# Tests for the launchers' verify_binary_signature (DEVA11Y-473/474). macOS only: the
# check shells out to /usr/bin/codesign. Exercises the function lifted verbatim from each
# launcher copy, so a drift between bash/zsh/fish shows up here.
#
#   run_tests.sh matrix     genuine CLI passes; flipped-byte, ad-hoc-signed and unsigned
#                           copies are refused; Linux passes through; unknown OS refused.
#   run_tests.sh published  the latest published macOS arm64 and x64 CLIs satisfy the
#                           Team-pinned requirement, so a re-signed release (new team or
#                           certificate) turns CI red instead of breaking every launcher.
set -uo pipefail

MODE="${1:-matrix}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LAUNCHERS=(bash zsh fish)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

# Lift verify_binary_signature off a launcher (name() { ... } to the first bare }).
extract() {
  awk 'index($0,"verify_binary_signature() {")==1{p=1} p{print} p&&/^}$/{exit}' "$ROOT/scripts/$1/cli.sh"
}

# Download and extract the latest CLI for an arch; prints the binary's path.
fetch_cli() {
  local arch="$1" dir="$WORK/$1"
  mkdir -p "$dir"
  curl -fsSL --retry 3 --retry-delay 5 \
    "https://api.browserstack.com/sdk/v1/download_cli?os=macos&os_arch=${arch}" -o "$dir/cli.zip" || return 1
  bsdtar -xf "$dir/cli.zip" -C "$dir" || return 1
  find "$dir" -maxdepth 1 -type f -name 'binary-*' | head -n 1
}

# check <description> <launcher> <OS value> <binary> <expected rc>
check() {
  local desc="$1" launcher="$2" os="$3" binary="$4" want="$5" fn out rc
  fn=$(extract "$launcher")
  if [[ -z "$fn" ]]; then
    echo "FAIL | $launcher | verify_binary_signature not found in scripts/$launcher/cli.sh"
    fail=$((fail + 1))
    return
  fi
  out=$(OS="$os" bash -c "$fn"$'\n''verify_binary_signature "$1"' _ "$binary" 2>&1) && rc=0 || rc=$?
  if [[ "$rc" == "$want" ]]; then
    echo "PASS | $launcher | $desc | rc=$rc"
    pass=$((pass + 1))
  else
    echo "FAIL | $launcher | $desc | got rc=$rc want rc=$want | $out"
    fail=$((fail + 1))
  fi
}

run_matrix() {
  local arch genuine size
  case "$(uname -m)" in
    arm64) arch=arm64 ;;
    *) arch=x64 ;;
  esac
  genuine=$(fetch_cli "$arch") || { echo "FAIL | could not download the CLI"; fail=$((fail + 1)); return; }

  cp "$genuine" "$WORK/flipped"
  size=$(wc -c < "$WORK/flipped")
  printf '\xff' | dd of="$WORK/flipped" bs=1 seek=$((size / 2)) conv=notrunc 2>/dev/null
  cp "$genuine" "$WORK/adhoc" && codesign --force --sign - "$WORK/adhoc" 2>/dev/null
  cp "$genuine" "$WORK/unsigned" && codesign --remove-signature "$WORK/unsigned"

  for l in "${LAUNCHERS[@]}"; do
    check "genuine CLI ($arch)"         "$l" macos "$genuine"         0
    check "flipped byte"                "$l" macos "$WORK/flipped"    2
    check "ad-hoc signed"               "$l" macos "$WORK/adhoc"      2
    check "unsigned"                    "$l" macos "$WORK/unsigned"   2
    check "missing file"                "$l" macos "$WORK/does-not-exist" 2
    check "linux (accepted risk)"       "$l" linux "$WORK/unsigned"   0
    check "unknown OS refused"          "$l" "UNKNOWN:Plan9" "$genuine" 2
  done
}

run_published() {
  local arch binary
  for arch in arm64 x64; do
    binary=$(fetch_cli "$arch") || { echo "FAIL | could not download the $arch CLI"; fail=$((fail + 1)); continue; }
    check "latest published CLI ($arch)" bash macos "$binary" 0
  done
}

case "$MODE" in
  matrix) run_matrix ;;
  published) run_published ;;
  *) echo "usage: $0 [matrix|published]" >&2; exit 64 ;;
esac

echo "----"
echo "PASS=$pass FAIL=$fail"
[[ $fail -eq 0 && $pass -gt 0 ]]
