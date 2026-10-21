# History window attach/show — October 21, 2026

Follow-on to TODO item 5 measurement (`history-memory-2026-10-21.md`).
Scope: reduce History attach/show stalls only. No pruning, paging,
persistence or retention changes; IDs, outcomes, retries, exports,
migrations and interrupted-attempt recovery untouched. Search results
identical by construction and by the existing search-model tests.
Nothing committed or pushed.

Source: worktree `wt-history-attach`, branch
`todo/history-attach-20261021`, from main `5551990c`. `CHANGELOG.md`
and `docs/TODO.md` untouched (reviewer consolidates).

## Root causes (with evidence)

### 1. Collapsed DisclosureGroups eagerly built full record details

`TransferLibraryView.rowView` passed `detailsView(record, …)` as the
`DisclosureGroup` content for every row. On macOS that content is
evaluated even while collapsed, so first attach built, for all 500
records: the safety-state scan, `VerificationScopeEvidence`,
`TransferHistoryMetrics`, `TransferRecoveryDetails`, and a `ForEach`
over up to 100 result rows per record (~50,000 row views).

Evidence: guarding the content with `expandedIDs.contains(record.id)`
alone cut window attachment 1.95 s → 0.46 s and collapsed attachment
1.79 s → 0.29 s in the probe below. Details are pure presentation
(state lives in the parent view), so building them only while expanded
changes no verdict, action or export.

### 2. Collapsed-row label/detail scanned result rows repeatedly

`TransferRecordRow` computed `stateLabel(for:)` and `fileCount(for:)`
separately; both call
`TransferOutcomePresentation.hasVerifiedSelectedFiles` (a full
result-row scan), and the label path also builds destination summaries
over the same rows. Stubbing those two computations in a throwaway
probe run cut attachment a further 0.46 s → 0.23 s, sizing the cost.

Fix: `TransferLibraryPresentation.rowPresentation(for:)` computes the
verified-evidence flag once and derives label + detail line from it.
The public `stateLabel(for:)`/`fileCount(for:)` delegate to the same
private helpers, and a new test asserts the combined result equals the
separate computations for every record state.

### 3. Full scans repeated per body pass

`visibleMatches`, `visibleRecords` and `tabCounts` were recomputed by
every property the body touched (list, placeholder, review target,
searchable gate) — roughly five record scans per pass. The body now
computes matches and counts once per pass and hands them to the list
content. Each scan is O(records), so this is a smaller win than 1–2,
but it removes the multiplier on every invalidation.

### 4. Search indexing was already lazy — verified, now pinned

`TransferHistorySearchModel.requestSearch` returns synchronously for
an empty query without invoking the index builder, and
`TransferLibraryView` opens with an empty query; the expensive ~1–2 s
index in the baseline is the probe's explicit on-demand search, not
attach work (probe `historySearch` main-actor pulse: 0.05 ms). No
production search change was needed. A new test pins the contract:
resume/replaceRecords with an empty query builds no index; the first
nonempty query builds it exactly once. Search behavior and results
are unchanged.

## Probe numbers (Mac app-host, 500 attempts / 50,000 rows)

`Scripts/test-history-app-host-probe.sh`, this machine, single runs —
shared-machine observations, not thresholds. Deltas are checkpoint
differences within each run's receipt.

| Checkpoint | Before | After | 
| --- | ---: | ---: |
| Window attachment | 1.95 s | 0.30 s |
| Window orderFront | 0.95 s | 0.25 s |
| Settle (300 ms sleep + runloop) | 0.89 s | 0.30 s |
| Collapsed attachment | 1.79 s | 0.23 s |
| Collapsed orderFront | 1.13 s | 0.19 s |
| Empty-journal attachment | 0.007 s | 0.006 s |
| Max main-actor pulse | 2,994 ms | 1,158 ms |
| Peak footprint | 242 MiB | 334 MiB |
| Explicit search wait (on-demand) | 1.10 s | 1.59 s |

Receipts retained under the probe evidence base
(`app-host-20261021T222408Z-81533` before,
`app-host-20261021T222955Z-85480` after); both runs passed the strict
wrapper (complete receipt, cleanup verified, 50,000 covered rows, 1
recovered running attempt, 1 durable legacy row ID, 8 queue rows,
both PNG renders). Peak footprint varies run to run on this shared
machine (242–334 MiB across all runs here, including intermediates);
no leak claim is made either way. Search wait is the unchanged
on-demand index+match for a typed query.

## Tests

- `TransferHistorySearchModelTests`: new
  `testIndexBuildsLazilyOnlyForTheFirstNonemptyQuery`; whole suite
  passes.
- `TransferLibraryPresentationTests`: new
  `rowPresentationMatchesSeparateLabelAndDetailComputations`; whole
  suite passes (40 tests).
- `HistoryAppHostScaleTests` (ordinary cases) passes; the opt-in
  500-attempt probe passes before and after (above).
- iPad scheme `build-for-testing` succeeds (row view is shared).

## What remains

- Attach is now ~0.3 s at 500 records on this machine; the remaining
  cost is SwiftUI List/DisclosureGroup graph construction plus one
  evidence scan per materialized row. Further cuts would need a
  different row container or a presentation cache keyed by record
  content — not attempted here.
- The ~1–2 s first-keystroke search index over 50,000 rows is
  unchanged and on-demand; it already runs detached with a searching
  placeholder. Indexing incrementally is a separate design.
- Physical-device (iPhone/iPad) History attach timing is still
  unmeasured; the simulator probe from the slice-5 doc remains the
  only iOS evidence.
