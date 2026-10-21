# Diagnostic recorder contention classification — October 21, 2026

Slice of `docs/TODO.md` "Classify diagnostic-recording failures under
stress". The 20,000-file probes produced a recorder-error marker with no
recorded cause. This slice classifies the shape deterministically and
closes the disclosure gap; it does not retroactively identify the field
marker, and no timeout was raised.

Source: worktree `wt-diagnostic-recorder`, branch
`todo/diagnostic-recorder-20261021`.

## Classification

`TransferDiagnosticStore.record` appends under a directory `flock` with a
250 ms budget, fsyncing each event while holding the lock. A writer (or
external holder) whose sync is slow therefore makes concurrent writers
exceed the budget; the first failure is classified `directoryLock` /
`EWOULDBLOCK` and persisted in the marker sidecar, and later events are
dropped silently. Existing tests already proved the cross-process lock
timeout classification and whole-snapshot exports. The missing piece was
accounting: exports disclosed that errors occurred, never how much was
lost.

## Change

- Every failed `record` now counts toward `droppedEvents` (per instance),
  exported alongside `recordingHadErrors`; retained + dropped accounts
  for every attempted event in tests.
- The persisted sidecar moves to `v2`, adding the claiming instance's
  dropped count at claim time (a lower bound — later drops by other
  instances are not persisted). The reader accepts both `v1` and `v2`;
  no other sidecar readers exist in the repo.
- New deterministic test: an external descriptor holds the directory
  lock past the budget; five attempted events are all dropped, counted
  (5), disclosed with stage/code, and the next event after release is
  retained — retained (1) + dropped (5) accounts for all attempts.

No change to the 250 ms budget, rotation bounds, redaction, or event
retention caps.

## Tests

- `DiagnosticStore*` suites: 31 tests, all passing.
- Full engine suite: XCTest 343 executed (86 skipped), Swift Testing
  268 tests in 40 suites — all passing.
