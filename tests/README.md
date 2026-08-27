# Integration test harnesses

End-to-end harnesses that integrate the `a11y-scan` command plugin from this
repository into real consumer projects and run accessibility scans against
sample sources with intentional issues. Each harness uses a **path dependency**
on the repo root (`../..`), so it always exercises the local plugin sources.

| Folder | Consumer type | How the plugin is integrated |
|---|---|---|
| [`spm/`](./spm) | SwiftPM package | Package dependency on `AccessibilityDevTools`; the command plugin is invoked with `swift package plugin … scan`. |
| [`xcode-app/`](./xcode-app) | Xcode iOS app (XcodeGen) | A pre-compile build phase runs the scan on every build — the official Xcode integration. |

## Why two harnesses

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

Both harnesses need BrowserStack credentials to actually run a scan (the plugin
downloads the CLI and makes authenticated calls):

```bash
export BROWSERSTACK_USERNAME=<your-username>
export BROWSERSTACK_ACCESS_KEY=<your-access-key>
```

Without credentials, the SPM end-to-end test skips and the Xcode build phase
no-ops with a warning, so builds/tests stay green.
