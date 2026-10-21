# Per-destination out-of-space pause — October 21, 2026

Slice of `docs/TODO.md` "Per-destination out-of-space handling".
Per-destination fault isolation already existed (a bad destination
fails its own rows while others finish, covered by
`MountedFilesystemFaultTests`); what was missing was pause semantics —
a full destination kept receiving write attempts for every remaining
file.

Source: worktree `wt-space-pause`, branch `todo/space-pause-20261021`.

## Behavior

- First ENOSPC from a destination (temp creation, write, flush or
  publish path) pauses it for the rest of the attempt
  (`SpacePauseTracker` in `DestinationWriter.copyAllSafelyFanOut`).
- Later files for that destination fail fast through the normal error
  path with a POSIX ENOSPC error ("paused for the rest of this
  attempt"): a failure row is still recorded per file, no temp file is
  opened, and no partial work can publish.
- Other destinations are untouched and finish normally. Cancellation
  is unchanged (never classified as a destination failure), partial
  work remains incomplete, and the verdict cannot succeed while any
  required destination has failed rows.
- Resume is a new attempt: safety preflight revalidates space and
  destination identity from scratch. No timed in-attempt retry was
  added — an operation sleeping to wait for freed space would block
  cancellation and other destinations' verification for no proven gain.

## Tests

- New `FanOutTests.outOfSpaceDestinationIsPausedWhileOthersFinish`:
  24 files, one destination always ENOSPC. All 24 healthy rows succeed
  with bytes intact; all 24 full-destination rows fail with ENOSPC
  (paused rows carry the pause wording); write attempts on the full
  destination are bounded by the worker count (≤4), never the file
  count; verdict not successful.
- Full engine suite: XCTest 344 executed (86 skipped), Swift Testing
  270 — all passing.
