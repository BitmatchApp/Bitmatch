# Journal startup writes — October 20, 2026

Opening current History no longer re-encodes and atomically replaces the entire journal. It still reads and decodes the file, acquires the same exclusive lifetime lock, and retains the same records. Real mutations still persist before publication.

Two startup changes require an immediate write: running attempts become interrupted, and missing/null legacy result IDs receive durable UUIDs. A tracker scoped to that decoder records actual ID generation; another decoder cannot mark an unrelated journal for migration. Invalid IDs still throw. Deterministic optional-field defaults can wait until the next real mutation.

If a required recovery or migration write fails, History retains its recovered in-memory records, exposes the error and blocks mutations. A recovered attempt never reappears as running. Unreadable or malformed data is not rewritten. An unchanged read-only journal can load, but a later failed mutation cannot become visible as a saved change.

## Regression coverage

The focused engine XCTest suite passes 13 tests, with no failures or skips. It checks:

- Unchanged bytes, inode and modification time across repeated opens of current terminal and queued records.
- A 20,000-result synthetic metadata history through the actual journal, preserving all row IDs and evidence across two opens.
- Missing and null row IDs persisted once alongside existing IDs; subsequent opens preserve the assigned IDs without rewriting.
- Running recovery with and without legacy rows.
- Actual read-only-directory failures during migration, recovery and a normal mutation, with original bytes preserved and permissions restored afterward.
- Malformed IDs after a partially decoded legacy row, exclusive lock ownership, ordinary mutation persistence and decoder-context isolation.

The fixtures contain synthetic saved metadata. No source, backup media or production History is opened. The no-rewrite assertions use file identity and exact bytes rather than timing thresholds.

Two isolated source-copy mutations ran all 13 tests and produced actual assertion failures: unconditional startup persistence failed nine cases; ignoring the generated-ID migration flag failed two. The combined running-plus-legacy case still wrote through its independent interruption trigger, so that case alone does not prove the migration flag. Restored real-source tests passed all 13 again. All 127 source/test Swift file hashes remained unchanged during those private mutations.

The initial restricted-agent attempt stopped before testing because it could not write the compiler cache; a later private-copy attempt stopped at SwiftPM's manifest sandbox. Neither was a product test failure or a pass. Authorized reruns executed the recorded tests. Logs retain both environment failures separately.

## Full local checks

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Engine XCTest | 218 | 43 | 0 |
| Engine Swift Testing, unchanged final rerun | 217 | 6 | 0 |
| Full Mac app suite | 1,314 | 23 | 0 |

The universal iPhone/iPad simulator build also passed. Xcode 27.1 built the app targets; the engine ran ARM64 SwiftPM tests with each framework enabled separately, as the local runner requires. Existing compiler/toolchain warnings remain. The Swift Testing XML contains 223 logical cases: 217 passed and six skipped; its console headline includes the skipped cases.

The first full Swift Testing run had one failure: `FanOutTests.cancellationMidBroadcastPublishesNothingAndReportsNoSuccess` did not observe its injected destination-write stall within the helper's two-second deadline. Its subsequent cancellation and no-success/no-output assertions did not fail, but that run did not establish mid-broadcast cancellation. The original failure log is retained.

The unchanged test passed ten fresh-process focused runs and the final full-suite rerun. An exact `origin/main` (`efcedbf1`) source copy also passed the full Swift Testing suite; the failure was **not** reproduced on main. The fan-out test and its production path match main and do not call journal/result decoding. A transient setup deadline is a hypothesis, not a proven cause. No transfer code, test deadline or assertion was changed to obtain the green rerun; a deterministic readiness-gate follow-up remains open.

## Limits

This removes redundant startup encoding and writes. It does not bound journal size, move app startup decoding off the main actor, add paging or change retention. Every real mutation still encodes the full array. This is not a reproduction or diagnosis of either active transfer report.
