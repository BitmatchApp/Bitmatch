# Issue #10: exFAT handoff and interruption diagnostics

## Scope

[Issue #10](https://github.com/BitmatchApp/Bitmatch/issues/10) reports 0.2.1 stopping near verification/reporting, with a Samsung T7 (HFS+ Journaled), a USB dock, and a LaCie exFAT HDD. The reporter recalls the app remaining open and displaying cancellation. There is no crash report. Neither a process crash nor automatic SwiftUI task cancellation has been established.

This patch starts from `origin/main` at `f7597243`. The changes since the reviewed release `4bdeb183` were documentation and screenshots; no intervening engine fix addressed this path. Work is isolated on `fix/issue10-exfat-handoff`. No release, signing credentials, updater feed, or source media were changed.

## Reproduced locally

On macOS 27.0.1 (26A434), arm64, Xcode 27.0 (27A266a), a disposable mounted 3 GiB sparse exFAT image returned:

```text
real_exfat_directory_RENAME_EXCL rc=-1 errno=45
 direct_mhl_failure domain=NSPOSIXErrorDomain code=45 swiftCancellation=false taskCancelled=false
 copy_passed=true mhlIssues=[ASC MHL: Operation not supported] taskCancelled=false
```

The original direct-generation test failed, and the Standard copy/readback → MHL test failed its handoff assertions: 2 tests, 3 assertions/errors. Media copy and independent destination readback succeeded. This confirms an exFAT publication incompatibility. It does **not** reproduce the reporter's cancellation: the ordinary publication error becomes a handoff issue, not a CancellationError. Whether ASC MHL was enabled in the reporter's run also needs confirmation.

The supplied tests were reviewed and extended: they now assert the mounted filesystem type, check source bytes are unchanged, observe progress, test existing histories and publication interruption, and cancel during an actual destination reread. Setup failures fail tests instead of silently skipping them. Teardown detaches without force and never deletes a still-mounted image. No issue-10 images remained mounted after validation.

## Publication contract

The fast path remains `renameatx_np(RENAME_EXCL)`. Only unsupported-operation errors take the fallback:

1. Write and synchronize the complete manifest and chain in a private staging directory relative to the pinned destination descriptor.
2. Exclusively reserve `ascmhl` with `mkdirat`. Any existing file, symlink or directory at that name refuses the reservation.
3. Check cancellation, source separation and the reservation's directory identity.
4. Rename the staging directory over that owned empty reservation. A directory rename cannot replace a nonempty history. No public history is populated file by file.

An interruption before step 4 can leave an empty `ascmhl` reservation; it has no manifest or chain and is never reported as complete. A later attempt refuses it rather than guessing that it is safe to delete. Review an interrupted reservation before retrying. A process death can also leave a hidden staging directory. The patch does not automatically recover or delete these artifacts.

Real-exFAT tests prove successful handoff, refusal of an existing history, preservation of a file added inside the reserved directory before publication, and absence of a complete history after interruption. The source remains untouched. Destination readback and checksum/identity validation remain mandatory.

## Progress

ASC MHL emits processed bytes and file counts while reading destination media, and a separate publication-complete signal. exFAT still rereads with `F_NOCACHE`; the APFS/HFS readback-evidence reuse policy is unchanged. The shared UI labels this phase “Creating ASC MHL,” shows phase progress below 100% until publication, and switches to report-writing progress afterward.

The executor consumes a bounded, latest-value stream and drains it before reporting terminal state. Late pipeline progress is ignored after the pipeline returns, so it cannot overwrite the MHL phase. Publication progress is not a safety verdict; completion still requires the existing coverage, verification, handoff, report and project gates.

## Cancellation paths

| Entry | Diagnostic evidence | Outcome/history |
| --- | --- | --- |
| Confirmed Cancel button | `explicit_cancel`, origin `user` | Cancelled; partial results retained |
| Mac cancel menu/shortcut | origin `menu` after confirmation | Cancelled |
| Confirmed window close or app quit | origin `windowClose` or `appQuit`; settlement awaited | Cancelled; durable journal before exit |
| Parent task cancellation | executor cancellation handler; error kind and task flag | Interrupted history unless an explicit request was recorded |
| Authoritative-results owner released | `authoritativeRefused`, code 1; typed `TransferInterruption` | Interrupted; never successful handoff |
| Authoritative-results run replaced | `authoritativeRefused`, code 2 | Interrupted |
| Authoritative-results explicit-cancel guard | `authoritativeRefused`, code 3, explicit=true | Cancelled |
| Manually thrown CancellationError without explicit request | `kind=CancellationError`, task flag can be false | Interrupted, not labelled user cancellation |
| MHL/report cancellation | Forwarded into owned detached work and rethrown | Same explicit-versus-unexpected policy |
| Comparison/saved-check cancellation | Explicit comparison flag versus task interruption | Cancelled only for an explicit request; otherwise failed interruption |
| Relaunch after unfinished journal entry | Existing recovery rule | Interrupted; no claim that a crash was observed |

`TransferPipeline` already forwards caller cancellation into its owned operation task. Verification children settle before the final cancellation/coverage checks. The patch does not infer cancellation from the fact that a caller used `Task {}`. An ordinary MHL/report failure still downgrades completion to issues. Queue processing stops on interruption, and retained verified rows do not make an interrupted transfer safe to erase.

## Privacy-safe diagnostics

Existing free-form messages remain private. New persisted notice/error events expose only closed-vocabulary phase/reason values, random operation UUIDs, enumerated filesystem types, flags and numeric error codes. No footage filenames, paths, labels, hostnames, bookmarks, production notes or localized error descriptions enter these public fields. An early pipeline mapping links the executor run UUID to the engine UUID, including runs that never complete.

Error domains/types are classified as `CancellationError`, `identity_guard`, `POSIX`, `Cocoa`, or `other`; arbitrary error-domain strings are not made public. Phase, publication errno, explicit-cancel origin, parent-cancellation and journal-terminal events are recorded. Chunk-level events are not logged.

For a controlled diagnostic run, collect only the structured events:

```sh
/usr/bin/log show --last 1h --style compact \
  --predicate 'subsystem == "com.bitmatch.app" AND eventMessage BEGINSWITH "event="' \
  > bitmatch-issue10-events.txt
```

Review the output before sharing. Do not send the full transfer journal or a broad log archive: those can contain paths and bookmarks. Structured events were observed unredacted through `log show` during local tests.

## Validation

- `swift test --package-path Packages/BitMatchEngine`: 87 XCTest tests, 4 opt-in skips, 0 failures; 123 Swift Testing tests in 26 suites passed. All 7 issue-10 real-exFAT tests passed. Existing ASC MHL/readback and safety tests also passed.
- `bash test.sh mac-test`: full app suite passed; 1,059 tests in the xcresult summary, 1,057 passed, 2 skipped, 0 failures. Parameterized invocations account for the separate device count. New coverage includes unexpected CancellationError, parent-task cancellation, authoritative identity rejection, explicit cancellation, MHL progress and interrupted journal persistence. Existing report-failure, successful MHL, queue continuation and exit-settlement tests passed.
- `bash test.sh mac-build`: passed.
- `bash test.sh ipad-build`: passed for the shared iPhone/iPad simulator target.
- `git diff --check`: passed.

The engine skips are the opt-in buffer benchmark, real-copy benchmark, sparse-large-file stress and soak. App skips are the source-tree metadata filesystem case and opt-in workflow snapshots. These skips are not claimed as passes. A pre-existing engine warning about `FaultInjectingFileSystemService` restating inherited `@unchecked Sendable` remains outside this change.

An initial Mac build needed the new engine-type import in `BitMatchApp`; this was corrected. One overlapping iOS build saw a stale engine module while the diagnostic task-local type was being added; the final build after source changes settled passed. Final build/test logs and the xcresult are retained locally.

## Diagnostic build and limits

`bash test.sh mac-build` produces the local Debug diagnostic app, copied to `dist/issue10-diagnostic/BitMatch.app` and zipped alongside the validation logs. It is **unsigned and unnotarized**, intended for local diagnostics. It is not the signed distribution build and has not been sent to the reporter. No signing credentials were changed or release services invoked.

Disk-image tests do not simulate the reporter's dock, cables, physical disks, sleep, disconnects or filesystem damage. The reporter's exact cancellation remains unexplained. The next evidence should come from a controlled run with noncritical copied media and the new structured events, followed by an approved signed diagnostic build if needed. Do not close issue #10 solely on this reproduction.

## Closer HFS+ → exFAT synthetic run (follow-up)

`bash Scripts/test-issue10-filesystem-pair.sh` provisions two disposable 3 GiB sparse images outside the app test host, one **journaled HFS+** source and one **exFAT** destination. The test asserts both actual mounted filesystem types and the HFS journaling flag. It executes the real Mac file-access service and transfer pipeline through `CopyVerifyExecutor`, including Standard independent destination readback, ASC MHL handoff when enabled, report export and the completed-state callback.

The fixture contains 12 binary files: four each of 1 KiB, 1 MiB and 64 MiB (272,633,856 bytes). Two transfers run into fresh destination folders, with MHL off/on and reports enabled in both. Both completed successfully. All 12 rows per transfer were verified, CSV and JSON reports existed, the enabled MHL history had a chain, the disabled history did not exist, the MHL progress callback matched its setting, and independent SHA-256 checks confirmed unchanged source bytes and matching destination bytes. Exactly one completed state was published per run. No unexpected cancellation reproduced.

Final follow-up validation: **26 executor tests passed, 0 skipped, 0 failures**, including the full mounted-filesystem test. The preceding focused mounted-filesystem run also passed (2.233 seconds). Final xcresult: `.derived-data/mac-test/Logs/Test/Test-BitMatch-2026.10.01_14-06-16--0400.xcresult`; log: `/tmp/bitmatch-issue10-pair-suite.log`. The script detached both images without force and removed its disposable files. `bash -n` and `git diff --check` passed. No production implementation changed in this follow-up.

Initial fixture attempts failed before a transfer ran: the exFAT volume label exceeded its permitted length. These setup errors are not evidence of the reporter's cancellation. An initial cleanup script also needed correction to track successful attachments directly rather than matching `/tmp` mount strings against macOS's `/private/tmp` paths. The final script and cleanup were exercised successfully.

This is closer to the reported filesystem combination, but still a local SSD-backed disk-image test on macOS 27.0.1. It does not emulate Samsung/LaCie firmware, a USB dock, HDD latency, disconnects, the original footage or the reporter's exact macOS 27.0 build. MHL/report settings and original workload are unknown. The confirmed exFAT publication bug is fixed in this branch; the reporter's unexpected cancellation is still a hypothesis requiring diagnostic evidence. Keep issue #10 open.

## 0.2.2 diagnostic export

The release candidate adds a shared History → Export diagnostics action on Mac, iPad and iPhone. Only the existing typed structured events enter the persistent record; free-form logs remain private and are never copied into the export. Event names, phases, error classifications, filesystem types and cancellation origins are closed enums. The record includes app/build versions and session/run IDs, verification mode, phase transitions, first file error, MHL publication errno, terminal journal events and numerical progress sampled at most once every ten seconds when updates arrive. It stores two rotating files of at most 256 KiB each in the app's Application Support directory. No automatic upload is implemented.

Persistence is lock-serialized and flushed for sparse events. A damaged last line is isolated so a new session can continue recording. Recording failures do not throw into the transfer; the export reports recording errors and malformed records. Six new engine tests cover reopening, rotation, truncated records, failed storage, concurrent writes and exclusion of filenames/paths/error descriptions (including an arbitrary error domain and current-file progress string).

Validation: full engine suite passed (93 XCTest tests, 4 opt-in skips, 0 failures; 123 Swift Testing tests passed); full Mac suite passed (1,060 total, 1,057 passed, 3 skips, 0 failures); the real journaled-HFS+ → exFAT executor suite passed (26 tests, no skips/failures). Mac History snapshots passed. Both dedicated iPhone/iPad History captures and the corrected full mobile snapshot capture passed (2 tests, no skips/failures). The normal iPad suite and iPad build passed. The original combined mobile capture failed because a reused fixture's bookmark target was missing; History now uses a fresh fixture, and the snapshot host uses the system background so light/dark text is rendered against the correct surface. This was a test-fixture correction, not evidence of a transfer failure.

Release candidate version: 0.2.2, build 11. Signed release preparation uses the existing Developer ID and notary profile, with no credential changes. Initial infrastructure failures were a lost connection to Apple's notary service, followed by a missing signing timestamp during a retry; dependency fetching also encountered connection resets. The final attempt uses the already pinned local Sparkle checkout, with automatic package updates disabled, through the same release script. Signing/notarization results are recorded separately from test results. Do not publish until final signature, notarization and signed-app walkthrough gates pass.
