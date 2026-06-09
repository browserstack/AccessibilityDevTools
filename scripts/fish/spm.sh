#!/usr/bin/env bash -il
SCRIPT_VERSION="v1.0.0"

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

script_self_update() {
  local repo_base="https://raw.githubusercontent.com/browserstack/AccessibilityDevTools"
  local version_url="${repo_base}/refs/heads/main/scripts/latest-version.txt"
  local script_rel_path="fish/spm.sh"

  # Fetch remote version (lightweight metadata from main, not executable code)
  local remote_version
  remote_version=$(curl -fsSL --max-time 10 "$version_url" 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$remote_version" || "$remote_version" == "$SCRIPT_VERSION" ]]; then
    return 0
  fi

  # Fetch script and checksums from immutable tagged ref
  local tag_base="${repo_base}/refs/tags/${remote_version}/scripts"
  local tmp_script tmp_sums
  tmp_script=$(mktemp)
  tmp_sums=$(mktemp)
  trap 'rm -f "$tmp_script" "$tmp_sums"' RETURN

  if ! curl -fsSL --max-time 30 "${tag_base}/${script_rel_path}" -o "$tmp_script" 2>/dev/null; then
    return 0
  fi
  if ! curl -fsSL --max-time 10 "${tag_base}/SHA256SUMS" -o "$tmp_sums" 2>/dev/null; then
    return 0
  fi

  # Verify SHA-256 checksum
  local expected actual
  expected=$(grep "  ${script_rel_path}$" "$tmp_sums" | cut -d' ' -f1)
  actual=$(shasum -a 256 "$tmp_script" | cut -d' ' -f1)
  if [[ -z "$expected" || "$actual" != "$expected" ]]; then
    echo "[self-update] WARNING: Checksum verification failed for ${script_rel_path}. Update aborted." >&2
    return 1
  fi

  cp "$tmp_script" "$0"
  echo "[self-update] Updated to ${remote_version}." >&2
}

script_self_update
if [[ $SUBCOMMAND == "register-pre-commit-hook" ]]; then
  register_git_hook
  exit 0
fi

a11y_scan