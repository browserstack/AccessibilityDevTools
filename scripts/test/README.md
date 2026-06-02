# DEVA11Y-484 — decompression-bomb guard regression tests

Real, local tests for the size/entry guards on the CLI download path. **No mocks** — every
test runs actual `bsdtar`/`curl`/`head` against crafted archives.

There are two layers:

1. **Swift unit tests** (`Sources/cli-kit-tests`, run via `swift run cli-kit-tests`) exercise
   the **real shipped library** `BrowserStackCLIKit` — the same code the plugin runs. The
   plugin is a thin shim that invokes the `browserstack-accessibility-runner` executable,
   which calls this library (SwiftPM command plugins can't link a library target, so this is
   how the shipped code stays directly testable — no mirror, no drift check needed).
2. **Shell integration tests** (`test_shell_extraction.sh`) run the real `download_binary`
   from `scripts/{bash,zsh,fish}/cli.sh`.

## Run everything

```bash
scripts/test/run_tests.sh        # unit tests + shell tests
swift run cli-kit-tests          # just the Swift unit tests
```

Requirements: the Swift toolchain (`swift`), `bash`, `curl`, `bsdtar` (libarchive), `python3`.
All present on the macOS CI image and under Command Line Tools (no Xcode/XCTest required —
the unit tests are a plain executable, not an XCTest bundle).

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

The Swift unit tests now drive the **real** library code (`extractLocalArchive`,
`extractRemoteArchive`, `startExtractionWatchdog`, `locateExecutable`, parsing) directly —
there is no mirror and no drift check to maintain. The plugin → runner → library chain is
additionally verified end-to-end from a consumer package (a real download + extract + run).

## Known limitations (read before trusting this blindly)

- **The cap is soft, not exact.** The watchdog polls the extraction directory (every 50 ms)
  and kills `bsdtar` once the footprint crosses the limit, so peak disk use is roughly
  `cap + (poll interval × disk write rate)`. Measured: a 200 MB cap peaks ~230–300 MB on a
  fast NVMe; a 400 MB bomb under a 20 MB cap is killed at ~100 MB; a 2 GB bomb is killed at
  ~224 MB. The goal is preventing disk *exhaustion* by a multi-GB/TB bomb, not enforcing an
  exact byte count. The shell `-O | head -c` path is a hard byte cap.
- **Windows protection is post-hoc only.** The macOS/Linux `bsdtar` paths bound peak disk
  mid-stream via the watchdog. The Windows `Expand-Archive` path has no streaming guard; it
  gets only the platform-agnostic post-extraction backstop (it rejects + cleans up a bomb
  before the binary is used, but the bomb can momentarily expand to full size on disk first).
  Windows can't run on the macOS CI image, so it is verified by typecheck only. A streaming
  guard for Windows is a follow-up.

## Files

| File | Purpose |
| --- | --- |
| `../../Sources/cli-kit-tests/main.swift` | Swift unit tests against the real `BrowserStackCLIKit` |
| `run_tests.sh` | Orchestrator — runs the unit tests + the shell tests |
| `make_fixtures.sh` | Generates the bounded shell-test archives into `fixtures/` (gitignored) |
| `test_shell_extraction.sh` | Runs the real `download_binary` from all 3 wrappers |
| `lib/assert.sh` | Assertion helpers + local server management |
| `_shim/curl` | Test-only curl shim; redirects the hardcoded URL to the local server |
