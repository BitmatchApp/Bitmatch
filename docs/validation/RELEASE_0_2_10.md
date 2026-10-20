# 0.2.10 release validation

Candidate source: `71bdc9dbdd41b66d2827f5c8ce7454f0352dc85f`, version 0.2.10, build 20. Later documentation edits do not change the 451 recorded source/configuration hashes. Validation uses local Xcode 27.1 (27A9275), Swift 6.4.

## Completed local checks

| Check | Result |
| --- | --- |
| Engine Debug, XCTest | 205 passed, 43 opt-in skips, zero failures |
| Engine Debug, Swift Testing | 217 passed, six opt-in skips, zero failures |
| Engine Release, XCTest | 205 passed, 43 opt-in skips, zero failures |
| Engine Release, Swift Testing | 217 passed, six opt-in skips, zero failures |
| Mac app suite | 1,308 passed, 23 skips, zero failures |
| iPad Air M4 simulator | 75 passed, ten skips, zero failures |
| iPhone 18 Pro simulator | 75 passed, ten skips, zero failures |
| iOS device Release build | Succeeded; actual arm64 binary, iOS 18.5 minimum |
| Offline updater tests | Eight passed, zero failures or skips |
| Signed Mac app and DMG | Apple notarization accepted; stapled; Gatekeeper accepted both |

Mac and mobile structured results and raw logs contain no detected runtime state-update or continuation warnings. Existing compiler warnings remain. Both reused, owned mobile simulators were shut down after their tests. This is simulator coverage, not physical mobile file-provider or background testing.

Independent reviews found no blocker in the transfer/evidence, Unicode filename, queue-exclusion or updater changes. The notification review found stale failure text after returning from System Settings; the correction and regression are included in the passing Mac suite.

The first notification-focused attempt failed the newly added stale-error cases while a follow-up edit was being compiled. That attempt remains failed; the committed, frozen candidate passed the complete suite afterward. It is not claimed as a controlled red-state experiment.

## Notifications and native walkthrough

The temporary diagnostic app's button returned an immediate system error with no visible explanation. The notification service also logged that it could not validate that diagnostic bundle. The new UI shows pending and failed requests, offers System Settings for the running bundle, and allows retry without changing notification preferences.

In the notarized production app, Enable Notifications entered the pending state and disabled duplicate requests. Mike handled the protected macOS prompt and confirmed that Settings showed **Authorized**. The automation tool refuses to control that system dialog. This does not establish the cause of every notification failure.

The production app preserved an older paused queue and correctly blocked settings import while work needed attention. A separate, locally signed copy uses an isolated data profile for the remaining walkthrough; it is not separately notarized. The original notarized app and DMG remain unchanged.

Native settings export passed. Mike confirmed that the actual two-change import opened a compact review with Cancel and Apply. The controller still disconnects when that Settings sheet comes forward; Cancel/Apply, progress and menu-bar checks remain pending. Hosted layout and model tests are separate evidence and do not close the remaining native gap.

## Limits

The [overnight validation](../OVERNIGHT_VALIDATION_20261019.md) records the mounted-filesystem and physical SSD/SD tests, including their individual source revisions and failed attempts. Those earlier hardware runs are not presented as new runs of this release candidate.

GitHub's Xcode 26.3 jobs currently fail during Mac compiler IR generation and compilation of engine-test isolation patterns. They are not runtime test passes or billing failures. The local shipping-toolchain results do not prove source-build compatibility with that older compiler.

Neither synthetic passes nor this release establish the cause of the open field reports. Issues #10 and #23 remain open.
