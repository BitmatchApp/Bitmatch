# Blocked-drive discovery bounds — October 21, 2026

Slice 2 of `docs/TODO.md` ("Next five bounded slices", item 2). Scope: the
code-side remainder — outstanding-work bounds across rescans, generation and
mount-identity checks, honest unknown-capacity reporting, no recursive survey
of unselected storage, held/released tests for a second healthy drive,
replacement/unmount, late results, responsiveness and worker/file-descriptor
bounds. A display deadline never cancels a blocked filesystem call. Physical
blocked-drive responsiveness and descriptor measurements stay open (no
hardware here); verification/copy-safety semantics unchanged.

Source: worktree `wt-todo-slice-2-blocked-drive`, branch
`todo/slice-2-blocked-drive-20261021`, from main `f9cb30f1`. No changes to
`CHANGELOG.md` or `docs/TODO.md` (reviewer consolidates). Nothing pushed.

## Inspection result

Most item-2 bounds were already on main (bounded schedulers,
generation/identity checks, a depth-capped root-anchored classifier, no
recursive survey of unselected storage). Two genuine gaps remained:

1. Destination capacity went stale across mount changes: a replaced or
   unmounted destination kept advertising last-known free space until the
   re-probe finished.
2. The deadline/display-cancel property had no coordinated test: abandoning
   the display wait while a filesystem call held a worker slot was
   unexercised.

## What changed

- `Shared/Core/Services/SharedAppCoordinator.swift`
  - `prepareSelection()`: clears `destinationCapacities` while re-probing so
    a replaced or unmounted destination never shows last-known free space.
  - `refreshSourceAvailability()`: when a source or destinations are
    selected, re-schedules selection preparation on the bounded worker so
    identities, names, capacities and readiness are rechecked under the
    current generation; coalesces with in-flight preparation.
- `BitMatchTests/DriveAccessWorkerTests.swift` — `rescanStormStaysBoundedAndDrains`,
  `displayDeadlineNeverCancelsBlockedCall`,
  `cancelledDisplayTaskKeepsBlockedSlotAndAppliesNothing`.
- `BitMatchTests/DriveUIResponsivenessTests.swift` —
  `mountRefreshDropsStaleDestinationCapacity`.
- `BitMatchTests/SourceAvailabilityModelTests.swift` —
  `unmountedRecordLeavesOtherMountAvailable`,
  `replacedFolderAtSamePathReprobesUnderNewIdentity`,
  `everyEntryIsEvaluatedExactlyOnce`.

## Observed runs

- Focused (`DriveAccessWorkerTests`, `DriveUIResponsivenessTests`,
  `SourceAvailabilityModelTests`, `CODE_SIGNING_ALLOWED=NO`,
  `-parallel-testing-enabled NO`): **18 tests in 3 suites, all passed**
  (reviewer rerun; sandbox `linkd` log noise only, no failures).
- Full Mac suite was not rerun for this slice; the change is additive
  (two small coordinator branches) plus tests, and the touched suites pass.

## Open items

Physical blocked-drive responsiveness and file-descriptor measurements on
real hardware remain open per the TODO item. The display deadline property
is covered synthetically (held/released workers), not against a truly
blocked device.
