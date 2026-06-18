#!/usr/bin/env bash
# Runs the BrowserStack `a11y-scan` command plugin against this SwiftPM package.
#
# Requires BrowserStack credentials in the environment:
#   export BROWSERSTACK_USERNAME=<your-username>
#   export BROWSERSTACK_ACCESS_KEY=<your-access-key>
#
# Any extra arguments are forwarded to the scan (e.g. --non-strict).
set -euo pipefail

cd "$(dirname "$0")/.."

: "${BROWSERSTACK_USERNAME:?Set BROWSERSTACK_USERNAME before running the scan}"
: "${BROWSERSTACK_ACCESS_KEY:?Set BROWSERSTACK_ACCESS_KEY before running the scan}"

swift package plugin \
  --allow-writing-to-directory "$HOME/.cache" \
  --allow-writing-to-package-directory \
  --allow-network-connections 'all(ports: [])' \
  scan \
  --include "**/*.swift" \
  --include "**/*.xib" \
  --include "**/*.storyboard" \
  "$@"
