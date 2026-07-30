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

# Don't change anything after this, same as the bash equivalent
[ -f "${PWD}/Package.swift" ]
PACKAGE_EXISTS="$?"
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
SCRIPT_PATH=$(realpath --relative-to="$GIT_ROOT" "$0" 2>/dev/null || realpath "$0")
SUBCOMMAND="$1"
EXTRA_ARGS=$@

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
  # Ensure Package.swift is removed on exit (acts like a finally block)
  cleanup() {
      if [ $PACKAGE_EXISTS -eq 0 ]; then
          return
      fi
      rm -f -- "${PWD}/Package.swift" "${PWD}/Package.resolved"
  }
  trap cleanup EXIT

  setup() {
      if [ $PACKAGE_EXISTS -eq 0 ]; then
          return
      fi

      cat > Package.swift <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dummy",
    dependencies: [
        .package(url: "https://github.com/browserstack/AccessibilityDevTools.git", branch: "main")
    ],
    targets: []
)
EOF
  }

  setup
  if [[ -z "$EXTRA_ARGS" ]]; then
    EXTRA_ARGS="--include **/*.swift --include **/*.xib --include **/*.storyboard"
  fi
  env -i HOME="$HOME" \
      XCODE_VERSION_ACTUAL="$XCODE_VERSION_ACTUAL"\
      BROWSERSTACK_USERNAME="$BROWSERSTACK_USERNAME"\
      BROWSERSTACK_ACCESS_KEY="$BROWSERSTACK_ACCESS_KEY"\
      PATH="$PATH" \
      swift package plugin \
          --allow-writing-to-directory ~/.cache\
          --allow-writing-to-package-directory\
          --allow-network-connections 'all(ports: [])'\
          scan $EXTRA_ARGS
}

# Self-update tracks the latest launcher on `main` so users always run the
# newest version. DEVA11Y-475/477/478: we deliberately follow main HEAD rather
# than a pinned revision (per maintainer intent: always take the latest).
# Hardening retained from the pinning work: download to a temp dir, verify a
# SHA-256 sidecar (a download-integrity check, NOT an authenticity signature --
# script and checksum share one origin), sanity-check the shebang, then
# atomically replace the on-disk script. Keep scripts/fish/spm.sh.sha256 on main in
# sync with this file (regenerate on every change) or updates will abort.
SELF_UPDATE_BRANCH="main"
readonly SELF_UPDATE_BRANCH
SELF_UPDATE_RELPATH="scripts/fish/spm.sh"
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
  tmp_script="${tmp_dir}/spm.sh"
  tmp_sum="${tmp_dir}/spm.sh.sha256"

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

a11y_scan