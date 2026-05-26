#!/usr/bin/env bash -il

ORIGINAL_DIR="${PWD}"
HAS_EXISTING_PACKAGE=0
[ -f "${PWD}/Package.swift" ] && HAS_EXISTING_PACKAGE=1
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
      if [ $HAS_EXISTING_PACKAGE -eq 1 ]; then
          return
      fi
      if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
          rm -rf -- "$WORK_DIR"
      fi
  }
  trap cleanup EXIT

  setup() {
      if [ $HAS_EXISTING_PACKAGE -eq 1 ]; then
          WORK_DIR="$ORIGINAL_DIR"
          return
      fi

      WORK_DIR=$(mktemp -d)
      cat > "$WORK_DIR/Package.swift" <<EOF
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dummy",
    dependencies: [
        .package(url: "https://github.com/browserstack/AccessibilityDevTools.git", revision: "0428b322b00494b19e44c20c37502a0ee31af642")
    ],
    targets: []
)
EOF
  }

  setup
  if [[ -z "$EXTRA_ARGS" ]]; then
    EXTRA_ARGS="--include **/*.swift --include **/*.xib --include **/*.storyboard"
  fi
  cd "$WORK_DIR"
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

if [[ $SUBCOMMAND == "register-pre-commit-hook" ]]; then
  register_git_hook
  exit 0
fi

a11y_scan