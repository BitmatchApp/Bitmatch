# Sony Venice issue #8 investigation

2026-10-05, based on main e0753b08 (0.2.4).

The reporter originally used 0.1.4 and reported “1 only in destination.” Their October 2 comment says both Copy & Verify and comparison failed, but does not identify the retested version or the exact Copy & Verify error. The card was readable without extra Sony software. Viewer access was granted after the request and follow-up. The archive contains 18 XML and 15 BIM files (107,664,847 bytes), no MOV footage. All XML files parse successfully; model metadata identifies VENICE (MPC-3610). Original files remain private and outside the committed repository.

## Synthetic reproduction

`SonyVeniceIssue8Tests` uses all 58 reported paths: 49 files (15 MOV, 15 BIM, 18 XML and .DS_Store) and nine directories, including empty directories. Contents are deliberately synthetic; these are not valid camera media or original Sony metadata.

The matrix covers Quick, Standard, Thorough and Paranoid with local internal-storage, mounted exFAT and mounted HFS+ sources, copying into internal storage. It checks two transfers, unchanged source file names/bytes, identical destination bytes, empty folders and folder comparison. macOS-generated AppleDouble files on exFAT are included in the baseline, rather than assumed absent. Quick refuses the second transfer by design: it cannot prove an existing file matches and must not overwrite it.

Comparison cases cover a clean copy, extra destination-only Finder .DS_Store/AppleDouble metadata, a real extra BIM file, and same-size corruption of a MOV. Real extras remain differences; Standard/Thorough/Paranoid detect corruption. Quick checks sizes only.

The first harness mistakenly checked the selected backup root rather than its card subfolder, assumed 49 total files even when macOS created exFAT companions, and assumed Quick could reuse existing files. These were harness errors and were corrected before relying on the matrix. An intermediate enum spelling error also prevented compilation; it is not a product finding.

## Interpretation

The 12-case matrix passes on current code. Removing only destination-only Finder metadata filtering makes the tests fail, then restoring it passes. This confirms the tests exercise that protection. The 0.1.4 ComparisonCoordinator used an unfiltered destination-minus-source set, consistent with the original extra-Finder-file report. This does not establish the cause of the later Copy & Verify failure.

No production behavior changed during this investigation. No release is warranted from these synthetic results alone. Await the retested version and exact error; original metadata is now available and checked. These tests do not exercise a real Sony AXSM/SxS reader, UDF media, permission failures, large actual MOV containers or the signed-app picker/UI.

Validation logs and access-request receipt are retained locally under `dist/validation/issue8/`. Run the focused matrix with:

```sh
BITMATCH_ISSUE8_MOUNTED=1 arch -arm64 swift test --package-path Packages/BitMatchEngine --build-system native --filter SonyVeniceIssue8Tests
```

Mounted-image cases are opt-in to avoid blocking setup on the cooperative executor during the normal parallel suite. The final focused matrix (two parameterized tests, 12 cases) passed in 6.811 seconds. An earlier full run passed all 110 XCTest cases (15 opt-in skips) and the Sony matrix but missed timing deadlines in `cancellationMidBroadcastPublishesNothingAndReportsNoSuccess` and `testStalePauseDoesNotBlockNextOperation`; those are recorded separately from the Sony outcomes. The final full-suite rerun is recorded below.

Final full engine rerun: 110 XCTest cases, 15 skipped, zero failures (64.068 seconds); 129 Swift Testing tests in 29 suites, zero failures (8.181 seconds), including the four local Sony cases. Mounted Sony cases were disabled here and passed separately in the explicit 12-case run. No Mac app/UI or physical-reader validation was performed in this batch, which changes tests and documentation only.

## Original metadata follow-up

The opt-in `BITMATCH_ISSUE8_METADATA` path points to a local private card folder. Tests read the supplied XML/BIM bytes into disposable fixtures; they never edit the original folder or embed it in the repository. Cases cover metadata alone and metadata with 15 synthetic MOV placeholders. All four modes run against internal storage; Standard additionally runs from mounted exFAT and HFS+ sources. They repeat the transfer, check every original source byte remains unchanged, compare folders, ignore destination-only Finder metadata, detect real extra files and detect same-size corruption (BIM when no MOV placeholders are present). Quick remains size-only and refuses repeat copies.

The first metadata run passed all eight metadata cases and four existing local synthetic cases in 11.502 seconds. The expanded mounted-metadata run is recorded below. There is no evidence here that Sony metadata causes the reported copy/comparison failure. No actual footage bytes, signed-app UI or physical AXSM/SxS/UDF reader are exercised.

```sh
BITMATCH_ISSUE8_METADATA=/private/local/card-folder arch -arm64 swift test --package-path Packages/BitMatchEngine --build-system native --filter SonyVeniceIssue8Tests
```

Expanded original-metadata run: 12 metadata cases (eight mode/content combinations on internal storage, four Standard/content/filesystem combinations from exFAT and HFS+) plus four synthetic internal-storage controls passed in 22.588 seconds, zero failures. Independent SHA-256 checks confirmed all 33 original downloaded files remained unchanged. The earlier full engine suite passed; this follow-up changes only opt-in tests and notes, and does not claim a new full app/UI validation.


## Signed-app and diagnostic follow-up

The official signed/notarized 0.2.4 build passed a picker-driven Standard copy of all 33 supplied metadata files to internal storage, followed by ASC MHL and PDF/CSV/JSON reports. Check reported 33 matching files. Independent SHA-256 checks matched all source/destination files. The bundle contains no original MOV footage, so this does not reproduce the reporter's complete card or physical reader.

The follow-up adds comparison phase, count and terminal events correlated to the app run ID. These contain closed enums, counts and error classifications, never file names, footage paths or raw error messages. Failures and cancellation propagate. Differences lists now say missing/extra in the comparison folder, explain that an extra file alone does not imply damaged copies, and distinguish the path-bearing differences export from diagnostics.

A disposable mounted exFAT regression reproduced different valid AppleDouble companion files generated by different quarantine attributes. Standard verified the identical media but refused the differing existing companion. Both companions and the source media were preserved, and the overall completion verdict remained unsafe. The change explains this refusal; it does not delete companions, overwrite them or exempt them from copy verification. This is a confirmed local conflict, not an established cause of issue #8.

The walkthrough also found Eject offered for a completed internal-folder transfer, producing an OS error. Mac queue actions now require an ejectable volume, and the eject service returns a readable refusal for internal storage.

Local validation of the production follow-up:

- Full engine: 114 XCTest cases, 15 opt-in skips, zero failures (57.842s); 131 Swift Testing tests in 29 suites, zero failures (5.154s).
- Final focused comparison/exFAT run after adding the explicit unsafe verdict assertion: eight XCTest cases, zero failures (30.190s).
- Final Mac app and iOS Simulator builds: BUILD SUCCEEDED.
- Seeded mobile workflow/history snapshot tests: two tests passed; final workflow capture includes comparison at iPhone and iPad widths. Images were inspected for layout; this is not a physical-device picker test.
- Updated Mac app opened normally and displayed the intentional extra file under the new Extra list, with all 33 original files matching. Temporary selections and the test queue row were cleared; unrelated queue entries were preserved.
- Mac focused app test attempts (unsigned, then ad-hoc signed) stalled before tests started. Process samples show the host in dyld dependency loading. Only the owned stalled test processes were stopped. These are not passing tests, and no full Mac app-suite pass is claimed.
- git diff --check passed. Local logs and captures remain under dist/validation/followups, outside version control. No reporter metadata is included in commits.

No new release is justified solely by this metadata-only reproduction. Keep issue #8 open pending the reporter's tested version and exact Copy & Verify error.


## Release review, 5 October 2026

The follow-up Mac test-host stall was resolved by moving derived data outside Desktop. LLDB observed dyld opening the built Sparkle framework under the Desktop checkout; the external build folder allowed the tests to run without signing, sandbox or privacy changes. This is an observed workaround, not a proven explanation of the OS loader behavior.

Review found that Check cancellation logged no run ID because `activeStartID` belongs to copy operations. Cancellation now falls back to the current operation ID before clearing state. The comparison cancellation test failed with the old logging and passed with the fix. The bulk-eject test now explicitly models removable cards rather than treating internal temporary folders as removable. A separate test rejects internal folders, including bulk ejection. Removing the ejectability guard caused that test to fail by assertion.

Local release gates:

- Full Mac app suite: 1,063 passed, eight skipped, zero failed (xcresult summary; 1,071 tests).
- Optimized Release engine: 114 XCTest cases, 15 opt-in skips, zero failures; 131 Swift Testing tests across 29 suites, zero failures.
- Final Mac and iOS Simulator Release builds passed.
- Real-filesystem executor matrix: HFS+ source to exFAT and case-sensitive APFS, Standard, two destinations, initial transfer and verified-existing-file reuse. Both transfers passed with 52 result rows each, MHL and reports. This is one selected combination, not a rerun of the entire broad matrix.
- A Developer ID signed review archive was built through `Scripts/release_mac.sh` with notarization explicitly skipped. Its bundle version remains 0.2.4; it is a local review artifact, not a published update.
- Picker-driven signed-app Standard transfer: 33 original metadata files plus a 1 GiB synthetic file, HFS+ to exFAT and APFS. All 68 destination results verified; independent SHA-256 matched all 34 source files at both destinations. Both ASC MHL inventories contained all 34 files, and the JSON report recorded 68 rows and a safe verdict. PDF, CSV and JSON reports were generated. Success persisted after relaunch.
- A signed-app retry of 2,000 small files was cancelled through the menu. The dialog was opened while verification was visible, but the exported log proves confirmation reached the executor during reporting. The log recorded menu origin and explicit journal cancellation; history showed Interrupted / not safe to erase. No successful journal finish was recorded. All 2,000 source files and all 4,005 pre-existing destination files (including AppleDouble and MHL history) remained byte-identical. This walkthrough is reporting cancellation coverage, not mid-verification cancellation coverage.
- The retry's existing MHL history was refused rather than overwritten. This is expected safety behavior and is distinct from the clean initial MHL publication.

Logs, xcresult summary and private diagnostic exports remain local under `dist/validation/release-review/`. No original MOV footage or physical Sony reader was tested, and issue #8's later Copy & Verify failure remains unproven. The maintenance changes can be evaluated for release on their own evidence; do not describe the reporter's issue as resolved.

### Check picker crash found during final walkthrough

Selecting a copied card containing a multi-file MHL repeatedly terminated the signed review app. LLDB on the local Debug build identified a Swift fatal duplicate-key trap in `SavedChecksumCheck.makeDiscovery`: every file points to the same record URL, but the record list used `Dictionary(uniqueKeysWithValues:)`. This also affected multi-file JSON reports. Existing tests used one file per record and missed it.

The fix collects contributing records by URL after resolving the newest evidence per file. It preserves every file entry, report precedence and corruption detection. A parameterized two-file MHL/JSON regression reproduced both fatal traps before the fix; it verifies both files, changes one file, then requires the mismatch while preserving the record bytes. This is a confirmed Check bug, not evidence of the cause of issue #8's transfer failure.

Final verification after the picker-crash fix:

- The first parallel Release engine rerun passed all 114 XCTest cases (15 skips) and the new multi-file regression, but three pre-existing concurrency tests missed their start/completion deadlines while builds were running: `cancellationMidBroadcastPublishesNothingAndReportsNoSuccess`, `testStalePauseDoesNotBlockNextOperation`, and `failedRunWaitsForInFlightVerifiers`. The Swift Testing runner subsequently stalled; its process sample was saved and only that owned run was stopped. This run is not counted as a pass.
- With the builds finished, `swift test -c release --skip-build --no-parallel` passed: 114 XCTest cases, 15 skips, zero failures (68.075s); 132 Swift Testing tests in 29 suites, zero failures (32.090s). No test deadlines or assertions were weakened.
- Full Mac suite rerun: 1,063 passed, eight skipped, zero failures. Final Mac and iOS Simulator Release builds passed. The signed review archive was rebuilt with the final code.
- The rebuilt signed app selected the same exFAT backup without crashing and re-read its MHL: 34 files intact, one contributing MHL record. Folder comparison also completed with all 34 original files matching; 48 generated MHL/filesystem entries present only on the selected backup were reported separately. Its seven comparison diagnostic events share one run ID, end in completed with zero mismatches, and contain no private fixture names or paths.
- Independent hashes again confirmed all 34 source files unchanged. All three disposable images were detached without force and removed. Task-owned build caches were removed; signed review artifacts, reports, diagnostics, logs and xcresults were retained locally. Unrelated queue entries were preserved.

These results support a maintenance release for the confirmed fixes, while keeping issue #8 open for the reporter's confirmation.
