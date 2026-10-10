# Transfer details and File handling settings

Branch `feature/transfer-details`, based on merged #18 (`f09a629e`). No release was published.

## Behavior

Mac, iPad and iPhone share **Advanced → Transfer details**, collapsed by default. Operator and notes are optional; entered values are remembered until cleared. Each queued card retains its own snapshot. Expanded History and its PDF/CSV/JSON exports use that saved snapshot, not current preferences. Automatic reports and ASC MHL receive the same transfer settings. These strings are never added to structured diagnostics.

Reports omit an empty operator. MHL retains its original scope comment and adds entered details to that schema-compatible text field; XML markup is escaped and XML 1.0-unrepresentable controls are replaced with a replacement character. The chain C4 covers the resulting manifest. Media bytes, hashes, verification policy, destination readback and exclusive publication are unchanged; existing histories remain preserved. CSV detail fields neutralize spreadsheet formula prefixes without changing stored/JSON text.

`ReportPrefs` decodes absent fields with their original defaults, so older preferences and queued transfers retain their existing values. Tests cover older settings, remembered fields, independent queued snapshots, clearing, escaping, unsafe History exports, and a real app-executor transfer through PDF/CSV/JSON and MHL.

This is one set of details per transfer, not separate text for every destination. Destination-specific notes remain deferred.

## Local results — October 10

After resuming, AppleDouble handling moved from Advanced to Settings → File handling (General on Mac), with recognized-companion exclusion on when the preference is absent. Explicit saved false/true choices are retained. No zero-exclusion message is shown in setup; nonzero counts and evidence remain. Settings is disabled during execution/replay. Preview scanning participates in the existing analysing-source state; real scan errors still block Start. Tests cover preserving an older queued all-files policy even with the new live default, and replaying excluded selections without overwriting a saved preserve preference. The filter and extended-attribute handling are unchanged.

- Original Mac full suite: **1,087 passed, 10 skipped, 0 failed** (1,097 total). Optional capture tests account for the skips.
- Original iPad Air (M4), iOS 26.5 simulator: **63 passed, 5 skipped, 0 failed** (68 total).
- After compacting the operator line within the PDF summary, Mac focused evidence/History/capture run: **10 passed, 0 failed**. Final label/button styling was then captured separately on both targets: **1 capture test passed per target**, covering Mac and 320/500/820-point mobile layouts. Rendered images were visually inspected. The final three-test Mac History export run also passed; its generated PDF was rendered with Poppler and checked visually for the operator, notes and retained unsafe verdict.
- Engine XCTest: **123 cases, 15 skipped, 0 failures**, including the new MHL metadata/escaping/history-preservation checks. Swift Testing full run: **132 passed, 2 failed** out of 134. The two failures are existing timeout assertions in `cancellationMidBroadcastPublishesNothingAndReportsNoSuccess` and `testStalePauseDoesNotBlockNextOperation`; both pass in a separate two-test run (**2 passed, 0 failed**). A separate full Swift Testing run reproduces those same two failures. New metadata tests pass in all final runs. That earlier full run was red; the final resumed full-run result is below. No production transfer behavior was changed to satisfy timing assertions.
- Mac and iPhone/iPad Release builds: **BUILD SUCCEEDED** for both targets, unsigned local validation.
- `git diff --check`: clean.
- The first new journal relaunch test incorrectly opened two instances concurrently; corrected to release the real journal lock before reopening. The corrected test passes separately and in the full engine runs.

Logs, result summaries, xcresults and layout images are retained under `dist/validation/transfer-details`. PR #18's signed Mac walkthrough receipts remain in the primary checkout under `dist/validation/todo-reports`; it completed Standard copy/verify/MHL/reports on disposable APFS images, then exported History previews with the source ejected. Physical mobile keyboard/picker/share workflows were not exercised by the seeded rendering tests.

### Resume validation

- Final full Mac suite: **1,088 passed, 10 skipped, 0 failed** (1,098 total). Focused readiness, pause, AppleDouble, details and Settings capture run: **25 passed, 0 failed**.
- The initial resumed Mac run exposed three readiness failures (two Developer stress tests and the source-analysis parity test) caused by treating pending AppleDouble review as a blocker; corrected through the shared analysing-source state. That run also timed out in the automatic-pause test; it passes in the focused and final full runs. The initial log is retained.
- Final full iPad Air (M4) simulator suite: **63 passed, 6 optional captures skipped, 0 failed** (69 total).
- Settings render capture: **1 passed**, producing 320/500/820-point mobile layouts; all three inspected without clipping. Mac Settings section was also rendered and inspected.
- Final resumed Mac and iPhone/iPad Release builds: **both BUILD SUCCEEDED**, zero compiler errors.
- Final engine rerun after app builds completed: **XCTest 123 cases, 15 skipped, zero failures; Swift Testing 134 tests passed, zero failures**. The earlier timing failures and isolated runs remain documented above; the final full package gate is green. Real exFAT destination publication/transfer tests passed in this run.
