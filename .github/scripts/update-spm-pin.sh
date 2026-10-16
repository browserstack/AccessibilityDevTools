#!/usr/bin/env bash
# Pins the AccessibilityDevTools dependency in the synthetic Package.swift that
# scripts/{bash,zsh,fish}/spm.sh generate to an immutable commit SHA, and
# regenerates each script's .sha256 self-update sidecar (DEVA11Y-477 / F-005).
#
# Usage: .github/scripts/update-spm-pin.sh [<40-char sha>]
#   With no argument, pins to the latest first-parent commit on origin/main that
#   touched the plugin itself (Package.swift or Plugins/). Commits that only touch
#   scripts/ (including the pin bumps this produces) never move that SHA, so a
#   merged bump cannot trigger another bump.
#
# Prints the pinned SHA. Run from the repository root.
set -euo pipefail

SCRIPTS=(scripts/bash/spm.sh scripts/zsh/spm.sh scripts/fish/spm.sh)
DEP_URL='https://github.com/browserstack/AccessibilityDevTools.git'

sha="${1:-$(git log -1 --first-parent --format=%H origin/main -- Package.swift Plugins)}"
if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "error: '${sha}' is not a full 40-character commit SHA" >&2
  exit 1
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

for script in "${SCRIPTS[@]}"; do
  # Replace whatever requirement the dependency line has today (branch: "main" or
  # a previous revision: "<sha>") with the new revision pin.
  sed -E "s#(\\.package\\(url: \"${DEP_URL}\", )(branch|revision): \"[^\"]*\"\\)#\\1revision: \"${sha}\")#" \
    "$script" > "${script}.tmp"
  if ! grep -Fq ".package(url: \"${DEP_URL}\", revision: \"${sha}\")" "${script}.tmp"; then
    rm -f "${script}.tmp"
    echo "error: dependency line not found in ${script}" >&2
    exit 1
  fi
  cat "${script}.tmp" > "$script" # keep the original file mode
  rm -f "${script}.tmp"
  printf '%s  %s\n' "$(sha256_of "$script")" "$(basename "$script")" > "${script}.sha256"
done

echo "$sha"
