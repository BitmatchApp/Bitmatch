# Synthetic transfer matrix

The matrix uses disposable mounted APFS, journaled HFS+, exFAT, case-sensitive APFS and FAT32 images. Sources and backups use separate images. It checks source hashes before/after transfers, destination hashes, terminal verdicts, report exports and ASC MHL handoff. Disk images exercise the real filesystem drivers; all images still share one host disk. They cannot prove physical backup independence or reproduce a USB controller failure.

## Run

```sh
bash Scripts/test-transfer-regression-matrix.sh
BITMATCH_EXTENDED_MATRIX=1 bash Scripts/test-transfer-regression-matrix.sh
bash Scripts/test-filesystem-fault-matrix.sh
bash Scripts/test-full-transfer-matrix.sh
MATRIX_FOCUS=features bash Scripts/test-full-transfer-matrix.sh
MATRIX_FOCUS=rename bash Scripts/test-full-transfer-matrix.sh
MATRIX_FOCUS=limits bash Scripts/test-full-transfer-matrix.sh
MATRIX_FOCUS=collision bash Scripts/test-full-transfer-matrix.sh
MATRIX_KEY=exfat-exfat-Standard-1-3 bash Scripts/test-full-transfer-matrix.sh
```

Runs need macOS, Xcode and space for disposable sparse images. Run jobs sequentially when sharing DerivedData. `MATRIX_DERIVED_DATA` selects a separate directory. Tests check filesystem types, distinct mounted devices and ownership markers before mutation. Scripts detach owned images without force and remove them only after successful detach. Busy images are retained with an explicit path.

## Coverage

| Suite | Coverage |
| --- | --- |
| Full executor | 5 source × 5 backup filesystems × 4 verification modes × 1/2 backups × 4 MHL/report options; 800 combinations, each initial + repeat (1,600 operations) |
| Project ingest / reports | 270 combinations: five backup filesystems, three workflows, three labels, three verified modes, one/two backups; real draft preparation and ingest lifecycle, saved job roundtrip, MHL, PDF/CSV/JSON and Master Report |
| Folder naming | 320 combinations: five filesystems, prefix/suffix, four separators, grouping on/off, Unicode/traversal-like labels, Quick/Standard; original media filenames unchanged |
| Mounted faults / payloads | 55 XCTest methods, 270 scenarios across five filesystems |
| Filename collisions | 20 cases, five backup filesystems and four modes; conservative rejection of ambiguous source names |
| FAT32 file limit | Real sparse 4 GiB + 1 byte source to FAT32 and APFS simultaneously; FAT32 returns EFBIG, APFS independently verifies, overall verdict stays unsafe, failed backup has no complete MHL |
| Seeded soak | 200 iterations, seed 20261002, nine files and two backups; 3,600 independently hash-checked outputs |

Fixtures include empty files/directories, tiny files, 64 MiB files, 1,000-file cards, 24-level nesting, Unicode, spaces, hidden metadata and real AppleDouble files. Faults include destination removal/replacement, conflicting files, incomplete histories, truncated media, write/flush/close/publication errors, readback errors, cancellation before start and cancellation thrown during copy/verification. Error hooks inject faults; disks are not physically unplugged or filled to simulate ENOSPC.

## Confirmed defects and fixes

- Verifier `CancellationError` now propagates in both sequential and pipelined paths instead of being swallowed or recorded as an ordinary file error. This was reproduced before the fix.
- Mounted runs exposed AppleDouble sidecar publication races. Media now finishes publication before its AppleDouble companions. No manifest entry is dropped. A deterministic ordering regression failed before the fix and passed afterward.
- When a destination file appears during publication, verified modes may reuse it only after the existing pinned, uncached matching checks prove it matches. Conflicts remain failures and existing files are never overwritten. Deterministic publication-race regressions establish this behavior.
- Reports previously counted result rows across backups as source files/bytes. They now count unique source paths; result statistics still count individual copies. Master Report no longer doubles card totals for two backups.
- Saved JSON previously lost the overall transfer safety verdict. A transfer requiring attention could consequently become “Verified” in Master Report despite its terminal verdict. New version 3.1 reports preserve `safeToErase`. Declared result totals must also agree with matched counts.
- New reports requesting a PDF include its filename and SHA-256. Master Report checks this final publication marker through pinned, uncached reads before accepting a verified verdict. Missing or damaged PDFs remain unverified. PDF checks are streamed and capped at 256 MiB. JSON-only reports need no PDF; legacy reports remain readable but cannot recover verdict information they never stored.

The initial expanded transfer run failed on metadata publication; the corrected 800-case run passed. Its 200 Quick combinations remain unverified by design. 48 initial Quick cases deliberately refuse metadata files they cannot prove match; repeat Quick transfers refuse existing files too. These are expected safety outcomes, not verified transfers. All 600 verified-mode combinations passed.

Local red/green logs and final gate results are retained under `dist/validation/transfer-matrix-20261002`. XCTest exit status is authoritative; a count of completed combinations alone is not evidence of success.

## App and engine gates

Full Mac tests and the iPad simulator build passed. The engine bundle passed 109 XCTest tests (15 opt-in skips, zero failures) and 123 Swift Testing tests. On this Xcode installation, the standalone `swift test` launcher could not load its XCTest bundle, including after a clean native build. Running that same bundle directly with `xcrun xctest` passed both suites. The launcher error is not counted as a passing test run. The independent invocation was:

```sh
swift test --package-path Packages/BitMatchEngine --build-system native --scratch-path .derived-data/engine-native
xcrun xctest .derived-data/engine-native/arm64-apple-macosx/debug/BitMatchEnginePackageTests.xctest
```

The first command builds the bundle but reports the launcher failure on this machine; the second must independently complete successfully.

## Limits

These findings are real local defects, not proof of the issue #10 reporter's exact cause. Uncovered conditions include physical dock/cable disconnection, real power loss, SMB/NAS/cloud providers, actual out-of-space disks, extended thermal/throttling runs and iOS background suspension. PDF tests parse actual generated documents; they do not replace a device UI walkthrough. Project coverage exercises BitMatch's card-ingest workflows, not a new external project-file import feature.
