# DEVA11Y-484 — decompression-bomb guard regression tests

Real, local integration tests for the size/entry guards added to the CLI download path.
**No mocks** — every test runs actual `curl`, `bsdtar`, `head`, and (for the plugin) real
`Process`/watchdog logic against crafted archives served from a local HTTP server.

## Run everything

```bash
scripts/test/run_tests.sh
```

This generates fixtures (first run only), checks guard sync, then runs the shell and
Swift suites. Exit code is non-zero if anything fails.

Requirements: `bash`, `curl`, `bsdtar` (libarchive), `python3`, and the Swift toolchain
(`swift`). All present on the macOS CI image.

## What is covered

| Scenario | Shell (`download_binary`) | Swift plugin (extract paths) |
| --- | --- | --- |
| Legit binary downloads, extracts, **runs**, `0775` | ✅ | ✅ |
| Decompression bomb (400 MB) → abort + cleanup | ✅ | ✅ (remote + local) |
| Entry-count bomb (20k files) | n/a — `-O` streams, nothing per-entry on disk | ✅ flagged on entry cap |
| Multi-file archive (pre-existing behavior unchanged) | ✅ | ✅ |
| Oversized download (>100 MB) rejected before extraction | ✅ | ✅ (`curl --max-filesize`) |
| Corrupt archive → clean failure, no false bomb-positive | ✅ | ✅ |
| Missing URL / network failure → abort, no hang | ✅ | — |

All fixtures are **bounded** (nothing decompresses beyond ~400 MB) so a regressed guard
can never exhaust the disk during a test run; bomb tests additionally use a small byte cap.

## Why a "mirror" for the Swift side

SwiftPM **command plugins cannot be imported by a test target** (they run sandboxed and
compile only their own sources), so the plugin's guard logic cannot be unit-tested
directly. Instead:

- The guard lives in a clearly-marked block in
  `Plugins/BrowserStackAccessibilityLint/BrowserStackAccessibilityLint.swift`
  (`=== DEVA11Y-484 EXTRACTION GUARD ===`).
- `swift-harness/Sources/ExtractionHarness/Guard.swift` is a **verbatim mirror** of that
  block, compiled into a small executable that drives real `curl`/`bsdtar`.
- `check_drift.sh` diffs the two and **fails if they diverge**, so the mirror can never
  silently rot. If you edit the guard, copy the block into both — the drift check enforces it.

## Files

| File | Purpose |
| --- | --- |
| `run_tests.sh` | Orchestrator — run this |
| `make_fixtures.sh` | Generates the bounded test archives into `fixtures/` (gitignored) |
| `check_drift.sh` | Fails if the plugin guard and harness mirror diverge |
| `test_shell_extraction.sh` | Runs the real `download_binary` from all 3 wrappers |
| `test_swift_extraction.sh` | Runs the Swift guard via the mirror harness |
| `lib/assert.sh` | Assertion helpers + local server management |
| `_shim/curl` | Test-only curl shim; redirects the hardcoded URL to the local server |
| `swift-harness/` | Standalone SwiftPM executable mirroring the guard |
