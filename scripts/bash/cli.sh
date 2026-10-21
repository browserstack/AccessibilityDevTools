#!/usr/bin/env bash -il

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
# atomically replace the on-disk script. Keep scripts/bash/cli.sh.sha256 on main in
# sync with this file (regenerate on every change) or updates will abort.
SELF_UPDATE_BRANCH="main"
readonly SELF_UPDATE_BRANCH
SELF_UPDATE_RELPATH="scripts/bash/cli.sh"
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

# DEVA11Y-473/474: verify the extracted CLI binary's code signature before it is made
# executable, published or run, failing CLOSED. The CDN publishes no checksum, so we
# check the signature BrowserStack already ships the binary with: that proves who built
# it, which a compromised CDN/origin cannot forge. Mirrors the SwiftPM plugin.
#   - macOS: `codesign --verify --strict` against a Developer ID requirement pinned to
#     BrowserStack's Team ID.
#   - Linux: the CLI build is unsigned, so there is nothing to verify. Security accepted
#     that residual risk on DEVA11Y-473 until the Linux build is signed or the API serves
#     a digest (SDK-6482).
verify_binary_signature() {
  local binary_path="$1" team_id="YQ5FZQ855D" requirement codesign_out
  case "$OS" in
    linux) return 0 ;;
    macos) ;;
    *)
      echo "BrowserStack CLI: cannot verify the binary's signature on ${OS}; refusing to run it." >&2
      return 2
      ;;
  esac
  requirement="=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${team_id}\""
  if ! codesign_out=$(/usr/bin/codesign --verify --strict -R "$requirement" "$binary_path" 2>&1); then
    echo "BrowserStack CLI signature verification failed; refusing to run the downloaded binary." >&2
    echo "  ${codesign_out}" >&2
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
  # the signature check and the decompression guard ever run (DEVA11Y-484 review).
  local resolved_url curl_status=0
  resolved_url=$(curl -fR --max-filesize "$max_compressed" -z "$BINARY_ZIP_PATH" -L "https://api.browserstack.com/sdk/v1/download_cli?os=${OS}&os_arch=${ARCH}" -o "$BINARY_ZIP_PATH" -w '%{url_effective}') || curl_status=$?
  if [[ $curl_status -ne 0 ]]; then
    # Distinguish a size abort from a network failure by what landed on disk rather than by
    # curl's exit code: --max-filesize is documented to exit 63, but measured against this
    # endpoint (which 302s to sdk-assets) curl aborts during receive and exits 56 instead, so
    # branching on 63 alone would misreport the common case (DEVA11Y-484 review).
    local partial_size
    partial_size=$(wc -c < "$BINARY_ZIP_PATH" 2>/dev/null || echo 0)
    if [[ $partial_size -ge $max_compressed ]]; then
      echo "BrowserStack CLI archive exceeds the maximum allowed download size (100 MB). Aborting." >&2
    else
      echo "BrowserStack CLI download failed (curl exited $curl_status)." >&2
    fi
    # Remove unconditionally, including on a transient network error. This deliberately gives
    # up the -z If-Modified-Since fast path on the next run: a partial write carries a fresh
    # mtime, so keeping it risks the next -z revalidation getting a 304 and handing a
    # truncated archive to the extractor. Losing a 304 is cheaper than trusting a truncated
    # payload.
    rm -f "$BINARY_ZIP_PATH"
    return 1
  fi

  local compressed_size
  compressed_size=$(wc -c < "$BINARY_ZIP_PATH" 2>/dev/null || echo 0)
  if [[ $compressed_size -gt $max_compressed ]]; then
    echo "BrowserStack CLI archive exceeds the maximum allowed download size (100 MB). Aborting." >&2
    rm -f "$BINARY_ZIP_PATH"
    return 1
  fi

  # Extract to a temp path and atomically publish it. `> "$BINARY_PATH"` truncates the
  # destination before bsdtar is known to have succeeded, so a corrupt payload would zero
  # out a previously-good cached binary. Stage + mv keeps the cached binary intact unless a
  # fresh, extractable, correctly signed payload is in hand (DEVA11Y-473/474 review).
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
  # `|| extract_status=$?` rather than a bare pipeline: the shebang is `bash -il`, so the
  # user's rc files are sourced, and if one of them sets `-e` a bare failing pipeline aborts
  # the script here — skipping the diagnostics below and leaving ${BINARY_PATH}.tmp behind,
  # the exact residue the publish-failure cleanup was added to prevent (DEVA11Y-484 review).
  local extract_status=0
  bsdtar -xvf "$BINARY_ZIP_PATH" -O | head -c "$max_decompressed" > "${BINARY_PATH}.tmp" || extract_status=$?
  [[ $pipefail_was_set -eq 1 ]] || set +o pipefail

  local extracted_size
  extracted_size=$(wc -c < "${BINARY_PATH}.tmp" 2>/dev/null || echo 0)

  # Size first, and `-ge` not `-gt`: head -c caps output at exactly $max_decompressed, so a
  # file of exactly that size is indistinguishable from a truncated overflow and must be
  # rejected. A bomb trips both this and extract_status (SIGPIPE), and the size message is
  # the accurate one, so it is checked first.
  if [[ $extracted_size -ge $max_decompressed ]]; then
    echo "BrowserStack CLI archive exceeds the maximum allowed decompressed size (200 MB). Aborting." >&2
    rm -f "${BINARY_PATH}.tmp"
    return 1
  fi
  if [[ $extract_status -ne 0 ]]; then
    echo "BrowserStack CLI archive could not be extracted (bsdtar exited $extract_status). Aborting." >&2
    rm -f "${BINARY_PATH}.tmp"
    return 1
  fi

  # Verify BEFORE chmod/publish. The archive is re-extracted on every run (even on a 304),
  # so this also covers a cached zip. On failure drop the zip too, otherwise the next run's
  # If-Modified-Since request gets a 304 and keeps re-extracting the same rejected payload.
  local verify_status=0
  verify_binary_signature "${BINARY_PATH}.tmp" || verify_status=$?
  if [[ $verify_status -ne 0 ]]; then
    rm -f "${BINARY_PATH}.tmp" "$BINARY_ZIP_PATH"
    return $verify_status
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

# Abort before executing the CLI if the download or its signature check failed
# (a failed signature check returns 2 from download_binary -> DEVA11Y-473/474).
download_binary || exit $?
a11y_scan
