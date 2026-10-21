# Native Mac menu and card-event walkthrough — October 21, 2026

Slice 1 of docs/TODO.md ("Next five bounded slices"). Scope: close the
automatable remainder of the native Mac menu/card-event walkthrough —
active-window hide/reopen, Quit settlement, Dock badge/icon behavior, and
newly detected/removed card handling — without changing verification or
copy-safety semantics. Synthetic, signed-app and physical evidence stay
separate. Signed-app Dock observation and a real removable-card walkthrough
remain open and are recorded below with exact steps.

Source: worktree `wt-todo-slice-1-menu-card`, branch
`todo/slice-1-menu-card-20261021`, from main `f9cb30f1`. No changes to
`CHANGELOG.md` or `docs/TODO.md` (reviewer consolidates). Nothing committed.

## What changed

Production (one pure mapping, no verification/copy-safety semantics touched):

- `Shared/Core/Models/QueueSessionPresentation.swift` —
  `QueueDockBadgePolicy.badgeLabel(forCount:)` maps the unresolved-attention
  count to the Dock badge label (`nil` when clean, otherwise the count).
- `BitMatch/App/DockTile.swift` — `DockTileController.updateAttentionBadge`
  uses that mapping instead of an inline ternary. Behavior is identical.

Tests (three new focused cases in the repo test layout):

- `BitMatchTests/TransferExitGuardPolicyTests.swift` —
  `idleQuitTerminatesNowWithoutPrompt`: `AppDelegate.applicationShouldTerminate`
  returns `.terminateNow` when no transfer or queued work needs settlement,
  so idle Quit never presents the stop-transfer prompt.
- `BitMatchTests/QueueSessionPresentationTests.swift` —
  `dockBadgeShowsNothingWhenCleanAndTheCountOtherwise`: badge label is `nil`
  for zero and the decimal count otherwise.
- `BitMatchTests/MacCameraAutoSourceTests.swift` —
  `removedCardDropsItsQueuedReadabilityProbe`: with one probe slot held by a
  first card, a second newly detected card's readability check stays queued;
  removing the second card discards its queued check (it never runs and never
  auto-selects), while the surviving card still auto-selects. Discriminating
  assertion: the removed card's probe runs zero times; without the
  retire-on-removal path it would run once.

## Automated results (this slice)

Focused run (Debug, `CODE_SIGNING_ALLOWED=NO`, `-parallel-testing-enabled NO`):

- `TransferExitGuardPolicyTests`, `MacCameraAutoSourceTests`,
  `QueueSessionPresentationTests`, `DockTileStateTests`,
  `MacMenuBarCompanionTests`: **63 tests, all passed**, zero failures/skips.

Full Mac suite (`./test.sh mac-test`, Debug, `CODE_SIGNING_ALLOWED=NO`,
`-parallel-testing-enabled NO`): **1,144 tests in 110 suites, all passed**,
zero failures, in ~57 s of tests (no skip count was printed by this runner).
Receipt: the `TEST SUCCEEDED`
run above; xcresult under the checkout's `mac-test` derived-data logs.

Flake retained, not hidden: the first full run with these changes reported
1,144 tests with 1 issue —
`MainScreenQueueTests.editCancelRestoresComposerAndUpdateReplacesSnapshotInPlace`.
The work was stashed (tree back to `f9c30f1`) and the same test rerun on the
clean base: it passed in isolation (8 s), while that base-only suite run
still reported 1 issue elsewhere in the same file; a second base-only rerun
passed all 21 `MainScreenQueueTests`. After restoring the slice changes, the
full suite passed 1,144/1,144. The failure reproduces on the untouched base
and does not reproduce consistently anywhere, so it is a flaky UI-timing
case in `MainScreenQueueTests`, not a regression from this slice (whose
production change is a pure badge-label mapping plus delegate/test-only
additions). No test was narrowed, deselected, or edited to get green.

Retained prior automated coverage (unchanged, not rerun as new evidence):

- Hide/reopen: `activeWindowClosesToHideAndReopensWithSameCoordinator`
  (close-during-transfer hides and keeps the coordinator; Dock/menu-bar
  reopen refocuses the same window; idle close really closes).
- Quit settlement: `TransferExitGuardStateMachine` transitions —
  repeated-Quit single prompt, keep-copying denial, failed-settlement
  re-arm (`repeatedQuitKeepsOnePromptAndOneSettlement`,
  `closingActiveTransferHidesWhileQuitStillPrompts`,
  `failedPersistenceDeniesExitAndRearmsTheGuard`).
- Dock icon states: `DockTileStateTests` (running percent, idle icon,
  success-green only, journal-backed `makeTransfer`).
- Menu-bar icon/status/Open: `MacMenuBarCompanionTests` (template pixels,
  distinct states, no completion claim, Open/recent-transfer wording).
- Detection races: `CameraDetectionRaceTests`,
  `CameraDetectionCancellationTests`, `VolumeMonitorReconciliationTests`,
  `CameraCardDetectionTests` (supersede, unmount-in-flight, remount,
  missed-unmount, observer-token ownership).
- Auto-source: `MacCameraAutoSourceTests` (held-probe actor responsiveness,
  prefs/terminal-state invalidation, unmount-drops-late-result,
  remount identity retirement).

## Attempted and dropped

A `miniaturizedWindowDeminiaturizesOnFocus` test was written and run: the
headless test host never reports `isMiniaturized` after `miniaturize(nil)`
(no window-server miniaturization), so the deminiaturize branch in
`focusExistingContentWindow` cannot be exercised by tests. Removed rather
than left failing. The minimize-then-Dock-reopen path stays a signed-app
manual check (open item 1 below).

## Open items (not automatable here)

1. **Signed-app native check** (requires the notarized app + a human at the
   Mac; automation cannot drive the protected flows):
   - Minimize the transfer window mid-transfer, then click the Dock icon:
     expect the same window back, transfer continuing, same coordinator.
   - Hide (Cmd-H) mid-transfer, then click the Dock icon or use
     menu-bar "Open BitMatch": expect the same window back.
   - Close the window mid-transfer: expect hide (not close); reopen via
     Dock/menu bar; after the transfer settles, close really closes.
   - Quit mid-transfer: expect the "Stop this transfer?" sheet; Keep Copying
     denies exit; Stop Transfer cancels, settles the journal, then quits.
   - Dock tile during a transfer shows the progress ring and percent; on a
     fully verified finish it returns to the app icon; on a needs-review
     finish it shows the amber tile; the badge shows the unresolved count
     and clears when reviewed.
   - Menu-bar icon animates during transfer, never shows a completed ring
     while finishing work holds progress below 100%.
2. **Native Dock accessibility inspection**: the 0.2.11 record notes Dock
   inspection timed out and is unobserved; the 31 focused Dock regressions
   and the full Mac suite are the automated evidence, not an observation.
   Rerun the accessibility inspection against the signed app.
3. **Real removable-card walkthrough** (requires a disposable card the
   operator owns; nothing below was run — no fixture was written, no volume
   was probed or modified):
   - Present at the Mac: removable exFAT media is visible at
     `/Volumes/Untitled` (disk8s1, exFAT, reported removable) alongside the
     fixed T9 at `/Volumes/T9`; ownership/contents are unverified, so no
     walkthrough was performed against either volume.
   - Exact steps when a disposable card is available: with the signed app
     running, insert the card with a camera folder structure; expect
     detection (Setup offers it as source; menu bar shows last-card status);
     remove the card mid-idle and expect the Setup offer to retire without
     selecting it; insert during an active transfer from another source and
     expect no source replacement; after a verified transfer to two
     destinations, eject via File > Eject and expect safe removal. Record
     the card model, adapter/reader, filesystem, device node, and whether
     each expectation held; retain failures.
4. Field reports #10 and #23 remain open; nothing here reproduces or closes
   either.
