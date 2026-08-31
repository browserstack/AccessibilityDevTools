# Shared assertion + helper functions for the DEVA11Y-484 extraction tests.
# Sourced by the test suites; not executed directly.

PASS=0
FAIL=0

_green() { printf '\033[32m%s\033[0m' "$1"; }
_red()   { printf '\033[31m%s\033[0m' "$1"; }

ok()   { PASS=$((PASS+1)); printf '  %s %s\n' "$(_green 'PASS')" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s %s\n' "$(_red 'FAIL')" "$1"; }

# assert_eq <actual> <expected> <message>
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3 (= $2)"; else bad "$3 (expected '$2', got '$1')"; fi
}

# assert_true <0-or-1 cmd-status> <message>   (call as: cmd; assert_status $? 0 "...")
assert_status() {
  if [ "$1" = "$2" ]; then ok "$3 (exit $2)"; else bad "$3 (expected exit $2, got $1)"; fi
}

# assert_le <actual> <max> <message>
assert_le() {
  if [ "$1" -le "$2" ]; then ok "$3 ($1 <= $2)"; else bad "$3 ($1 > $2)"; fi
}

# assert_absent <path> <message>
assert_absent() {
  if [ ! -e "$1" ]; then ok "$2 (removed)"; else bad "$2 (still present: $1)"; fi
}

# assert_contains <haystack> <needle> <message>
assert_contains() {
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (missing '$2' in: $1)" ;; esac
}

summary() {
  echo
  if [ "$FAIL" -eq 0 ]; then
    printf '%s  %d passed, 0 failed\n' "$(_green 'ALL GREEN')" "$PASS"
    return 0
  fi
  printf '%s  %d passed, %d failed\n' "$(_red 'FAILURES')" "$PASS" "$FAIL"
  return 1
}

# ---- local static file server (python3) ----
SERVER_PID=""
SERVER_PORT=""

start_server() {
  local root="$1"
  # Pick a port deterministically-ish from PID to avoid clashes; fall back if taken.
  SERVER_PORT=$(( 18000 + ($$ % 2000) ))
  ( cd "$root" && exec python3 -m http.server "$SERVER_PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  SERVER_PID=$!
  # Wait until it answers.
  for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:${SERVER_PORT}/" -o /dev/null 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  echo "ERROR: local server failed to start on port ${SERVER_PORT}" >&2
  return 1
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

url_for() { echo "http://127.0.0.1:${SERVER_PORT}/$1"; }
