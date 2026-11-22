# Splitting `work/unvalidated-todo-20261109` — design

Date: 2026-11-22. Approved by Mike ("start on all that you found").

## Intent

The branch bundles six unrelated changes in 105 files, never built. Four
independent reviews (Codex, muse, Gemini, GLM) all BLOCK and all recommend
the same split. Land it as five slices, each extracted by file onto its own
branch off main, compiled, tested, reviewed and merged before the next.

## Confirmed findings to fix (verified in code by the lead)

1. SourceFaultLineage returns noFaultObserved for predecessors without the
   new failure tokens (0.2.13 records, enumeration failures with no rows).
2. Eight verdict surfaces call the single-record safety check that skips
   lineage (CSV/JSON, PDF, Dock, menu bar, queue recovery, two presenters).
3. The completion-wording clamp was deleted (two folders on one disk read as
   "all 2 backups").
4. A failed settings Apply leaves the pending record; startup rolls it
   forward with no busy/changed/expiry checks.
5. One shared 2-slot executor for 18 call sites; cancelled queued jobs are
   never evicted; transfer-critical enumeration shares capacity with scans.
6. iOS file listing drops security-scoped access on cancel while the
   enumeration continues.
7. Journal `independentDestinationCount` changed meaning under the same key.
8. Three compile errors (Sendable field, @Sendable closure, reversed array).

## Slices, in order

1. Evidence reader: SavedChecksumCheck + fixtures + MHL tests. Fixtures need
   their README-stated independent verification before being called
   compatibility evidence.
2. Independence rename + volumeIsLocal guard + unknown-capacity presentation.
3. BoundedBlockingExecutor: compile fixes, queue pruning, a separate pool
   for transfer-critical enumeration, scoped-access audit; engine call sites
   first, then DriveAccessWorker and app migrations.
4. Failure reasons + lineage + every verdict surface as one safety slice;
   unclassified predecessors fail closed; clamp restored; journal key
   disambiguated.
5. Portable settings v2 + roll-forward, with the failed-Apply fix and an
   honest durability claim. Docs/TODO/contract proposals ride with this.

## Non-goals

No new features. No behaviour the branch did not already intend, beyond the
fixes above. Each slice: engine-test and mac-test green; ipad-build where
Shared/ changes; one external reviewer pass before merge.
