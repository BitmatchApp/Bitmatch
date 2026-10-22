# Three-disk physical transfer suite — October 21, 2026

First run of the sanctioned physical harness with three distinct
physical volumes attached at once: SD card as source, T9 and WheeDrive
as the two backups. Earlier the same run was impossible here because
the internal disk is not a direct `/Volumes` mount, leaving only two
eligible volumes.

Runner: `Scripts/test-physical-drives.py` (Homebrew Python), no
`--large` case. Fixtures are generated test data in new marked folders;
existing footage is never selected or modified, and passing fixtures
are cleaned up.

## Volumes

| Role | Volume | Notes |
| --- | --- | --- |
| Source (sd) | `/Volumes/Untitled` | 119 Gi card, 112 Gi free |
| Backup A (ssdA) | `/Volumes/T9` | 3.6 Ti, 3.6 Ti free |
| Backup B (ssdB) | `/Volumes/WheeDrive` | 1.8 Ti, 1.6 Ti free |

The runner verified three distinct physical parent disks before
creating any fixture.

## Result

- `testCardToTwoPhysicalBackupsAcrossModesAndReuse` passed: 1 test,
  0 failures, 905.6 s. Card-to-two-backups across verification modes
  plus reuse, on real media through the real engine.
- Runner summary: `exitStatus 0`, `cleanupWarnings []`,
  `retainedFixtureRoles []` — all generated fixtures removed after
  the pass.
- Receipts retained at `/private/tmp/bitmatch-physical-a6aqi34t`
  (`build.log`, `card.log`, `config.json`, `summary.json`).

## Same-candidate gates (main at `5bdf5ef9` plus test-fixture fixes)

- `bash test.sh mac-test`: XCTest 352 executed (33 skipped),
  0 failures; Swift Testing 1,153 passed. TEST SUCCEEDED.
- `bash test.sh engine-test`: XCTest 344 executed (86 skipped),
  0 failures; Swift Testing 272 passed.
- `bash test.sh ipad-build`: BUILD SUCCEEDED.

## Mac-suite failures found and resolved on the way

The first full Mac run failed two Swift Testing tests; both also fail
on the pre-re-copy base `e0b2e1ff`, so neither is a re-copy regression.
Both trace to one intended behavior change from the assurance audit
(commit `72ccbf2c`): a completed transfer claim with no successful
rows now resolves to `.issues`, never success. The audit added its own
pin (`ResultPresentationTests.testCompletedTrueWithNoRowsResolvesToIssues`)
but two older fixtures still modeled the pre-audit world:

- `TransferMenuPresentationTests.ejectRequiresSafeToEraseAndAnEjectableSource`
  built its "safe" outcome with zero rows, so the eject gate correctly
  stayed closed. The fixture now carries one verified row, matching a
  real safe transfer; the unsafe states still expose no Eject title.
- `SharedCompareFlowTests.testCleanCompareDoesNotInheritPriorCopyFailures`
  used `CompletionVerdict.resolve` as its oracle. Production compare
  reports through `CompareOutcome`, where a clean compare legitimately
  has zero difference rows; the test now asserts the coordinator's own
  completed-success state, results and error state directly.

One further full-run failure,
`MainScreenQueueTests.replacementWhileEditingCannotBeSavedAsTheOriginalSelection`,
is a timing wait that passed in the first full run, passed alone
(21 tests), and passed in the final clean full run; recorded here as
an observed one-off flake under load, not a code change.

## Limits

- The 119.6 GB `--large` case was not run (multi-hour destination
  I/O); this was the bounded non-large case.
- No signed-app Dock/card walkthrough, no power-loss test, and no
  fault injection on physical media. Synthetic fault coverage remains
  the engine suites.
