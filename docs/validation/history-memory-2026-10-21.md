# History memory in the actual app — October 21, 2026

Slice 5 of `docs/TODO.md` ("Next five bounded slices", item 5). Scope:
profile the History window attach/show interval found substantial in
[history-app-host-2026-10-20](history-app-host-2026-10-20.md), and measure
iPad/iPhone, before designing any bounded loading or persistence. No
pruning, paging, persistence or retention-rule changes; IDs, outcomes,
retries, exports, migrations and interrupted-attempt recovery preserved.

Source: worktree `wt-todo-slice-5-history-memory`, branch
`todo/slice-5-history-memory-20261021`, from main `f9cb30f1`. No changes to
`CHANGELOG.md` or `docs/TODO.md` (reviewer consolidates). Nothing pushed.

## Mac app-host probe (completed, reviewer-rerun)

Ran the blessed `Scripts/test-history-app-host-probe.sh` (500 attempts ×
100 rows = 50,000 result rows) in the slice worktree. Receipt fully
verified by the script: complete, 50,000 covered rows, 1 recovered running
attempt, 1 durable legacy row ID, 8 queue summary rows, rendered PNGs for
both History and queue views, 1,443 memory samples, peak **251 MiB**
(under the 1 GiB bound).

New in this slice: the Mac probe now also times model preparation over all
records, collapsed-window attach/show, and empty-journal attach/show. The
phase picture answers the open question from the October 20 probe:

- Worst main-actor pulse delays: `historyViewLayout` **3,348 ms**,
  `historyViewCollapsedAttach` **3,272 ms** — even the collapsed and empty
  variants stall the main actor for seconds.
- Fixture preparation costs 1,489 ms of main-actor delay; queue layout 937
  ms; search stays at 0.1 ms.
- Conclusion: the hot interval is window attach/show and layout, not data
  loading or search. Collapsed and empty journals stall nearly as much as
  the full 50,000-row view, so the cost sits in view hosting/attachment,
  not in record count. Any future bounded-loading design must target the
  attach/show path first; paging records alone will not move it.

Mac-side test additions (`BitMatchTests/HistoryAppHostScaleTests`): model
preparation over reloaded records (visibility filter, safety state, scope
evidence, per-row status text) with safe-footprint checks, plus collapsed
and empty History window attach/show/layout phases with the same memory
and layout instrumentation as the existing full-view phase.

## iPad probe (measured on simulator, reviewer-verified)

`BitMatch-iPadTests/HistoryMemoryAppProbeTests.swift` adds the opt-in
iOS counterpart (`BITMATCH_HISTORY_IOS_PROBE=1`, 100–500 attempts):
synthetic owned journal, search, JSON/CSV export, retry, queue
presentation, full/collapsed/empty History view layout and PNG render on
an actual simulator window scene, with footprint bound, responsiveness
pulses and a JSON receipt attachment. No production code changed; skips
cleanly without the opt-in variable.

Measured run (reviewer, iPad Pro 13-inch M5 simulator, 100 attempts /
10,000 rows): **passed**, peak **91 MiB** over 352 samples, max
main-actor pulse **1,084 ms** in `historyViewLayout` (collapsed attach
867 ms, fixture prep 319 ms, search 0.0 ms). Same signature as macOS:
attach/show dominates even for the empty journal, so the cost sits in
view hosting/attachment, not record count.

Reviewer-found defects fixed during verification (both in the new test
file only): the first journal stayed alive across the reload (a
`guard let` binding lives to end of scope, so nil-ing the source
variable does not release the exclusive history file lock — the reload
failed as already-open), and the coordinator was created before the
queue session was saved (it restores the saved session at init, so it
saw zero rows; creation moved after the save, mirroring the macOS
probe). Simulator measurement is not device performance, does not
reproduce #23, and physical iPhone/iPad measurement is still required
before any loading/persistence design.
