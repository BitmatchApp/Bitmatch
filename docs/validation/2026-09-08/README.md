# Simpler transfers, ASC MHL, and local recovery

Source validation on 2026-09-08, on the working tree based on `f0c96a7` containing the changes committed with this report. Host: Apple Silicon, macOS 26.6, Xcode 26.6 (17F113). This does not describe the downloadable v0.1.4 binary.

## Automated checks

- macOS unit and integration suite: `bash test.sh mac-test` — exit 0. **484 tests passed, 0 failed, 1 skipped** (the opt-in soak test). Parameterized cases produced 503 passing runs. [Recorded summary](test-summary.json).
- Shared mobile target: `bash test.sh ipad-build` — exit 0; builds for both iPhone and iPad simulators.
- Mac interface compilation: `bash test.sh mac-build` — exit 0. The final Mac test run rebuilt the app after report changes; a subsequent Mac build also passed after connecting the queue sheet to the current report preferences.
- [ASC reference validation](../ascmhl/README.md): official schemas, rehashing, chain digests, a reference-generated second generation, and deliberate corruption.

New coverage includes independent queue settings, two real card copies with independent SHA-256 checks and persisted outcomes, interrupted-attempt recovery, cancellation, unavailable destinations, corrupt history, competing journal writers, project retry restrictions, full-result exports, and preserving verified local evidence after a handoff issue. ASC tests reject incomplete inventories, changed files, existing histories, unsafe paths, and source overlap.

## Visual checks

Mac setup was checked at 680 points and around 1,000 points wide. The README screenshot at the time showed a real source containing 12 disposable text files and two local scratch folders, before copying. The [Mac queue form](mac-add-transfer.png) was checked at 480 points wide after correcting its missing padding.

The shared Transfers screen was opened through each platform's navigation on an [iPhone 17 Pro simulator](iphone-transfers.png) at 402 points wide and an [iPad Air simulator](ipad-transfers.png) at 820 points wide. Advanced verification settings and the queue form were also inspected. These are simulator layout checks, not physical-device transfer tests. A complete live mobile offload and iPad multitasking layout check were not performed.

A live Mac Standard copy transferred the 12 disposable files to two scratch backups. All **24 copies independently matched** their source bytes. The [completion screen](mac-completion.png) showed one verdict and both destination summaries at 680 points wide; PDF, CSV, JSON, and checksum reports were produced. [Recorded file check](live-copy-evidence.json). The saved journal confirms ASC generation was disabled for this live run, so its ASC coverage comes from the separate executor, real-file paranoid, and official reference tests.

## Scope

The local queue is sequential. It stops on issues and waits for the user to resume. Recovery starts a new attempt using the original folder identities; it does not claim to resume at a byte offset. Existing verified destination files are rechecked by the copy engine. A project card must be reviewed and prepared in its project before another ingest.

ASC support creates initial destination inventories. It does not import or extend existing histories. The separate retry option disables new ASC generation while preserving those histories. Generating an inventory reads the destination again and can add substantial time on slow storage.

Physical iPhone/iPad storage, card readers, drive disconnects on a real hub, and interoperability with commercial DIT applications remain untested. Simulator checks do not establish unattended iOS background transfer support; keep BitMatch open.

[Follow-up layout cleanup](layout-cleanup/README.md) records the compact Mac setup and consistent mobile headings, including a narrow iPad window check.
