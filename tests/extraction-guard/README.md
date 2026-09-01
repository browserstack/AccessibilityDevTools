# DEVA11Y-484 extraction-guard regression suite

Regression tests for the decompression-bomb guard on the CLI download path.

```bash
bash tests/extraction-guard/run_tests.sh
```

First run generates ~106 MB of fixtures into `fixtures/` (gitignored). Requires
`bsdtar`, `curl`, `python3`, `awk` — all present on GitHub's `macos-latest`.

## What it covers

The **shell launchers**: the real `download_binary()` from
`scripts/{bash,zsh,fish}/cli.sh`, 20 assertions per variant, 60 total.

| Case | Asserts |
|---|---|
| legit `.tar.gz` | exits 0, binary present, mode matches that variant's `cli.sh`, extracted binary runs |
| legit `.zip` | same — this is the format production actually serves |
| 400 MB bomb | rejected **by the decompressed-size cap specifically**, partial file cleaned up |
| 110 MB download | rejected *before extraction*, no binary written |
| corrupt archive | rejected, and *not* misreported as a size rejection |
| missing URL | rejected, no hang |
| 20,000-entry archive | succeeds — `-O` streams to one file, so nothing lands per-entry |
| multi-file archive | succeeds (pre-existing `-O` concatenation) |
| bomb after a good download | rejected, and the already-cached good binary survives |

Note on the 110 MB row: it asserts "rejected before extraction", **not** "the
`--max-filesize` flag is present". Those are different claims — see the mutation
table below.

Note on the 20,000-entry row: it asserts no per-entry disk amplification, **not**
that entry counts are capped. The shell path has no entry-count ceiling at all,
unlike the Swift path's `maxArchiveEntries = 10_000`; and because `-O` concatenates,
that archive publishes a 0-byte `browserstack-cli`. Pre-existing and outside this
ticket's remediation, but a real gap rather than covered behaviour.

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

**The local server must be ours.** The port is derived from the PID, so an
unrelated local service can already hold it. A bare "does anything answer?" probe
would then succeed against *that* server, every fixture request would 404, and the
run would fail with a dozen confusing per-case errors instead of "port busy".
`start_server` therefore serves a random token and requires the responding server to
return it, trying other ports otherwise.

**The expected mode is read per variant.** The three `cli.sh` files are
byte-identical in that region today, but reading bash's value for all three would
check a zsh- or fish-only change against the wrong source.

**Exit status alone is not trusted.** A bomb trips both the size check *and*
`extract_status` (bsdtar takes SIGPIPE when `head -c` closes the pipe), so
asserting "exit 1" still passes with the size cap deleted — confirmed by mutation
test. The suite asserts on the *message*, which differs per path.

**The expected file mode is read from `cli.sh`**, not hardcoded: main tightened it
from `0775` to `0755` and a hardcoded expectation had already rotted.

**Fixture generation is locked and marker-gated.** Generation is not atomic, and
the first version gated on "does `legit.tar.gz` exist?" — which `make_fixtures.sh`
creates *first*. A second run starting behind a generating one therefore saw the
gate satisfied and read `bomb`/`manyfiles`/`multifile` while they were still being
written, failing 5 of 51 assertions. This was not theoretical: a reviewer running
the suite alongside another run hit it (1 run in 7). Generation now takes an
atomic `mkdir` lock and writes a `.complete` marker last; `run_tests.sh` gates on
that marker. Validated with 4 concurrent cold starts, a staggered cold start, and
6 warm serial runs — all green.

## Mutation-validated

Baseline green; each guard removal below flips it red:

| Mutation | Caught by |
|---|---|
| disable the decompressed-size rejection | behavioural assertion |
| raise the decompressed cap to 4 GB | faithfulness grep |
| drop the `head -c` truncation | faithfulness grep |
| remove **both** compressed-cap layers | behavioural assertion |
| remove `--max-filesize` only | faithfulness grep |

That last row is the subtle one, and it is why the greps exist. The compressed cap
has **two** layers: `--max-filesize` aborts the transfer pre-emptively, and an
explicit `compressed_size > max_compressed` check backstops responses with no
declared length. Removing the flag alone leaves the backstop, which still rejects —
measured: the full 105 MB downloads, then the backstop fires and emits the same
"maximum allowed download size" message. So **no behavioural assertion can detect
that mutation**; every one stays green. Only the grep catches it, and it matters,
because without the flag a chunked or undeclared-length response can write unbounded
bytes to disk before any check runs.

An earlier revision of this suite asserted the opposite in a code comment ("with the
cap removed the failure moves to bsdtar"), which was false and contradicted this
table. Fixed.

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
