# Failed-readback marking surfacing — October 21, 2026

Follow-on to [failed-readback-marking](failed-readback-marking-2026-10-21.md):
the marking outcome now survives into History and reports instead of
being visible only as a changed destination path.

Source: worktree `wt-marking-surfacing`, branch
`todo/marking-surfacing-20261021`.

## Change

- `FileOperationResult.failedOutputMarking` records the outcome at both
  verify sites: `marked`, `nameOccupied`, `fileChanged`, `fileMissing`,
  `nameTooLong`, `swapped`, or `markingFailed` when the mark itself
  throws. Nil when marking was not attempted (match, read error, reused
  file, Quick).
- `ResultRow.failedOutputMarking` carries it through
  `TransferCompletion.row`; JSON encoding includes it when present, and
  rows persisted before this change decode with it absent (covered by a
  legacy-JSON decode test).
- History status wording (`TransferHistoryResultPresentation`):
  marked rows read "… · failed file renamed with .bitmatch-failed
  suffix"; skipped rows name the reason and state the file is still at
  its original name. Unmarked legacy rows are unchanged.

## Tests

- Engine: `FailedReadbackMarkingTests` 6 (incl. legacy decode +
  round-trip), FanOut corruption case asserts `marked` on both the
  operation result and the converted row. Engine suites green.
- App: `TransferLibraryPresentationTests` 41, including the new
  marked / name-occupied / legacy wording cases.
