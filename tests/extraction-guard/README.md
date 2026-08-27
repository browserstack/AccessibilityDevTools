# DEVA11Y-484 — decompression-bomb guard regression tests

Real, local integration tests for the size/entry guards added to the CLI download path.
**No mocks** — every test runs actual `curl`, `bsdtar`, `head`, and (for the plugin) real
`Process`/watchdog logic against crafted archives served from a local HTTP server.

## Run everything

```bash
tests/extraction-guard/run_tests.sh
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

## Known limitations (read before trusting this blindly)

- **The cap is soft, not exact.** The Swift watchdog polls the extraction directory
  (every 50 ms) and kills `bsdtar` once the footprint crosses the limit, so peak disk use
  is roughly `cap + (poll interval × disk write rate)`. Measured: a 200 MB cap peaks around
  ~230–300 MB on a fast NVMe; a 2 GB bomb is killed at ~224 MB (see `test_large_bomb.sh`).
  The goal is preventing disk *exhaustion* by a multi-GB/TB bomb — not enforcing an exact
  byte count. The shell `-O | head -c` path, by contrast, is a hard byte cap.
- **The Swift tests run a mirror, not the compiled plugin.** `check_drift.sh` guarantees the
  guard *block* matches, but the harness has its own copies of the `extractRemote/extractLocal`
  call sites, which are NOT drift-checked. A bug in how the plugin wires the guard into those
  call sites would not be caught here (the plugin edits are typecheck-only). Eliminating this
  needs the larger refactor of extracting the logic into an importable target.
- **`locateExecutable`'s 10k-entry cap is not exercised by the harness** — the watchdog's
  entry ceiling (which IS tested) is the primary defense; the `locateExecutable` cap is
  secondary/defense-in-depth and currently typecheck-only.
- **Windows protection is post-hoc only.** The macOS/Linux `bsdtar` paths bound peak disk
  mid-stream via the watchdog. The Windows `Expand-Archive` path has no streaming guard; it
  gets only the platform-agnostic post-extraction backstop (it rejects + cleans up a bomb
  before the binary is used, but the bomb can momentarily expand to its full size on disk
  first). Windows also can't run on the macOS CI image, so it is verified by typecheck only.
  A streaming guard for Windows is a follow-up.

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
