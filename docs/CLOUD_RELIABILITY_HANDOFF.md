# Cloud reliability handoff — October 14, 2026

Branch: `cloud/reliability-evidence`, based on `f37c918`. Implementation and synthetic reference validation only; not release-ready until Apple checks pass.

## Changes

- Recorded the proposed P2 BitMatch Remote roadmap in TODO: menu bar, authenticated monitoring, setup/Start, operational controls and connectivity investigation. No remote hosting or client code is implemented.
- Added bounded reads for saved JSON/MHL and adjacent checksum text. Check no longer silently ignores unreadable, malformed, oversized or conflicting adjacent records. Missing companions remain optional; identical duplicate lines and GNU-escaped paths remain supported. Reads enforce the limit during loading, not just against earlier metadata; cancellation is checked between chunks and manifest lines.
- Separated remote destination wording from whole-card assurance and guarded photographer report `fullyBackedUpAt` against rejected local evidence. Retained remote evidence remains visible separately.
- Expanded the independent ASC corpus and added a Linux-compatible checker and CI job. All generated media are original synthetic payloads, under the existing fixture license.
- Documented the source/destination/digest audit and corrected README/Guide descriptions. The full verification-wording TODO is still open.

## Executed here

Linux, Python 3.12.14. Reference checkout pinned to `ascmitc/mhl@0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687`.

- `validate_corpus.py`: **68 checks passed**, across MD5 (two generations), XXH64, C4, SHA-1, XXH128 and XXH64 boundary vectors. Includes inventory/chain XSDs, C4 chain digests, original file/path checks and negative controls for altered/missing/renamed/extra media and modified/missing manifests. Permanent corpus remained unchanged.
- The first runner draft expected missing-file exit 10 for a rename. The official CLI emits exit 21 with both new-file and missing-file diagnostics. The expectation was corrected; the successful run requires both diagnostics. That initial runner failure was not a BitMatch test failure.
- Python compilation, shell syntax, Swift syntax parsing of edited files and `git diff --check` passed. Swift syntax parsing is not type checking, compilation or test execution.
- The new CI workflow is authored but has not been run on GitHub from this cloud session.

Local reference output is in ignored `dist/validation/cloud-2026-10-14/asc-corpus.json`. Reproduce with a Python 3.11+ virtual environment, the pinned reference checkout installed into it, then:

```bash
python Scripts/ascmhl/validate_corpus.py /path/to/pinned/ascmitc/mhl
```

No Swift/Xcode toolchain is installed here. No engine tests, Mac app tests, Apple builds, UI captures, physical media tests or memory-footprint measurements are claimed as passes. The 64 MiB byte limit bounds input loading; it is not a 64 MiB total-process-memory guarantee for parsing large evidence.

## MacBook gates

From the checked-out branch, run and retain results:

```bash
bash test.sh engine-test
bash test.sh mac-test
bash test.sh ipad-build
```

Focus failures first on `SavedChecksumCheckTests`, `EvidenceCompatibilityTests`, `PhotographerJobPresentationTests` and `PhotographerReportTests`. New files were added only as package fixture resources or Python tooling; Swift regressions live in existing test files.

Mutation-check the new behavioral regressions: ignore a damaged adjacent manifest, break the XXH64 lane/tail processing, restore the old remote status title, and remove the new local-evidence gate for `fullyBackedUpAt`. Each corresponding test must fail; restore production code after each mutation. These mutations have not run in cloud.

Then run `Scripts/ascmhl/validate_reference.sh /path/to/pinned/ascmitc/mhl /path/to/reference-venv/bin` to check fresh BitMatch-generated output, independent next-generation compatibility and the expanded corpus. The Linux run covers only external fixtures, not fresh engine output.

For shared UI/report changes, run simulator tests at actual installed iPhone/iPad destinations, inspect the changed remote labels and CSV/JSON/PDF report output, and check narrow widths. Exercise the signed Mac SFTP workflow with disposable files in both modes, cancellation/interruption, missing/changed local artifacts and report regeneration. Do not substitute old baseline results for this branch's run. Release builds and signed-app walkthroughs remain required before shipping.

## MacBook validation — October 14, 2026

On macOS 27.0.1 with Xcode 27.0 and Swift 6.4, after reviewing the cloud branch and correcting the two evidence edge cases below:

- `bash test.sh engine-test`: XCTest executed 126 tests with 17 skips and zero failures; Swift Testing passed 159 tests in 32 suites, with the opt-in memory stress cases skipped.
- `bash test.sh mac-test`: 1,101 passed, 13 skipped, zero failed, from the Xcode result bundle.
- `bash test.sh ipad-build`: `BUILD SUCCEEDED` for the generic iOS Simulator target.
- `bash test.sh ipad-test`: 64 passed, 8 skipped, zero failed on an iPad Air 11-inch (M4), iOS 26.5. The same counts passed on an iPhone 17 Pro, iOS 26.5.
- `validate_corpus.py` passed all 68 checks against the pinned ASC reference on this Mac. `validate_reference.sh` also passed fresh BitMatch-generated evidence, schema/byte/path checks, next-generation append, C4 chain checks and corruption rejection. Shell syntax, Python compilation and `git diff --check` passed.

Review found two additional fail-closed gaps and fixed them before the final runs: a damaged second adjacent checksum companion or an empty companion could be ignored behind an intact report, and a mixed remote backup could inherit the first file's readback label while refreshes moved its completion time forward. Focused regressions cover these cases. Isolated mutation checks made the new companion tests fail when their guards were removed; the XXH64 boundary test failed for separate lane and tail mutations; and the remote title/local-evidence tests failed when their protections were removed. The working tree used for these negative checks was discarded without changing this branch.

These are local automated checks. A signed Mac SFTP walkthrough, physical-drive testing, narrow-width visual review and release builds have not been run for this branch. No evidence here establishes #10 or #23 as fixed, and this validation is not a release sign-off.

## Still open

P0 #10 and #23 need actual diagnostic/field evidence. The bounded evidence-read issue is a separately identified path, not a demonstrated cause of either report. No user issue has been closed or externally commented on.

Physical-drive benchmarks, storage-aware scheduling decisions, source retries, sibling repair, owned-output re-copy, per-destination out-of-space continuation and crash diagnostics remain open. So do full cross-surface verification wording, standalone classic MHL, structural/chain verification in BitMatch, existing-history extension, portable settings, drive-discovered History and the Remote implementation. These are not marked complete merely because they can be designed or edited in Linux.
