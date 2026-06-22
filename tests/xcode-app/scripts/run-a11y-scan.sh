#!/usr/bin/env bash
# Runs the BrowserStack `a11y-scan` command plugin over this Xcode app's
# Sources/. Invoked as a pre-compile build phase by the generated project, and
# also runnable standalone.
#
# Requires BrowserStack credentials in the environment:
#   export BROWSERSTACK_USERNAME=<your-username>
#   export BROWSERSTACK_ACCESS_KEY=<your-access-key>
#
# Extra arguments are forwarded to the scan (e.g. --non-strict).
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${BROWSERSTACK_USERNAME:-}" || -z "${BROWSERSTACK_ACCESS_KEY:-}" ]]; then
  echo "warning: BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY not set; skipping accessibility scan." >&2
  exit 0
fi

swift package plugin \
  --allow-writing-to-directory "$HOME/.cache" \
  --allow-writing-to-package-directory \
  --allow-network-connections 'all(ports: [])' \
  scan \
  --include "**/*.swift" \
  --include "**/*.xib" \
  --include "**/*.storyboard" \
  "$@"
