# Test harnesses

Two different kinds of suite live here.

**Integration harnesses** (`spm/`, `xcode-app/`) integrate the `a11y-scan` command
plugin from this repository into real consumer projects and run accessibility scans
against sample sources with intentional issues. Each uses a **path dependency** on
the repo root (`../..`), so it always exercises the local plugin sources.

**Regression suites** (`extraction-guard/`) test one hardened code path directly —
no consumer project, no credentials, no network.

| Folder | Kind | What it exercises |
|---|---|---|
| [`spm/`](./spm) | Integration | SwiftPM consumer: package dependency on `AccessibilityDevTools`; the command plugin is invoked with `swift package plugin … scan`. |
| [`xcode-app/`](./xcode-app) | Integration | Xcode iOS app (XcodeGen): a pre-compile build phase runs the scan on every build — the official Xcode integration. |
| [`extraction-guard/`](./extraction-guard) | Regression | The DEVA11Y-484 decompression-bomb guard in the shell launchers (`scripts/{bash,zsh,fish}/cli.sh`). Run with `bash tests/extraction-guard/run_tests.sh`. |

## Why two integration harnesses

The plugin supports both project types the product targets — SwiftPM packages
and Xcode apps — and they integrate the **command** plugin differently:

- **SwiftPM** consumers declare the package dependency and invoke the command
  plugin directly (`swift package plugin … scan`). The plugin must **not** be
  attached to a target's `plugins:` array — `a11y-scan` is a *command* plugin,
  not a build-tool plugin, and attaching it breaks `swift build`.
- **Xcode** apps have no `Package.swift`, so the integration synthesizes a
  minimal one to host the command plugin and runs it from a build phase. This
  harness checks that minimal package in directly (`xcode-app/Package.swift`).

## Authentication

Both **integration** harnesses need BrowserStack credentials to actually run a scan
(the plugin downloads the CLI and makes authenticated calls). The
`extraction-guard/` regression suite needs none — it serves its own fixtures over
localhost:

```bash
export BROWSERSTACK_USERNAME=<your-username>
export BROWSERSTACK_ACCESS_KEY=<your-access-key>
```

Without credentials, the SPM end-to-end test skips and the Xcode build phase
no-ops with a warning, so builds/tests stay green.
