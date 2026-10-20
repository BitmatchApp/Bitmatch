# Combined workflow checks — October 20, 2026

This record covers the integration of PRs #66–#75: History/queue work, diagnostic writers, classic MHL Check, mobile controls, test-fixture retention and queued cancellation. It records the tested candidate, not a release or a claim that the open field reports are resolved. GitHub Actions remains disabled.

## Scope and revisions

The combined branch started at `efcedbf1f5e111a2ae5b569796b47a0e67f84505` and contains all seven reviewed PR heads. Commit `e327b531` adds the first UI cleanup; `9282c653` retains failed hardware fixtures and extends the empty-file retry probe. These checks precede the later mobile bottom-action-bar work unless explicitly stated otherwise.

The primary checkout, production app, preferences and existing footage were preserved. Physical fixtures used new, marked directories on an exFAT microSD card and two exFAT Samsung SSDs. One SSD used the slower cable provided by Mike. No physical volume was formatted or ejected.

## Completed checks before the bottom-action-bar change

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Engine XCTest | 224 | 44 | 0 |
| Engine Swift Testing | 239 | 6 | 0 |
| Full Mac app suite | 1,357 | 29 | 0 |
| Opt-in Mac layout captures | 3 | 0 | 0 |
| Full iPad simulator suite with captures | 90 | 0 | 0 |
| Full iPhone simulator suite with captures | 90 | 0 | 0 |
| Physical-runner Python tests | 24 | 0 | 0 |

The universal iPhone/iPad simulator build also succeeded. Counts use logical Xcode tests, not expanded parameterized executions. Existing compiler warnings remain. Opt-in large/hardware engine cases did not silently become part of the default suite.

The engine checks include mounted exFAT handoff, synthetic transfer combinations and the 5,009-file stress fixture. Private guard-removal runs produced actual assertion failures for composer width, handoff explanation, count grammar and the pause-stage guards. The restored focused suites passed. None of these UI changes modifies engine production sources.

## Physical transfers: retain the first failure

The first uninstrumented matrix failed during Standard existing-file reuse: the zero-byte file was rejected by the final identity check on both SSDs. The old runner removed its failed fixture, so the exact failing identity fields cannot be recovered. This is an unresolved test failure, not evidence that the reporter's interruption has been reproduced.

A private diagnostic-only engine copy then completed all nine transfers: Quick, Standard, Thorough and Paranoid with pipelining off/on, followed by Standard reuse. Its strict identity checks were unchanged. The card contained 272 files, approximately 2.15 GB including AppleDouble companions. Source hashes and previous MHL histories remained unchanged. The largest observed engine-worker memory footprint was 32 MiB. One XCTest completed in 890.964 seconds.

A further reuse check of those retained Standard destinations passed in 167.519 seconds with no new media copies, unchanged source hashes and unchanged MHL histories. Between the two successful runs, the untouched T9 empty file reported a different inode with the same size and timestamps. That observation is outside a run; it does not establish the cause of the original rejection. No engine identity check has been relaxed in the review branch.

Small retries on all three drives also passed, including a main-based test branch. They do not erase the original full-matrix failure.

## Mobile bottom actions

Commit `f1241254` keeps Start at the iPhone/iPad viewport bottom. Running transfers use that area for Pause/Resume and Cancel; the Transfers sheet owns its controls while open, and History/other tools do not inherit them. Start calls the existing queue/project/readiness actions. A delayed Cancel confirmation captures the current attempt ID and rechecks it before cancellation. This does not make the engine's Pause API operation-scoped; its post-await coordinator check protects presentation state.

At `f1241254`, the full iPhone and iPad schemes each passed 96 logical tests, with no failures or skips, including all workflow captures and the existing launch UI tests. The focused Mac readiness/control cases passed 19 tests without failures or skips. Captures use actual SwiftUI shells at 375, 760 and 1,180 pt, including light/dark, ready/blocked/running/paused/settled, sheet/inspector ownership, large text and a simulated keyboard safe area. Source/backup composer readability, action bounds and selected text/duplicate counts are asserted. Both dedicated QA simulators were shut down afterward.

The first whole-shell capture run failed because the window was not attached to a foreground scene. Scene attachment, async settling and sheet-coordinate observation corrected the test setup; those initial images are not valid layout evidence. After the final passing run, one surplus EOF blank line was removed, with a whitespace-only receipt. No semantic UI change followed that freeze.

These renders do not prove native typing, scrolling, storage-provider permissions or VoiceOver. Large accessibility text still truncates the existing source-card name; the new action labels remain readable. The independent UI branch omits only async adaptations for the two snapshot methods absent from its PR base (#68/#69); both remain present and passed in this combined branch.

The independent UI branch `104d263f` passed its full Mac suite: 1,339 logical tests, 26 intentional skips, zero failures. Its universal iPhone/iPad simulator build also passed, and frozen source hashes matched afterward. This work is [PR #75](https://github.com/BitmatchApp/Bitmatch/pull/75), stacked on #72.

## App benchmark and harness correction

The first app-host Standard transfer completed copy, independent verification, ASC MHL, automatic PDF/CSV/JSON, durable History, regenerated reports, saved-evidence Check and a Master PDF. Its 512 MiB fixture included a playable clip, sidecars and an empty file. Source hashes stayed unchanged; the app-worker footprint peaked at 70 MiB. Rendered PDFs contained the clip frame without clipped rows or overlapping text.

The six-trial benchmark then stopped in test-fixture cleanup, after that first transfer's assertions passed. This was not a successful six-trial benchmark. A smaller probe reproduced the cleanup failure: removing a principal file on exFAT caused macOS to remove its AppleDouble companion, leaving a stale directory entry that returned `ENOENT` when the harness inspected it.

The test helper now tolerates only an already-absent `._` companion with a nonempty suffix. Missing ordinary files and a bare `._` remain errors. Descriptor, device, inode, replacement and no-follow checks stay intact. The actual two-SSD probe and four deterministic/negative helper checks passed after the fix. This changes test cleanup, not product filtering or transfer safety.

The complete repeat at `f1241254` passed: one physical app XCTest, six paired Standard/Thorough transfers, zero failures or skips, 184.6 seconds for the test case. Each transfer used a 512 MiB source payload plus a playable clip, XML, a legitimate `._` file and an empty file. Both backups passed independent hashes and saved-evidence Check; all six trials produced embedded PDF previews, regenerated History exports and a Master PDF. The source snapshot matched afterward, and each successful trial's owned children were removed safely.

| Pair | Standard to settled verdict | Thorough to settled verdict |
| --- | ---: | ---: |
| 1 | 12.508 s | 19.458 s |
| 2 | 12.429 s | 18.347 s |
| 3 | 12.775 s | 19.789 s |

The largest sampled app-worker footprint was 72 MiB. These are steady-state app-host measurements on this card, two SSDs and their current cables. They are not cold-cache, physical-mobile, power-loss or large-clip memory-exhaustion tests. Post-verdict independent checks and regenerated reports add time beyond the settled-verdict columns. No verification default or scheduling policy changed based on this small benchmark.

The separate main-based hardware branch also passed its full Mac suite after this correction: 1,316 logical tests passed, 24 skipped, zero failures. Its earlier unchanged engine checks passed 422 tests with 50 intentional skips. Hardware opt-ins were disabled during the full app suite; the actual-drive cases are recorded separately above. This work is [PR #73](https://github.com/BitmatchApp/Bitmatch/pull/73).

## Queued preparation cancellation

Review found a separate app lifecycle defect on main: exit settlement could return during queued-card preparation, followed by a late engine start. Three deterministic app-host cases ran against the unchanged main coordinator. Two cancellation/restart cases failed with eight assertions, while the Stop-after-current control passed. A test-helper compile error before that run is not counted as a reproduction.

Commit `6e8d41cc` owns each queued invocation through folder-access release, cancels its owned source-scan task and rejects stale admission after awaited preparation. Exit settlement waits for that invocation to unwind; a restart cannot revive it. A card that never started remains queued. Stop after current still runs the already-preparing card.

The final three cases passed. The separate branch's full Mac suite passed 1,317 logical tests, with 23 intentional skips and zero failures; the universal iOS simulator build also succeeded. After those gates, the new test helper gained an explicit teardown drain and passed the same three cases again. Production code did not change after the full-suite freeze. This is [PR #74](https://github.com/BitmatchApp/Bitmatch/pull/74); its combined cherry-pick is `715499bf`.

This proof uses real scratch folders and a gated identity provider in the app host. It is not a native Quit click or physical-drive test. The preceding six-trial physical benchmark ran at `f1241254`, before this correction. Mike then paused physical testing. He later made the SD card and T9 available again; the second SSD is no longer available. The three-volume matrix has not been rerun or represented as a two-volume test. Later app checks clear all physical opt-ins.

## Final combined software gates

At combined commit `715499bf`, the full Mac suite passed 1,371 logical tests, with 30 intentional skips and zero failures. The universal iPhone/iPad simulator build and all three opt-in Mac layout captures also passed. All 462 frozen Swift files still matched when work resumed.

The first final iPad run was interrupted at Mike's stop request; its result bundle is incomplete. The iPhone run had not started. Neither is counted as a pass or product failure. The earlier 96-test passes above belong to `f1241254`.

The first resume attempt booted the QA iPad but stalled in a host `ps` scheduling probe before starting Xcode or tests. That probe was stopped and the QA iPad shut down. A narrower probe is used for the next attempt. The hardware-runner Python unit tests also failed under the unrelated Python 3.9 installation, which lacks descriptor-relative APIs; the documented Homebrew interpreter passed all 24 cases. Neither result used physical volumes.

The completed resume at `715499bf` passed all 93 unit/rendering tests on each dedicated iPhone and iPad simulator, with zero failures or skips. These runs include every workflow capture, but exclude the separate launch/performance UI target that passed in the earlier 96-test runs. Physical opt-ins were cleared. All 462 frozen Swift files matched afterward, and both QA simulators returned to Shutdown. Receipts are in `BottomBarFinalGates` and `ResumedFinalMobileGates2` under the local evidence directory.

## Merge integrity

The integration preserves its tested async snapshot corrections. Simulating independent PR merges in sequence found a test-source regression: the two snapshot methods added by #68/#69 became synchronous against an async capture helper. Merging the three standalone follow-up heads (#73–#75) into the existing tested integration instead changes no files. It records all ten PR heads as ancestors while retaining the exact tested source tree. Only this validation record and the TODO change afterward; no additional runtime or test changes are introduced during integration.

## Private empty-file experiment

A fresh-readback prototype remains outside every product branch in this batch. On a disposable mounted exFAT image, it reopens an eligible reused empty file, performs an actual uncached EOF read, checks the original digests, retains its descriptors through the awaited result callback, and rechecks source and destination identity before status advancement. Its final focused regressions passed 67 XCTest and 36 Swift Testing cases, with no failures or skips. Pipeline cases performed 32 fresh/retry transfers with pipelining off/on; targeted guard removals produced real assertion failures for callback replacement and a source change after publication.

Those tests inject an old recorded inode. They do not reproduce physical driver drift or the original failed run. The prototype still needs separate review, app builds and a new physical matrix before adoption. No part of it is included in the combined candidate or the physical provenance above. Its final patch hash is `ab726f3e18461cf01a147d963420af58ff5ce2415b6bc2afdf996726b22ad0f2`. The obsolete first prototype has known gaps and must not be adopted.

## Limits and remaining gates

The failed empty-file run remains open. A private fresh-readback experiment must prove its complete pipeline, source-change, replacement and cancellation behavior before it can be considered for a product patch. Passing synthetic tests alone is insufficient.

Headless app-host and simulator checks do not replace a signed-app interaction, physical iPhone/iPad storage, VoiceOver, cable-pull, sleep or power-loss walkthrough. These checks do not close issues #10 or #23.

Detailed commands, source hashes, logs, result bundles and owned-fixture receipts are retained locally under `/private/tmp/bitmatch-combined-20261020`. This document reports the bounded scenarios tested rather than promising every drive or workload is covered.
