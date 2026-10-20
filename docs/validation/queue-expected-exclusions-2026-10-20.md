# Queue continuation after expected metadata exclusions

October 20, 2026. Validated source: `9581e48eba6d2b6115d3ca62b2849068ae0d309d`.

A queued transfer could stop for review even when every selected file verified and its only exclusions were the AppleDouble metadata files the user chose to ignore. That specific result can now advance to the next card.

Queue advancement is separate from permission to erase a card. Exclusions remain in History and reports, and the whole-card result stays conservative. This change does not grant a safe-to-erase verdict or automatic eject permission, or add another setting. Quick keeps its existing queue behavior; it cannot earn this new verified-exclusions qualification.

## What must pass

The engine must have recognized and validated the reviewed exclusions during the actual transfer. A filename starting with `._`, a row labeled excluded, or a collection of verified rows alone is not enough.

The final result must cover every selected file and every reviewed exclusion exactly once at every destination, match the captured source manifest and requested verification mode, and contain no failed, duplicate, missing or unexpected selected rows. Selected files must be independently verified. Requested MHL histories and reports must finish without error, and the terminal journal record must save successfully. Cancellation, interruption and excluded-only transfers cannot earn the qualification.

Projects also require matching saved project/card identities, enough independent verified copies, and successful project persistence. The conditional project check removes only the exclusions bound to the actual engine result; it does not relax the whole-card verdict. Unknown, missing or legacy qualifications stay blocked. Reload checks the saved scope and rows without requiring the processed source to remain connected.

## Regression coverage

There are 29 new cases: 10 engine tests, six queue integration tests, three identity/scope tests and 10 project tests. The existing Quick queue control is also explicitly required to pass.

The five transfer integration cases run the real copy/verification pipeline; the sixth checks legacy restore. They show a reviewed-exclusion card advancing to a completed next card, and still pausing for an existing MHL history, report-path conflict, selected-file conflict or journal failure. Conflicting bytes and source bytes are checked for preservation. The positive case checks the saved unsafe whole-card verdict, retained exclusion rows, MHL chain existence, and nonempty requested PDF, JSON and CSV files. These artifact checks are not a new visual PDF review.

The remaining cases exercise exact coverage, malformed typed results, absent engine provenance, unreviewed exclusions, changed manifests, missing or mismatched identities, insufficient project independence, failed persistence, stale results and legacy restore. A durable qualification is reloaded after removing the synthetic source, without promoting the saved safety verdict. Deliberately constructed unit fixtures are separate from the real-pipeline cases.

## Local results

All source and configuration hashes stayed stable across the seven core gates: 450 tracked files. The tested code includes the filename-safety changes from the preceding PR; this document describes only the queue policy.

| Run | Passed | Skipped | Failed | Count basis |
| --- | ---: | ---: | ---: | --- |
| Engine Debug, XCTest | 205 | 43 | 0 | 248 scheduled methods |
| Engine Debug, Swift Testing | 217 | 6 | 0 | 223 reported tests, 40 suites |
| Engine Release, XCTest | 205 | 43 | 0 | 248 scheduled methods |
| Engine Release, Swift Testing | 217 | 6 | 0 | 223 reported tests, 40 suites |
| Full Mac app suite | 1,301 | 23 | 0 | 1,324 total |
| iPad simulator suite | 75 | 10 | 0 | 85 total |
| iPhone simulator suite | 75 | 10 | 0 | 85 total |
| Mac import-review layout capture | 1 | 0 | 0 | One opt-in hosted layout test |

The 10 new engine cases passed in both configurations. All 19 new app cases and the existing Quick control passed in the full Mac run. Debug and Release repeat the same tests; they are not additional unique cases. Opt-in tests skipped by the ordinary gates are not counted as passes.

Unsigned iOS-device arm64 and universal Mac arm64/x86_64 Release builds passed. A separate local universal diagnostic archive passed deep, strict signature verification with matching executable/dSYM UUIDs for both architectures. Existing signing settings were retained. The archive was not exported, installed, notarized or published. A universal build is not native Intel runtime coverage.

Structured results and raw-log runtime-warning checks were clear for the accepted runs. Compiler and toolchain warnings remain recorded separately; this is not an all-warnings-free claim.

## Retained controller failures and limits

Three optional mobile controllers failed auxiliary process-enumeration or settlement checks after a process-list query timed out. Their failed receipts remain failed. The iPad suite had already completed in the first attempt, and its actual passing test result was validated separately. The iPhone suite passed in a separate, bounded direct run on the same frozen source, with exact test counts, zero expected failures, stable source hashes and completed clone shutdown. That pass does not rewrite the earlier controller outcomes.

The import-review test produced four PNG captures: nine changes at the top, middle and bottom, and a short two-change review. All four were inspected. It checks compact sizing, reachable text, title padding and pinned Cancel/Apply buttons in a production `NSHostingView`/`NSWindow`. The initial wrapper expected `TEST SUCCEEDED`, while `test-without-building` printed `TEST EXECUTE SUCCEEDED`; the existing native result was revalidated as one pass without rerunning or editing the test. Both the failed wrapper receipt and the corrected validation remain retained. This was hosted layout evidence, not a native file-picker, button-action or applied-settings walkthrough.

These queue cases use tiny, owned host fixtures. They do not establish physical mobile-device behavior, every drive/camera combination, or the cause of issue #10 or #23. The separate large physical HFS+ follow-up was unfinished at this checkpoint and is not counted as a pass here. Nothing in this validation is a release announcement.

