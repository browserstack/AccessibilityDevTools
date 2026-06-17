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

# Pinned, immutable git revision the self-update is allowed to fetch from.
# DEVA11Y-475: never fetch executable code from a mutable branch HEAD.
# Bump this (and the published .sha256 sidecars) on every release.
SELF_UPDATE_REF="db817c37cf74cba47e2fef535f53a35bfc88ec6a"
SELF_UPDATE_RELPATH="scripts/bash/cli.sh"

# DEVA11Y-475 / F-003: self-update is OPT-IN (run with `--self-update`),
# fetches from a pinned revision (not a mutable branch), verifies a SHA-256
# checksum before use, and atomically replaces the script instead of
# overwriting the currently-running file in place.
script_self_update() {
  local base_url="https://raw.githubusercontent.com/browserstack/AccessibilityDevTools/${SELF_UPDATE_REF}/${SELF_UPDATE_RELPATH}"
  local tmp_dir tmp_script tmp_sum expected_sum actual_sum

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/bs-a11y-selfupdate.XXXXXX") || {
    echo "Self-update: failed to create temp dir." >&2
    return 1
  }
  # shellcheck disable=SC2064
  trap "rm -rf -- '${tmp_dir}'" RETURN
  tmp_script="${tmp_dir}/cli.sh"
  tmp_sum="${tmp_dir}/cli.sh.sha256"

  if ! curl -fsSL "$base_url" -o "$tmp_script"; then
    echo "Self-update: failed to download script from pinned revision." >&2
    return 1
  fi
  if ! curl -fsSL "${base_url}.sha256" -o "$tmp_sum"; then
    echo "Self-update: failed to download checksum; aborting (integrity unverifiable)." >&2
    return 1
  fi

  if ! head -c2 "$tmp_script" | grep -q '^#!'; then
    echo "Self-update: downloaded file is not a script; aborting." >&2
    return 1
  fi

  # Published sidecar is "<sha256>  <filename>"; take the first field.
  expected_sum=$(awk '{print $1; exit}' "$tmp_sum")
  actual_sum=$(shasum -a 256 "$tmp_script" | awk '{print $1}')
  if [[ -z "$expected_sum" || "$expected_sum" != "$actual_sum" ]]; then
    echo "Self-update: checksum mismatch; refusing to apply." >&2
    echo "  expected: ${expected_sum:-<empty>}" >&2
    echo "  actual:   ${actual_sum}" >&2
    return 1
  fi

  chmod 0755 "$tmp_script"
  # Atomic replace: never overwrite the running script in place.
  if mv -f "$tmp_script" "$SCRIPT_PATH"; then
    echo "Self-update: updated ${SCRIPT_PATH} to pinned revision ${SELF_UPDATE_REF}."
  else
    echo "Self-update: failed to replace ${SCRIPT_PATH}." >&2
    return 1
  fi
}

download_binary() {
  curl -R -z "$BINARY_ZIP_PATH" -L "https://api.browserstack.com/sdk/v1/download_cli?os=${OS}&os_arch=${ARCH}" -o "$BINARY_ZIP_PATH"
  bsdtar -xvf "$BINARY_ZIP_PATH" -O > "$BINARY_PATH" && chmod 0775 "$BINARY_PATH"
}

if [[ $SUBCOMMAND == "--self-update" ]]; then
  script_self_update
  exit $?
fi

if [[ $SUBCOMMAND == "register-pre-commit-hook" ]]; then
  register_git_hook
  exit 0
fi

download_binary
a11y_scan
