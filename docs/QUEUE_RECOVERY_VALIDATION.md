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

A signed release walkthrough and physical iPhone/iPad access/background testing remain release checks. No release was published by this change.
