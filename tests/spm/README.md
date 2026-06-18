# SwiftPM integration harness

A SwiftPM package (`A11yScanSPMConsumer`) that consumes the `a11y-scan` command
plugin from this repository via a path dependency on the repo root.

```
spm/
├── Package.swift                 # path dependency on ../.. (AccessibilityDevTools)
├── Sources/A11yDemoLib/          # sample SwiftUI views with intentional a11y issues
├── Tests/A11yDemoLibTests/       # unit test + gated end-to-end scan test
└── scripts/run-a11y-scan.sh      # invokes the command plugin
```

## Build & test

```bash
cd tests/spm
swift build      # compiles the plugin + sample sources
swift test       # unit test passes; the end-to-end scan test skips by default
```

## Run the accessibility scan

```bash
export BROWSERSTACK_USERNAME=<your-username>
export BROWSERSTACK_ACCESS_KEY=<your-access-key>
./scripts/run-a11y-scan.sh                 # fails the run on issues
./scripts/run-a11y-scan.sh --non-strict    # reports issues without failing
```

The script runs:

```bash
swift package plugin \
  --allow-writing-to-directory ~/.cache \
  --allow-writing-to-package-directory \
  --allow-network-connections 'all(ports: [])' \
  scan --include "**/*.swift" --include "**/*.xib" --include "**/*.storyboard"
```

To run the scan as part of `swift test`, set `RUN_A11Y_SCAN=1` (with credentials);
otherwise `testA11yScanPluginRuns` is skipped.

> `a11y-scan` is a **command** plugin, so it is invoked explicitly — it is not
> attached to a target's `plugins:` array (that would make `swift build` treat
> it as a build-tool plugin and fail).
