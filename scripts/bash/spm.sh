#!/usr/bin/env bash -il

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
  # Scan target is always the directory the user invoked us from.
  local scan_root="${PWD}"

  # Per-invocation staging directory for the synthetic manifest. Using a unique
  # temp dir (instead of writing Package.swift into the user's CWD) prevents
  # concurrent invocations from deleting each other's manifest on exit
  # (DEVA11Y-483 / F-014). Only created when the user has no Package.swift.
  local synthetic_pkg_dir=""

  # Ensure the per-invocation temp dir is removed on exit (acts like a finally
  # block). We only ever delete our own temp dir, never files in the user's CWD.
  cleanup() {
      if [ -n "$synthetic_pkg_dir" ] && [ -d "$synthetic_pkg_dir" ]; then
          rm -rf -- "$synthetic_pkg_dir"
      fi
  }
  trap cleanup EXIT

  setup() {
      if [ $PACKAGE_EXISTS -eq 0 ]; then
          return
      fi

      synthetic_pkg_dir="$(mktemp -d "${TMPDIR:-/tmp}/bstack-a11y-spm.XXXXXX")"

      cat > "${synthetic_pkg_dir}/Package.swift" <<EOF
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
    EXTRA_ARGS="--include ${scan_root}/**/*.swift --include ${scan_root}/**/*.xib --include ${scan_root}/**/*.storyboard"
  fi

  # When we synthesized a manifest, run the plugin against that temp package
  # directory (--package-path). The scan still targets the user's sources because
  # the include globs are rooted at the original working directory. When the user
  # already has a Package.swift, scan it in place exactly as before.
  local package_path_args=()
  if [ -n "$synthetic_pkg_dir" ]; then
    package_path_args=(--package-path "$synthetic_pkg_dir")
  fi

  env -i HOME="$HOME" \
      XCODE_VERSION_ACTUAL="$XCODE_VERSION_ACTUAL"\
      BROWSERSTACK_USERNAME="$BROWSERSTACK_USERNAME"\
      BROWSERSTACK_ACCESS_KEY="$BROWSERSTACK_ACCESS_KEY"\
      PATH="$PATH" \
      swift package "${package_path_args[@]}" plugin \
          --allow-writing-to-directory ~/.cache\
          --allow-writing-to-package-directory\
          --allow-network-connections 'all(ports: [])'\
          scan $EXTRA_ARGS
}

script_self_update() {
  local remote_url="https://raw.githubusercontent.com/browserstack/AccessibilityDevTools/refs/heads/main/scripts/bash/spm.sh"

  updated_script=$(curl -R -z "$SCRIPT_PATH" "$remote_url")
  if [[ $updated_script =~ ^#! ]]; then
    echo "$updated_script" > "$SCRIPT_PATH"
  fi
}

script_self_update
if [[ $SUBCOMMAND == "register-pre-commit-hook" ]]; then
  register_git_hook
  exit 0
fi

a11y_scan