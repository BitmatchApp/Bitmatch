# Sony Venice issue #8 investigation

2026-10-05, based on main e0753b08 (0.2.4).

The reporter originally used 0.1.4 and reported “1 only in destination.” Their October 2 comment says both Copy & Verify and comparison failed, but does not identify the retested version or the exact Copy & Verify error. The card was readable without extra Sony software. Their private metadata folder needs approval; a Viewer request was sent and a follow-up posted. The actual Sony XML/BIM contents have not been inspected.

## Synthetic reproduction

`SonyVeniceIssue8Tests` uses all 58 reported paths: 49 files (15 MOV, 15 BIM, 18 XML and .DS_Store) and nine directories, including empty directories. Contents are deliberately synthetic; these are not valid camera media or original Sony metadata.

The matrix covers Quick, Standard, Thorough and Paranoid with local internal-storage, mounted exFAT and mounted HFS+ sources, copying into internal storage. It checks two transfers, unchanged source file names/bytes, identical destination bytes, empty folders and folder comparison. macOS-generated AppleDouble files on exFAT are included in the baseline, rather than assumed absent. Quick refuses the second transfer by design: it cannot prove an existing file matches and must not overwrite it.

Comparison cases cover a clean copy, extra destination-only Finder .DS_Store/AppleDouble metadata, a real extra BIM file, and same-size corruption of a MOV. Real extras remain differences; Standard/Thorough/Paranoid detect corruption. Quick checks sizes only.

The first harness mistakenly checked the selected backup root rather than its card subfolder, assumed 49 total files even when macOS created exFAT companions, and assumed Quick could reuse existing files. These were harness errors and were corrected before relying on the matrix. An intermediate enum spelling error also prevented compilation; it is not a product finding.

## Interpretation

The 12-case matrix passes on current code. Removing only destination-only Finder metadata filtering makes the tests fail, then restoring it passes. This confirms the tests exercise that protection. The 0.1.4 ComparisonCoordinator used an unfiltered destination-minus-source set, consistent with the original extra-Finder-file report. This does not establish the cause of the later Copy & Verify failure.

No production behavior changed during this investigation. No release is warranted from these synthetic results alone. Await the original metadata, retested version and exact error. These tests do not exercise a real Sony AXSM/SxS reader, UDF media, permission failures, large actual MOV containers or the signed-app picker/UI.

Validation logs and access-request receipt are retained locally under `dist/validation/issue8/`. Run the focused matrix with:

```sh
BITMATCH_ISSUE8_MOUNTED=1 arch -arm64 swift test --package-path Packages/BitMatchEngine --build-system native --filter SonyVeniceIssue8Tests
```

Mounted-image cases are opt-in to avoid blocking setup on the cooperative executor during the normal parallel suite. The final focused matrix (two parameterized tests, 12 cases) passed in 6.811 seconds. An earlier full run passed all 110 XCTest cases (15 opt-in skips) and the Sony matrix but missed timing deadlines in `cancellationMidBroadcastPublishesNothingAndReportsNoSuccess` and `testStalePauseDoesNotBlockNextOperation`; those are recorded separately from the Sony outcomes. The final full-suite rerun is recorded below.

Final full engine rerun: 110 XCTest cases, 15 skipped, zero failures (64.068 seconds); 129 Swift Testing tests in 29 suites, zero failures (8.181 seconds), including the four local Sony cases. Mounted Sony cases were disabled here and passed separately in the explicit 12-case run. No Mac app/UI or physical-reader validation was performed in this batch, which changes tests and documentation only.
