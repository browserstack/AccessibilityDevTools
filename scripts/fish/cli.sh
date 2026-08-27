#!/usr/bin/env bash -il

export PATH="$PATH:/opt/homebrew/bin"
# Shell specific
fish_bin=$(command -v fish)

if [[ -z "$fish_bin" ]]; then
  echo "Fish shell is not installed(or not available in PATH). Please install Fish shell to use this script."
  exit 2
fi

export BROWSERSTACK_USERNAME=$($fish_bin -lic 'echo $BROWSERSTACK_USERNAME' | tail -n 1)
export BROWSERSTACK_ACCESS_KEY=$($fish_bin -lic 'echo $BROWSERSTACK_ACCESS_KEY' | tail -n 1)

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
SCRIPT_PATH=$(realpath --relative-to="$GIT_ROOT" "$0" 2>/dev/null || realpath "$0")
SUBCOMMAND="$1"
EXTRA_ARGS=$@
CACHE_ROOT="${HOME}/.cache/browserstack/devtools/cli/"
BINARY_ZIP_PATH="${CACHE_ROOT}/browserstack-cli.zip"
BINARY_PATH="${CACHE_ROOT}/browserstack-cli"

mkdir -p "$CACHE_ROOT"

get_os() {
  local uname_out
  uname_out="$(uname -s)"
  case "${uname_out}" in
      Linux*)     os_type=linux;;
      Darwin*)    os_type=macos;;
      *)          os_type="UNKNOWN:${uname_out}"
  esac
  echo "${os_type}"
}

get_arch() {
  local arch_out
  arch_out="$(uname -m)"
  case "${arch_out}" in
      x86_64*)    arch_type=x64;;
      arm64*)     arch_type=arm64;;
      *)          arch_type="UNKNOWN:${arch_out}"
  esac
  echo "${arch_type}"
}

OS=$(get_os)
ARCH=$(get_arch)

register_git_hook() {
  local hook_name="pre-commit"
  local hook_path="${GIT_ROOT}/.git/hooks/${hook_name}"

  # Check if the hook file already exists
  if [ -f "${hook_path}" ]; then
    # Append the script execution if not already present
    if ! grep -q "${SCRIPT_PATH}" "${hook_path}"; then
      echo "" >> "${hook_path}"
      echo "# Hook to run accessibility scan before commit" >> "${hook_path}"
      echo "${SCRIPT_PATH}" >> "${hook_path}"
      echo "if [ \$? -ne 0 ]; then" >> "${hook_path}"
      echo "    echo \"Accessibility scan failed. Commit aborted.\"" >> "${hook_path}"
      echo "    exit 1" >> "${hook_path}"
      echo "fi" >> "${hook_path}"
    fi
  else
    # Create a new hook file
    cat > "${hook_path}" <<EOF
#!/bin/sh
# Hook to run accessibility scan before commit
"${SCRIPT_PATH}"
if [ \$? -ne 0 ]; then
    echo "Accessibility scan failed. Commit aborted."
    exit 1
fi
EOF
    chmod +x "${hook_path}"  # Make the hook executable
  fi
}

a11y_scan() {
  if [[ -z "$EXTRA_ARGS" ]]; then
    EXTRA_ARGS="--include **/*.swift --include **/*.xib --include **/*.storyboard"
  fi
  env -i HOME="$HOME" \
      XCODE_VERSION_ACTUAL="$XCODE_VERSION_ACTUAL"\
      BROWSERSTACK_USERNAME="$BROWSERSTACK_USERNAME"\
      BROWSERSTACK_ACCESS_KEY="$BROWSERSTACK_ACCESS_KEY"\
      PATH="$PATH" \
      $BINARY_PATH a11y $EXTRA_ARGS
}

# Self-update pulls the latest launcher from `main` on demand: it runs only via
# the explicit `self-update` subcommand (DEVA11Y-475), not automatically on every
# invocation. DEVA11Y-477/478: when it does run we deliberately follow main HEAD
# rather than a pinned revision (per maintainer intent: take the latest on demand).
# Hardening retained from the pinning work: download to a temp dir, verify a
# SHA-256 sidecar (a download-integrity check, NOT an authenticity signature --
# script and checksum share one origin), sanity-check the shebang, then
# atomically replace the on-disk script. Keep scripts/fish/cli.sh.sha256 on main in
# sync with this file (regenerate on every change) or updates will abort.
SELF_UPDATE_BRANCH="main"
readonly SELF_UPDATE_BRANCH
SELF_UPDATE_RELPATH="scripts/fish/cli.sh"
readonly SELF_UPDATE_RELPATH

# sha256 with a portable fallback: GNU `sha256sum` (Linux) or `shasum -a 256`
# (macOS / Perl Digest::SHA).
_self_update_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

script_self_update() {
  local base_url="https://raw.githubusercontent.com/browserstack/AccessibilityDevTools/refs/heads/${SELF_UPDATE_BRANCH}/${SELF_UPDATE_RELPATH}"
  local tmp_dir tmp_script tmp_sum expected_sum actual_sum local_sum target_path stage_file

  # Resolve the on-disk target absolutely so the replace never depends on CWD.
  if [[ -n "$GIT_ROOT" && "$SCRIPT_PATH" != /* ]]; then
    target_path="${GIT_ROOT}/${SCRIPT_PATH}"
  else
    target_path="$SCRIPT_PATH"
  fi

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/bs-a11y-selfupdate.XXXXXX") || {
    echo "Self-update: failed to create temp dir." >&2
    return 1
  }
  # Clean the work dir and any half-written staged file so an interrupt between
  # staging and the final mv can't leak a dotfile in the target directory. The
  # RETURN trap also clears the signal traps so they don't linger past this
  # function (which would otherwise swallow Ctrl-C during the main command).
  # tmp_dir is expanded now; stage_file is expanded when the trap fires (escaped $).
  # shellcheck disable=SC2064
  trap "rm -rf -- '${tmp_dir}'; rm -f -- \"\${stage_file:-}\"; trap - INT TERM" RETURN
  # shellcheck disable=SC2064
  trap "rm -rf -- '${tmp_dir}'; rm -f -- \"\${stage_file:-}\"; exit 130" INT TERM
  tmp_script="${tmp_dir}/cli.sh"
  tmp_sum="${tmp_dir}/cli.sh.sha256"

  # Fetch the checksum first; if our on-disk copy already matches, we're current.
  if ! curl -fsSL --connect-timeout 10 --max-time 30 "${base_url}.sha256" -o "$tmp_sum"; then
    echo "Self-update: could not fetch checksum from ${SELF_UPDATE_BRANCH}; skipping update." >&2
    return 0
  fi
  # Published sidecar is "<sha256>  <filename>"; take the first field.
  expected_sum=$(awk '{print $1; exit}' "$tmp_sum")
  if [[ -f "$target_path" ]]; then
    local_sum=$(_self_update_sha256 "$target_path")
    if [[ -n "$expected_sum" && "$local_sum" == "$expected_sum" ]]; then
      return 0
    fi
  fi

  if ! curl -fsSL --connect-timeout 10 --max-time 30 "$base_url" -o "$tmp_script"; then
    echo "Self-update: could not download latest script; skipping update." >&2
    return 0
  fi

  actual_sum=$(_self_update_sha256 "$tmp_script")
  if [[ -z "$expected_sum" || -z "$actual_sum" || "$expected_sum" != "$actual_sum" ]]; then
    echo "Self-update: checksum mismatch; refusing to apply." >&2
    echo "  expected: ${expected_sum:-<empty>}" >&2
    echo "  actual:   ${actual_sum:-<empty>}" >&2
    # Integrity violation — distinct exit code (2) so the caller can tell this
    # apart from a benign network skip (0) or an operational error (1).
    return 2
  fi

  # Sanity check AFTER integrity: ensure the verified payload is a script.
  if ! head -c2 "$tmp_script" | grep -q '^#!'; then
    echo "Self-update: downloaded file is not a script; aborting." >&2
    return 2
  fi

  # Stage inside the target's directory so the rename is atomic (mv across
  # filesystems would degrade to a non-atomic copy).
  stage_file=$(mktemp "$(dirname "$target_path")/.bs-a11y-update.XXXXXX") || {
    echo "Self-update: failed to stage update next to ${target_path}." >&2
    return 1
  }
  if cp "$tmp_script" "$stage_file" && chmod 0755 "$stage_file" && mv -f "$stage_file" "$target_path"; then
    echo "Self-update: updated ${target_path} to latest ${SELF_UPDATE_BRANCH}."
  else
    rm -f -- "$stage_file"
    echo "Self-update: failed to replace ${target_path}." >&2
    return 1
  fi
}

strip_quarantine() {
  # macOS Gatekeeper refuses to run binaries carrying the com.apple.quarantine
  # attribute unless they are Developer ID signed and notarized. Some managed
  # environments (MDM/security tooling) stamp this attribute on network-written
  # files, which blocks the downloaded CLI with no "Allow Anyway" option. Strip
  # it if present. No-op on non-macOS and when the attribute is absent.
  if [[ "$OS" == "macos" ]] && command -v xattr >/dev/null 2>&1; then
    xattr -d com.apple.quarantine "$BINARY_PATH" 2>/dev/null || true
  fi
}

# DEVA11Y-473/474: verify the downloaded CLI archive against a server-published
# SHA-256 sidecar before extracting and executing it. api.browserstack.com (the
# control plane) 302-redirects to a versioned, immutable asset on the CDN/S3 (the
# data plane); a checksum published next to that asset lets us detect a tampered
# or corrupted binary before `chmod 0755` + exec. Semantics mirror self-update:
# fail CLOSED on a checksum mismatch, fail OPEN (warn + proceed) when no sidecar
# is published yet, so this stays non-breaking until the SDK-assets team ships the
# sidecars (the server-side half of DEVA11Y-473/474).
verify_binary_integrity() {
  local zip_path="$1" resolved_url="$2" sum_url tmp_sum expected actual
  if [[ -z "$resolved_url" ]]; then
    echo "CLI download: could not resolve asset URL; skipping integrity check (DEVA11Y-473/474)." >&2
    return 0
  fi
  # Derive the sidecar from the asset path only. Stripping any query string keeps
  # signed/presigned URLs (…zip?token=) from deriving a permanently-404 sidecar
  # (…zip?token=.sha256), which would silently disable verification.
  sum_url="${resolved_url%%\?*}.sha256"
  tmp_sum=$(mktemp "${TMPDIR:-/tmp}/bs-a11y-clisum.XXXXXX") || return 0
  # shellcheck disable=SC2064
  trap "rm -f -- '${tmp_sum}'" RETURN
  if ! curl -fsSL --connect-timeout 10 --max-time 30 "$sum_url" -o "$tmp_sum" 2>/dev/null; then
    echo "CLI download: no published checksum at ${sum_url}; proceeding WITHOUT integrity verification (DEVA11Y-473/474)." >&2
    return 0
  fi
  expected=$(awk '{print $1; exit}' "$tmp_sum" | tr 'A-Z' 'a-z')
  actual=$(_self_update_sha256 "$zip_path" | tr 'A-Z' 'a-z')
  # A present-but-empty sidecar body is a hard failure: once the server publishes
  # checksums, a blank value must not silently downgrade to "no verification".
  if [[ -z "$expected" ]]; then
    echo "CLI download: empty checksum at ${sum_url}; refusing to use the downloaded binary." >&2
    rm -f -- "$zip_path"
    return 2
  fi
  # A non-empty body that is NOT a 64-char hex digest is a CDN/S3 error page answered 200
  # (e.g. an S3 `AccessDenied` XML), not a checksum. Its first token must not become the
  # "expected hash" and hard-fail every client on every run; fail OPEN instead (DEVA11Y-473/474 review).
  if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "CLI download: malformed checksum at ${sum_url}; proceeding WITHOUT verification (DEVA11Y-473/474)." >&2
    return 0
  fi
  if [[ -z "$actual" || "$expected" != "$actual" ]]; then
    echo "CLI download: checksum mismatch; refusing to use the downloaded binary." >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual:-<empty>}" >&2
    rm -f -- "$zip_path"
    return 2
  fi
}

download_binary() {
  local max_compressed=104857600   # 100 MB cap on the compressed download
  local max_decompressed=209715200 # 200 MB cap on the decompressed binary

  # --max-filesize aborts the transfer once the declared size is known to exceed the cap.
  # Measured against this endpoint (which 302s to sdk-assets), curl bails with a non-zero
  # exit and nothing written to disk. curl documents the flag as a no-op when the length is
  # unknown (chunked responses), so the explicit size check below backstops that case —
  # otherwise an attacker-controlled endpoint could exhaust the disk during download, before
  # the checksum and the decompression guard ever run (DEVA11Y-484 review).
  local resolved_url
  resolved_url=$(curl -fR --max-filesize "$max_compressed" -z "$BINARY_ZIP_PATH" -L "https://api.browserstack.com/sdk/v1/download_cli?os=${OS}&os_arch=${ARCH}" -o "$BINARY_ZIP_PATH" -w '%{url_effective}') || {
    echo "CLI download failed or exceeds the maximum allowed download size (100 MB)." >&2
    rm -f "$BINARY_ZIP_PATH"
    return 1
  }

  local compressed_size
  compressed_size=$(wc -c < "$BINARY_ZIP_PATH" 2>/dev/null || echo 0)
  if [[ $compressed_size -gt $max_compressed ]]; then
    echo "BrowserStack CLI archive exceeds the maximum allowed download size (100 MB). Aborting." >&2
    rm -f "$BINARY_ZIP_PATH"
    return 1
  fi

  verify_binary_integrity "$BINARY_ZIP_PATH" "$resolved_url" || return $?

  # Extract to a temp path and atomically publish it. `> "$BINARY_PATH"` truncates the
  # destination before bsdtar is known to have succeeded, so a corrupt payload — the live
  # case today, since no sidecars are published yet and verification fails open — would
  # zero out a previously-good cached binary. Stage + mv keeps the cached binary intact
  # unless a fresh, extractable payload is in hand (DEVA11Y-473/474 review).
  #
  # The decompression-bomb guard (DEVA11Y-484) sits on that same staged path: head -c stops
  # bsdtar via SIGPIPE once the decompressed output reaches the cap, and pipefail surfaces
  # that as a failure. Because the cap applies to ${BINARY_PATH}.tmp and publication is a
  # later mv, a rejected bomb leaves any previously-cached binary untouched.
  # Save and restore pipefail rather than clearing it: these scripts do not enable it
  # globally today, but unconditionally turning it off would silently disable it for
  # everything after download_binary if they ever do (DEVA11Y-484 review).
  local pipefail_was_set=0
  case "$(set +o)" in *"-o pipefail"*) pipefail_was_set=1 ;; esac
  set -o pipefail
  bsdtar -xvf "$BINARY_ZIP_PATH" -O | head -c "$max_decompressed" > "${BINARY_PATH}.tmp"
  local extract_status=$?
  [[ $pipefail_was_set -eq 1 ]] || set +o pipefail

  local extracted_size
  extracted_size=$(wc -c < "${BINARY_PATH}.tmp" 2>/dev/null || echo 0)
  if [[ $extract_status -ne 0 || $extracted_size -ge $max_decompressed ]]; then
    echo "BrowserStack CLI download failed or exceeds the maximum allowed size (200 MB). Aborting." >&2
    rm -f "${BINARY_PATH}.tmp"
    return 1
  fi

  # Clean the staged file up on *any* failure below, not just the size rejection above,
  # so a failed chmod/mv never leaves a stray ${BINARY_PATH}.tmp in the cache.
  if ! { chmod 0755 "${BINARY_PATH}.tmp" && mv -f "${BINARY_PATH}.tmp" "$BINARY_PATH"; }; then
    echo "BrowserStack CLI: failed to publish the downloaded binary." >&2
    rm -f "${BINARY_PATH}.tmp"
    return 1
  fi
  strip_quarantine
}

# Self-update is opt-in (DEVA11Y-475): it runs only via the explicit `self-update`
# subcommand, never automatically on every invocation. Running it unconditionally
# before subcommand parsing meant a single compromise of the fetched source silently
# replaced the running script on every developer's machine, with no way to opt out;
# gating it behind an explicit command removes that always-on side-effect. Integrity
# verification (SHA-256 check + atomic staging) still guards the download itself.
if [[ $SUBCOMMAND == "self-update" ]]; then
  _self_update_rc=0
  script_self_update || _self_update_rc=$?
  if [[ "$_self_update_rc" -eq 2 ]]; then
    echo "Self-update: integrity verification FAILED; kept the existing verified script (possible corruption or tampering)." >&2
  fi
  exit "$_self_update_rc"
fi

if [[ $SUBCOMMAND == "register-pre-commit-hook" ]]; then
  register_git_hook
  exit 0
fi

# Abort before executing the CLI if the download or its integrity check failed
# (checksum mismatch returns 2 from download_binary -> DEVA11Y-473/474).
download_binary || exit $?
a11y_scan

