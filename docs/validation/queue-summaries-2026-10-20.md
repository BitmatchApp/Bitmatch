# Completed queue summaries — October 20, 2026

The queue rebuilt completed cards' derived outcomes on every presentation, repeatedly grouping and inspecting their saved results. The shared journal now retains derived rows for up to 64 completed session cards. It keeps a stable newest-first subset in larger sessions, so rendering older cards does not evict every cached card.

The journal clears the cache on every record refresh, including failed mutations. Its engine store is private, so callers cannot mutate evidence without that refresh. During synchronous `@Published` notifications, presentation bypasses cache reads and writes: an observer can see the previous snapshot without retaining it after the update. No result-count or pointer-based freshness heuristic is used.

Mount and eject actions are reapplied on every presentation. Queued and running rows use current state and progress. Saved results, exports, journal encoding and safety rules are unchanged.

## Regression evidence

Seven new tests cover:

- 24 completed cards with 200 results each alongside an active card over 30 copying/verifying ticks. Completed evidence is derived 24 times; live progress and mount/eject actions change correctly. Cached and uncached presentations match.
- Same-count replacement results, changed sizes, reasons and terminal outcomes.
- Synchronous journal observers reading the previous snapshot during publication.
- Retry, changed file plans, incomplete and verified outcomes, and phase durations.
- Sessions larger than 64 cards, stable cache admission, session removal and preserved history.
- A new retry attempt, queued removal and failed mutations.

Focused Mac checks passed all 31 selected tests: the 7 new cases and 24 existing queue-presentation cases, zero failures or skips. Four isolated mutations ran all 7 new tests and produced real assertion failures: ignoring cached rows, retaining rows across refresh, admitting rows during publication, and disabling the entry limit. Ignoring cached rows produced 744 derivations instead of 24 in the live-tick test.

The full Mac app build and test suite passed: 1,321 passed, 23 skipped, zero failures (1,344 total). It used the `mac-test` job's Xcode test arguments with a private DerivedData folder and a retained result bundle. Skips include opt-in snapshots and hardware checks.

The shared iPhone/iPad target also built successfully for the iOS simulator using the `ipad-build` job's arguments. Existing warnings in untouched updater, executor and queue-view code remain; this is not a warning-free build claim.

## Limits

The cache bounds entries, not total bytes. Derived issue descriptions can grow with a record's results; it retains no raw result arrays. Older cards outside the admitted subset still derive their summaries on demand, and journal mutations invalidate unchanged cards too. History loading and persistence remain separate work. This is not an established cause or fix for issue #23.

The tests exercise the shared presentation model on Mac. iPhone/iPad compilation does not measure responsiveness on physical devices. No layout or transfer-engine behavior changes in this patch.
