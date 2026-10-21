# Drive UI and combined reliability validation — October 21, 2026

## Source and scope

Production source is `da44a47a`; `9e9b6621` adds test-only readiness waits. Its parent PDF correction is `1a7c42d7`. This source includes the reliability, source-diagnostics and reused-file-progress work from PRs #79–81, the PDF memory changes, diagnostic writer failure details, and the bounded drive-access work. Mike authorized merging the reviewed work; release publication remains on hold.

Filesystem calls made while presenting queue rows, selecting folders, restoring Mac backups, reconnecting History locations and preparing transfers now run through bounded background work. Presentation reads cached labels, capacity, readiness and source-availability hints. Final admission and eject still validate the original resources; the cache never authorizes an operation. Accepted journal mutations return their actual durable result despite UI-task cancellation. The mobile bottom Start control uses the same prepared admission path as Setup.

The worker allows two active and eight queued jobs and reserves all lexical mounts involved in a job. Cancellation settles a caller without pretending that a synchronous filesystem call has stopped: its reservation remains until the call returns. An original-resource snapshot is checked before a queued journal read resolves bookmarks, so a changed record cannot redirect work to an unreserved location.

## Executed local checks

All builds/tests ran at low process priority, with one scheduled BitMatch gate at a time, Xcode jobs limited to one and parallel test scheduling disabled. The approved host free-space floor was 15 GiB. GitHub Actions was not used.

| Gate | Actual result |
| --- | --- |
| Engine XCTest, `engine-xctest` | 334 total, 83 skipped, zero failures; 76.985 seconds of tests, 165.195 seconds including the fresh build. All three prepared-resource tests passed, including rejection of a changed journal snapshot. Disposable exFAT image checks ran; external user drives were not used. |
| Engine Swift Testing, `engine-swift-testing` | 267 tests in 41 suites passed; 31.398 seconds of tests, 35.062 seconds total. |
| Focused Mac workflow rerun, `mac-focused-7` | 84 passed, zero failures/skips. Covers AppleDouble workflow, backup admission, worker scheduling and queue integration. |
| Full Mac, `mac-full-3`, `9e9b6621` | 1,456 passed, 35 skipped, zero failures; 1,491 total definitions. Total gate time 95.091 seconds. Parameterized executions are not additional test definitions. Opt-in tests skipped here are separate from the selected scale probe below. |
| Mixed PDF scale, `mac-pdf-mixed40k`, production `da44a47a` | One actual test, zero failures/skips; 18.033 seconds of tests. 20,000 synthetic files / 40,000 result rows, 10% long wrapped paths, Unicode and mixed verdicts. Peak 143 MiB under the unchanged 1,024 MiB guard; no deadline or sampling failure. 1,513 pages, 8,902,166 bytes. |

Independent extraction checked every PDF manifest row: each file appeared once for Backup 1 and once for Backup 2, with the expected status and retained filename content. Totals were 36,000 verified, 2,000 failed and 2,000 copied-but-unverified glyphs. The report intentionally describes mixed outcomes; generating it is not a successful-transfer verdict. Pages 1, 757, 1,512 and 1,513 received visual inspection. The [PDF record](report-memory-2026-10-21.md) retains hashes and the earlier failed baselines.

**iPhone/iPad generic simulator build-for-testing passed** (`ios-build-for-testing`), including the app and test target for arm64 and x86_64; 185.146 seconds total. This compiles the shared changes, mobile Start path and mirrored PDF tests. It is not simulator test execution, a physical-device test or a signed-app walkthrough.

## Failures retained and corrected

- The first Mac build/test compilations exposed callback argument order, obsolete trailing-closure labels and a MainActor test-helper isolation error. Those were corrected before runtime checks.
- `mac-focused-3` ran 262 tests: 256 passed and six failed. The failures exposed async setup expectations and a directory-form URL mismatch in an injected held-probe fixture. Subsequent focused runs retained the original safety assertions and waited for their actual completion conditions.
- `mac-full-1` ran 1,491 definitions: 1,450 passed, six failed and 35 skipped. `mac-full-2` had 1,452 passes, four failures and 35 skips. These remain failed runs. The final corrections wait for actual readiness, worker retirement and engine admission rather than assuming those asynchronous steps finish synchronously or within a two-second setup window. The final full run above passed.
- The native wrapped-row assertion initially required PDFKit's selected text to contain `…`. The saved page visibly contains the ellipsis, but PDFKit omits Core Text's truncation token from selection text. Mac and iOS tests now normalize whitespace before rejecting the full untruncated filename; row-local Unicode, retained ends, measured height and overlap checks remain. Literal glyph appearance was checked visually, not inferred from text extraction.
- Review found and corrected two production omissions: mobile bottom Start still used the synchronous compatibility path, and three prepared journal reads could resolve a newer resource snapshot under older mount reservations.

## Evidence and limits

Private receipts, logs, result summaries, source hashes, the independently checked PDF and representative page images belong to evidence run `20261021-drive-ui-a9352519-e12b-4091-9bae-17a1cd1cf044`. They are local validation artifacts, not user footage or public telemetry.

The tests cover disposable folders, controlled held workers, original-folder replacement, cancellation and durable admission. They do not establish a deadline for a blocked OS call, prove physical-device independence from lexical paths, or measure responsiveness against a genuinely wedged removable drive. Compatibility APIs retained for tests/internal callers are not a claim that every synchronous filesystem API was removed.

The prior 20,000-file coordinator report-off/on workflow passed on `5eb7ac09` before the wrapped-row change; it is separate from this final mixed-PDF check. A new combined coordinator scale run, large physical app workflow and signed/device walkthrough remain follow-ups. The earlier physical Thorough source-stability rejection remains unexplained. Field issues #10 and #23 remain unresolved; these synthetic results do not attribute or close either report. No release, tag, signing/notarization, updater, Homebrew or Actions change is authorized here.
