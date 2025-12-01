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
    EXTRA_ARGS="--include **/*.swift"
  fi
  env -i HOME="$HOME" \
      XCODE_VERSION_ACTUAL="$XCODE_VERSION_ACTUAL"\
      BROWSERSTACK_USERNAME="$BROWSERSTACK_USERNAME"\
      BROWSERSTACK_ACCESS_KEY="$BROWSERSTACK_ACCESS_KEY"\
      PATH="$PATH" \
      $BINARY_PATH a11y $EXTRA_ARGS
}

script_self_update() {
  local remote_url="https://raw.githubusercontent.com/browserstack/AccessibilityDevTools/refs/heads/main/scripts/bash/spm.sh"

  updated_script=$(curl -R -z "$SCRIPT_PATH" "$remote_url")
  if [[ $updated_script =~ ^#! ]]; then
    echo "$updated_script" > "$SCRIPT_PATH"
  fi
}

download_binary() {
  curl -R -z "$BINARY_ZIP_PATH" -L "http://api.browserstack.com/sdk/v1/download_cli?os=${OS}&os_arch=${ARCH}" -o "$BINARY_ZIP_PATH"
  bsdtar -xvf "$BINARY_ZIP_PATH" -O > "$BINARY_PATH" && chmod 0775 "$BINARY_PATH"
}

script_self_update
if [[ $SUBCOMMAND == "register-pre-commit-hook" ]]; then
  register_git_hook
  exit 0
fi

download_binary
a11y_scan
