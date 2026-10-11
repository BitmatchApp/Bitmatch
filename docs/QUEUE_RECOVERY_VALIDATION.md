# Queue editing, admission and recovery

October 10, 2026. Based on `main` at `13be2f05`, developed on `feature/queue-recovery`. This is a pre-merge validation record, not a release or a resolution of a user's hardware report.

## Changes

- Edit resolves the original bookmarked folders before changing Setup and retains their access while editing. Unchanged selections are checked again when saving. Cancel restores the previous composer, including its original folder identities, operator and notes.
- Setup captures folder identities when selected. Start validates them with fresh filesystem values, then journal admission checks the actual execution URLs after asynchronous preflight. Identity includes volume, resource ID and, for new records, creation date. Missing old creation dates decode normally.
- Different cards in the queue cannot target the same or nested output folders. Case-only differences are treated conservatively for portable destinations. A started card retains its reservation within the current queue session. An intentional retry of the same original source remains supported.
- Retries retain a link to their previous attempt; editing a retry to use a different source removes that link. The old attempt remains unchanged.
- The engine's selected-file counts are saved once when progress first supplies them. Expanded queue and History details show reused/verified, copied/verified, unverified, failed, excluded and pending counts per backup. “Copied” means copied during this attempt, not necessarily copied before. Pending means no saved result; older or ambiguous evidence shows an unknown count. These figures do not decide the safety verdict.
- JSON and CSV history exports include the attempt link and planned counts; CSV also carries each row's reuse flag. Access tokens are not exported. PDF layout and ASC MHL semantics are unchanged.
- Mac Edit uses the reverse card animation, with Reduce Motion respected. Compact mobile Edit closes the queue sheet to reveal Setup.

## Reproductions and tests

The first new replacement test failed despite the added identity check: Foundation returned cached resource values from an already-read URL. Clearing cached resource values made both source and destination replacement tests pass. This is observed red-to-green evidence, not an inferred failure.

The new regressions cover:

- Replacement source and backup folders while sitting in Setup, while editing, and between queued preflight and admission. The app-level admission test asserts the copy executor never starts.
- Identical, case-only and nested queue output collisions; distinct sibling output folders and an intentional same-source recheck; reservations after a previous attempt starts.
- Retry lineage, settings and planned counts surviving serialization; old records without the new fields; export without bookmarks.
- Three real recovery transfers, one in each of Standard, Thorough and Paranoid, with two backups. Backup A begins with one matching file and one conflicting file; Backup B is empty. The engine reuses the matching file after verification, copies missing files, preserves the conflict, and leaves the retry unsafe. Counts match both destinations. The source and original interrupted record remain unchanged.
- Duplicate/conflicting result rows, Quick/unverified results, intentional exclusions, missing older plans and unassigned destination evidence. None can inflate successful counts or invent zero pending.
- Edit/cancel/save preserving order, mode, report settings, operator and notes, including editing while another transfer runs.

Local validation:

- `arch -arm64 swift test --package-path Packages/BitMatchEngine --build-system native --jobs 4`: 123 XCTest cases, 15 intentional skips, zero failures; 138 Swift Testing tests, zero failures. Includes mounted exFAT handoffs and the existing AppleDouble filesystem matrix.
- Mac full suite (`xcodebuild test`, `BitMatchTests`, `-parallel-testing-enabled NO`): 1,097 passed, 12 opt-in/hardware skips, zero failures. This run includes the final code and all new Mac regressions. The four opt-in workflow capture tests also passed in the separate capture run.
- iPhone 17 Pro simulator: all 71 tests passed, including opt-in rendered workflows.
- iPad Air 11-inch (M4) simulator: all 71 tests passed, including opt-in rendered workflows.
- Inspected recovery details on Mac, iPhone and iPad, plus expanded History at 320 points. No clipping in the added details. The captures exercise production views with synthetic records, not a physical-device transfer or a signed release walkthrough.
- `git diff --check`: clean.

Raw logs, result summaries and PNGs are retained locally in `dist/validation/queue-recovery/`.

Failed intermediate runs are retained too. The first Mac run caught an assertion comparing `/var` with `/private/var` after bookmark resolution; the test now compares resolved URLs. A setup fixture also needed to wait for its AppleDouble review, not just its folder-size scan. A later engine run under concurrent builds hit existing short deadlines in three concurrency tests; the complete engine rerun without competing BitMatch builds passed. Running all opt-in AppKit captures alongside the Mac suite hit the existing five-second source-scan deadline once; all four capture tests passed. Ordinary tests and captures are assessed separately; failed runs are not counted as passes.

## Limits

These are local filesystem, mounted disk-image, model and simulator tests. They do not establish real reader/cable/dock reliability. The admission check narrows the selection-to-execution gap; descriptor-pinned engine protections remain necessary during a run. Recovery rechecks whole files, not byte offsets. Pending counts describe saved evidence, not a claim that an unrecorded file was never written. An attempt removed from History no longer supplies a visible predecessor date, but its retry ID remains saved.

## Signed Mac walkthrough

The walkthrough began with a local universal Release archive built by `Scripts/release_mac.sh` with `SKIP_NOTARIZE=1`, using the existing Developer ID and sandbox entitlements. It was launched from its archive; nothing was installed over the released app, notarized, tagged or published. The only production follow-up was left-aligning recovery counts inside the expanded queue row. A fresh final archive used the same Release configuration and signing sequence; strict deep signature verification passed.

Disposable mounted volumes provided an APFS source and APFS/exFAT backups. The production UI and native folder pickers exercised:

- Queue → Edit → Cancel, then Edit → Update: both backups, Standard verification, ASC MHL, reports, operator and notes were retained. Cancel restored the previous notes; Update reached the generated report.
- A four-file transfer including a hidden sidecar and an empty folder: both backups matched the source, ASC MHL was published on both, and PDF/CSV/JSON reports were saved. The app showed a verified completion.
- A three-file recovery case: APFS began with a matching file and a conflicting file; exFAT began empty. APFS showed **1 reused, 1 copied, 1 failed, 0 pending**; exFAT showed **0 reused, 3 copied, 0 failed, 0 pending**. The conflict was byte-for-byte unchanged, and the overall result needed attention.
- After moving only the disposable conflict aside, Retry showed **2 reused + 1 copied** on APFS and **3 reused** on exFAT. All media verified, but the existing ASC MHL history correctly kept the handoff outcome unsafe. The explicit **Retry without ASC MHL** then reverified all six copies and completed successfully. History retained the earlier failed attempts and retry links.
- Replacing the selected source folder before Start: the app refused it with “Its original folder could not be confirmed.” Neither backup gained an output folder for the replacement.
- The final signed archive retained the retry evidence after relaunch, displayed the corrected left alignment and ejected the verified disposable source through the app. Setup preferences and selections were restored afterward.

Independent file checks confirmed source hashes, sizes, modification times and permissions were unchanged. Four JSON reports preserved the operator and edited notes and recorded the expected safety sequence: success, conflict/unsafe, existing-history/unsafe, success without new MHL. Failure reports append issue details to the operator's notes; the initial probe incorrectly expected exact note equality and was corrected to check the preserved first line plus the failure verdict.

One native folder-picker attempt left Choose Source disabled after Go to Folder. Cancelling, reopening and navigating into the same folder enabled it. This was a transient UI observation, not a reproduced BitMatch code defect.

Raw signed-build logs, sample reports/MHL and independent file-check results are in the local validation directory. All three disposable images were detached and removed after retaining the small evidence files. Physical iPhone/iPad access/background testing remains outside this Mac and simulator coverage. A future published release still needs notarization and distribution checks.

After the alignment fix, the full Mac suite passed again: **1,097 passed, 12 skipped, zero failures**. `mac-closeout-summary.json` and `mac-closeout.log` retain that result. The simulator test counts above precede the alignment-only follow-up. A fresh shared iPhone/iPad Release simulator build (arm64 and x86_64) then succeeded; its log is `ios-closeout-build.log`. The signed Release build still reports existing warnings about the updater conformance, a trailing closure, unused animation results, AppIntents metadata and the app category; this is not a warning-free build claim.
