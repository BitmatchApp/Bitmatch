# Classic MHL single-algorithm fixtures — October 21, 2026

TODO slice 4 adds independently generated coverage for the remaining
supported classic-MHL record shapes: single-digest MD5-only and SHA-1-only
inventories. The same separately authored `mhl-suite` 1.4.0 writer behind the
existing padded-path fixture produced all four variants at the same pinned
upstream revision `9304aef7139403e8188d48ac2c653594ad589745`
(`https://github.com/lucuma13/mhl-suite`), with the same retained MIT notice.
Two further variants from the same writer — size-only (`<null>`) and xxh64
(`<xxhash64be>`) records — pin the exact unsupported shapes the BitMatch
reader must fail closed on.

Each variant directory under
`Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/EvidenceCompatibility/classic-single-algorithm/`
holds byte-identical original synthetic media (a spaced filename, a nested
`Reel A/` directory and a non-ASCII `café` filename) beside its own
writer-generated manifest. Only creator username, hostname and environment
log were replaced with synthetic values; paths, sizes, dates and digest
claims are unchanged. The raw pre-sanitization manifest hashes, committed
sanitized manifest hashes, media digests, commands, dependency pins and
limitations are recorded in the [fixture README](../../Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/EvidenceCompatibility/classic-single-algorithm/README.md).

## Independent checks

The pinned upstream checkout matched the recorded revision with no local
edits, and its `pyproject.toml`/`uv.lock` hashes matched the fixture README
pins. The generation venv used Python 3.12.15 with the exact locked runtime
closure (lxml 6.1.1, xxhash 3.8.1, packaging 26.2, pathspec 1.1.1,
pyuca 1.2, rich 15.0.0, click 8.4.2) after an explicit hatchling install;
the package installed was `mhl-suite` 1.4.0 from the pinned source.

All four sanitized manifests passed the upstream tool beside copies of
their payloads: `simple-mhl verify` (with `-a md5`, `-a sha1`, `-S` and
`-a xxh64` respectively) and `simple-mhl xsd-schema-check` each exited 0.
All four also validate against the primary classic MHL 1.1 XSD (SHA-256
`c1adcd2591069249c88f2fc1fabac81363e7572b952834cce66f72a264e4c703`)
with the W3C signature schema resolved locally. Disposable-copy negatives
with the upstream verifier: same-size content corruption exits 11
(`hash mismatch`) and missing media exits 10 (`missing file`), observed on
both supported variants. The upstream verifier accepts the size-only and
xxh64 manifests, while the BitMatch reader explicitly rejects those record
shapes; that disagreement is the intended fail-closed boundary, not a defect
in either tool. Every recorded MD5, SHA-1 and XXH64 digest was independently
recomputed from the committed media bytes (hashlib plus the `xxhash`
package); all matched. The writer refuses to seal empty files
(`cannot seal empty file`), so empty-file coverage stays synthetic-only,
and it emits UTF-8 without a byte-order mark, so BOM handling is likewise
not covered by writer output.

The offline validator
`Scripts/ascmhl/validate_independent_classic_single_algorithm.py` pins the
exact variant file set, license hash, manifest hashes and media digests,
recomputes every MD5/SHA-1/XXH64 claim, enforces strict UTF-8 with no DTD,
exact per-variant record shapes, safe paths and full coverage, and verifies
the fixture is byte-identical afterward. Its companion
`Scripts/test_independent_classic_single_algorithm.py` passed **9 tests**:
pinned validation without modification, changed-media/extra-file/manifest/license
tamper rejection, synthetic single-digest round-trips, unsupported-shape
separation, DTD/encoding/unsafe-path controls, an explicit missing-xxhash
failure, and schema-pin gating with an offline resolver. The pre-existing
padded-fixture suite (12 tests) and its validator still pass unchanged.

## BitMatch reader tests

`ClassicMHLCompatibilityTests` gains four writer-backed cases:

- `singleAlgorithmWriterInventoryChecksSupportedDigest` (md5-only, sha1-only):
  discovery yields one classic record with three expected files, each
  requiring exactly its single recorded digest; the intact check matches all
  three paths, including the nested and non-ASCII names, without touching
  media bytes.
- `singleAlgorithmWriterMediaChangesPreventAnIntactResult` (2 variants ×
  corrupt/missing): changed or missing media prevents an intact result with
  the exact changed/missing path.
- `independentWriterUnsupportedShapesFailClosed` (size-only, xxh64):
  discovery throws `unsupportedEvidence` and leaves media bytes unchanged.
- `complementaryWriterManifestsMergeWithoutOverstatingScope`: the MD5-only
  and SHA-1 manifests beside identical media merge into a two-digest
  requirement per file and check intact, proving consistent records combine
  rather than shadowing each other.

The focused `ClassicMHLCompatibilityTests` run passed **7 tests in 1 suite**
(the 3 pre-existing cases plus the 4 new ones, 9 invocations total), zero
failures, in 0.331 seconds (`--no-parallel --disable-xctest`, native arm64).
The neighboring `ClassicMHLCheckTests` suite passed **26 tests**, zero
failures. The full engine Swift Testing run passed **271 tests in 41
suites**, zero failures. These focused/full counts are actual Swift Testing
executions; XCTest was disabled in the focused runs, so these numbers are
not empty XCTest successes.

## Scope and limits

This slice covers single-digest MD5/SHA-1 content evidence plus explicit
unsupported-shape boundaries from one more independent writer output. It
does not authenticate the manifest, establish custody, prove copy history,
validate timestamps against files, extend histories, or certify any
third-party reader. Empty-file and BOM handling remain synthetic-reader-only.
No production code changed: the reader's supported/unsupported boundary is
unchanged, and every new test asserts the existing fail-closed behavior.
Unsupported or contradictory evidence still fails closed. Full engine and
app gates are not claimed by this slice; only the focused suites listed
above were run.
