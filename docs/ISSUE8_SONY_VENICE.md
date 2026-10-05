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
