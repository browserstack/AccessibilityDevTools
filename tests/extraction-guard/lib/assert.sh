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
SERVER_TOKEN_FILE=""

start_server() {
  local root="$1"
  # A bare readiness probe ("does anything answer on this port?") is not enough. If an
  # unrelated local service already holds the PID-derived port, the probe succeeds
  # against IT, start_server returns 0, and every fixture request 404s — surfacing as a
  # dozen confusing per-case failures rather than "port busy". The old comment here
  # promised a fallback that was never implemented (DEVA11Y-484 review). So: serve a
  # token, require the responding server to be OURS, and try other ports if not.
  # Per-run filename, not a fixed one. A shared name is itself a concurrency bug:
  # four simultaneous runs overwrite each other's token, every probe then reads a
  # foreign value, and start_server exhausts all its ports and fails with no tests
  # run at all. Measured — 2 of 4 concurrent cold starts died that way.
  local token_file=".eg-token.$$.${RANDOM:-0}"
  local token="eg-$$-${RANDOM:-0}"
  if ! printf '%s' "$token" > "${root}/${token_file}" 2>/dev/null; then
    echo "ERROR: cannot write probe token into $root" >&2
    return 1
  fi
  SERVER_TOKEN_FILE="${root}/${token_file}"

  local base=$(( 18000 + ($$ % 2000) ))
  local attempt port got pid i
  for attempt in 0 1 2 3 4 5 6 7 8 9; do
    port=$(( base + attempt * 37 ))
    [ "$port" -gt 64000 ] && port=$(( 18000 + attempt * 37 ))
    ( cd "$root" && exec python3 -m http.server "$port" --bind 127.0.0.1 ) >/dev/null 2>&1 &
    pid=$!
    got=""
    for i in $(seq 1 40); do
      got=$(curl -fsS "http://127.0.0.1:${port}/${token_file}" 2>/dev/null || true)
      [ -n "$got" ] && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if [ "$got" = "$token" ]; then
      SERVER_PID="$pid"
      SERVER_PORT="$port"
      return 0
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done

  echo "ERROR: could not start a local server we own (tried 10 ports from ${base})" >&2
  return 1
}

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
  # Remove our own probe token so repeated runs do not litter the fixtures dir.
  if [ -n "$SERVER_TOKEN_FILE" ]; then
    rm -f "$SERVER_TOKEN_FILE" 2>/dev/null || true
    SERVER_TOKEN_FILE=""
  fi
}

url_for() { echo "http://127.0.0.1:${SERVER_PORT}/$1"; }
