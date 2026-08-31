# DEVA11Y-484 extraction-guard regression suite

Regression tests for the decompression-bomb guard on the CLI download path.

```bash
bash tests/extraction-guard/run_tests.sh
```

First run generates ~106 MB of fixtures into `fixtures/` (gitignored). Requires
`bsdtar`, `curl`, `python3`, `awk` — all present on GitHub's `macos-latest`.

## What it covers

The **shell launchers**: the real `download_binary()` from
`scripts/{bash,zsh,fish}/cli.sh`, 17 assertions per variant, 51 total.

| Case | Asserts |
|---|---|
| legit archive | exits 0, binary present, mode matches `cli.sh`, extracted binary runs |
| 400 MB bomb | rejected **by the decompressed-size cap specifically**, partial file cleaned up |
| 110 MB download | rejected at the download stage, no binary written |
| corrupt archive | rejected, and *not* misreported as a size rejection |
| missing URL | rejected, no hang |
| 20,000-entry archive | succeeds — `-O` streams to one file, so nothing lands per-entry |
| multi-file archive | succeeds (pre-existing `-O` concatenation) |
| bomb after a good download | rejected, and the already-cached good binary survives |

## How it avoids testing the wrong thing

**Functions are extracted verbatim.** `load_download_binary` lifts
`_self_update_sha256`, `strip_quarantine`, `verify_binary_integrity` and
`download_binary` straight out of `cli.sh` and sources them. Loading only
`download_binary` leaves the others undefined, the function dies with exit 127,
and *every abort assertion passes for the wrong reason* — so all four are loaded.
Faithfulness greps then assert the extracted code still contains the guarded
`bsdtar … | head -c` pipeline and both cap constants; if `cli.sh` is refactored
past those, the suite fails loudly instead of quietly testing nothing.

**Only curl's CLI boundary is shimmed.** `_shim/curl` rewrites the hardcoded
`api.browserstack.com` URL to a local `python3 -m http.server` and passes every
other argument through, so `--max-filesize`, `-L`, `-z` and the
`bsdtar | head -c` pipeline all execute for real. No network, no credentials.

**Exit status alone is not trusted.** A bomb trips both the size check *and*
`extract_status` (bsdtar takes SIGPIPE when `head -c` closes the pipe), so
asserting "exit 1" still passes with the size cap deleted — confirmed by mutation
test. The suite asserts on the *message*, which differs per path.

**The expected file mode is read from `cli.sh`**, not hardcoded: main tightened it
from `0775` to `0755` and a hardcoded expectation had already rotted.

## Mutation-validated

Baseline green; each guard removal below flips it red:

| Mutation | Result |
|---|---|
| disable the decompressed-size rejection | caught |
| raise the decompressed cap to 4 GB | caught |
| drop the `head -c` truncation | caught |
| remove **both** compressed-cap layers | caught |
| remove `--max-filesize` only | **stays green, by design** |

That last row is not a gap. The compressed cap has two layers, and removing the
flag leaves the explicit `compressed_size > max_compressed` backstop, which still
rejects — measured: the full 105 MB downloads, then the backstop fires. Removing
both layers is caught.

## Not covered

The **Swift** half — `extractLocalArchive`, the extraction watchdog, and the
stderr excerpt bounding — has no automated coverage here. It is `private` on a
`private struct` in a plugin-only package with no library target, so no test can
import it. Making it testable requires the library extraction tracked in
**DEVA11Y-761**; the `refactor/DEVA11Y-484-testable-extraction` branch carries a
working prototype of that split plus Swift unit tests.

## Location

Under `tests/` rather than `scripts/` deliberately: the
`verify-selfupdate-checksums` workflow globs `scripts/**/*.sh` and requires a
committed `.sha256` sidecar for every match. Test scripts are not self-updated
and must not enter that glob.
