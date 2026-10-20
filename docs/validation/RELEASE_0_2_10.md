# 0.2.10 release validation

Final Mac candidate: `b4e23c252b0f1f2bbc9e95b1d42393b1dc06c354`, version 0.2.10, build 20. Validation uses local Xcode 27.1 (27A9275), Swift 6.4. Engine and mobile checks ran at `71bdc9dbdd41b66d2827f5c8ce7454f0352dc85f`; only the Mac app scene, Mac menu-bar drawing and its Mac tests changed afterward. The other 448 recorded source/configuration hashes, including all engine and mobile inputs, match. The final Mac suite and replacement archive use the later candidate.

## Completed local checks

| Check | Result |
| --- | --- |
| Engine Debug, XCTest | 205 passed, 43 opt-in skips, zero failures |
| Engine Debug, Swift Testing | 217 passed, six opt-in skips, zero failures |
| Engine Release, XCTest | 205 passed, 43 opt-in skips, zero failures |
| Engine Release, Swift Testing | 217 passed, six opt-in skips, zero failures |
| Final Mac app suite | 1,314 passed, 23 skips, zero failures |
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

In the initial notarized production candidate, Enable Notifications entered the pending state and disabled duplicate requests. Mike handled the protected macOS prompt and confirmed that Settings showed **Authorized**. The automation tool refuses to control that system dialog. This does not establish the cause of every notification failure.

The production app preserved an older paused queue and correctly blocked settings import while work needed attention. A separate, locally signed copy uses an isolated data profile for the remaining walkthrough; it is not separately notarized. The original notarized app and DMG remain unchanged.

Native settings export passed. Mike confirmed that the actual two-change import opened a compact review, Cancel retained the original settings, and Apply worked. An initial post-check still found Thorough with previews off, so that observation was not counted as a persistence pass. After reopening the exact file and Mike applying it again, both the saved preferences and the native UI showed Standard with clip thumbnails on. No import/reset defect was established. The controller disconnects while that review sheet is open; the human actions and subsequent independent checks are recorded separately.

The isolated copy also completed a real Thorough transfer from the disposable SD-card fixture to separate folders on T9 and WheeDrive, with ASC MHL and reports enabled. Each destination showed three verified files, zero unverified files and three intentionally excluded AppleDouble companions. The live row showed Copying, then Finishing at 89%, before the final result. The selected-file queue finished; the whole-card verdict remained conservative because files were excluded. Advanced also identified the selected WheeDrive's reported USB 2 connection. Independent checks matched all six source files against the pre-transfer hashes, inode identities, sizes, modification times and modes, plus all six selected backup copies. Both three-file MHL inventories, inventory-chain hashes and completion-record digests validated. PDF/CSV/JSON/checksum reports validated, and both rendered PDF pages were readable. The checker's initial file-URL/path comparison error is retained separately from its corrected passing run; these independent XML/hash checks are not a new formal ASC schema-validation run. Previews were off for this transfer. Mike reported no menu-bar icon in the initial candidate. The replacement supplies real template images and uses explicit companion-scene insertion, following [Apple's multi-scene API](https://developer.apple.com/documentation/swiftui/menubarextra/init(isinserted:content:label:)). Image tests check visible pixels, distinct progress states, bounded caching and off-main drawing. Review caught a callback-isolation risk before the final build; the corrected callback is explicitly Sendable and captures only immutable data. No corresponding crash was reproduced. The replacement passed the full Mac suite, notarization and Gatekeeper. The initial signed artifact is retained separately. Mike confirmed that the replacement icon is visible, the menu shows the idle status and last card, and Open BitMatch works. This establishes the replacement's native behavior; the two changes were tested together, so it does not isolate one cause. The active-window hide/Quit guard and new-card event paths retain automated coverage but were not separately exercised in this final native check.

## Limits

The [overnight validation](../OVERNIGHT_VALIDATION_20261019.md) records the mounted-filesystem and physical SSD/SD tests, including their individual source revisions and failed attempts. Those earlier hardware runs are not presented as new runs of this release candidate.

GitHub's Xcode 26.3 jobs currently fail during Mac compiler IR generation and compilation of engine-test isolation patterns. They are not runtime test passes or billing failures. The local shipping-toolchain results do not prove source-build compatibility with that older compiler.

Neither synthetic passes nor this release establish the cause of the open field reports. Issues #10 and #23 remain open.
