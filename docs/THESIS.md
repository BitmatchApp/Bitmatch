# BitMatch thesis

Confirmed by Mike, 2026-09-25.

> **BitMatch is a free, open-source card-offload tool: plug in a card, pick your backups, and walk away knowing — with evidence you can hand to anyone — that every backup is a complete, verified copy before you wipe the card.**

Every feature, screen, and refactor should make this truer. When a change is hard to judge, check it against the promises below.

## Promises

1. **The card is sacred.** The source is never modified. Nothing on a destination is overwritten. A partial copy never looks complete.
2. **Green means verified, red means real.** Success only when every file on every backup verified. No false greens, and no false alarms (a Finder `.DS_Store` is not a difference; see GitHub #8).
3. **The evidence matches reality.** Reports, ASC MHL, and history record exactly what happened, built from the same results the screen shows.
4. **Simple by default, powerful on purpose.** The everyday path is: choose a source, choose backups, copy and verify, review the outcome. Photographer jobs, folder recipes, SFTP, ASC MHL, and verification modes are first-class but opt-in; they never crowd the default path.
5. **One app everywhere.** Mac, iPad, and iPhone share the same engine, rules, and verdicts. Layout adapts; behavior does not. Mac-only exceptions (SFTP) are explicit.

## Coherence review, 2026-09-25

A read-only audit of the whole codebase against these promises found the safety core strong and the drift in the layers around it. Findings, in priority order:

- **P5:** Mac and iPad/iPhone are two UI shells over the shared engine. `CopyAndVerifyView`, `CompareFoldersView`, and `MasterReportView` each exist twice, with separate readiness checks. Only about 630 lines of view code are shared.
- **P2:** Operation state is tracked twice: `SharedAppCoordinator.operationState` (the displayed verdict) and `OperationStateService` (pause/resume, which can reject transitions). They can diverge.
- **P5:** macOS alone has `AppCoordinator` (676 lines), which mirrors shared state into five view models by hand. *(Step 3 deletes it; see below.)*
- **P4:** The Mac setup screen shows verification mode and the ASC MHL and report toggles at the top level.
- **Crust:** dead `OperationStateManager` and `MHLGenerator` (kept alive only by their tests); Swift 5 mode with partial strict-concurrency checking; Core Data for jobs next to a JSON journal for transfers; a file-system test stub copied into 7 test files.
- **Test gaps:** no Mac-vs-iOS verdict-parity test; no whole-source-tree-unchanged test.

### Plan: converge, don't rewrite

Each step ships on its own.

1. Delete dead code; correct stale docs and comments. **Done 2026-09-25**: `OperationStateManager` and `MHLGenerator` are gone and the tests share one file-system fake. `ARCHITECTURE.md`, `README.md` and `DEVELOPMENT.md` describe `main` after steps 2–4.
2. Collapse operation state to one source, with the verdict derived from results. **Done 2026-09-25**, including the typed `ResultOutcome`.
3. Retire `AppCoordinator`: run Mac on `SharedAppCoordinator` as iPad and iPhone do. **Done 2026-09-25** ([plan](superpowers/plans/2026-09-25-retire-appcoordinator.md)): `AppCoordinator` and its four mirrored view models are gone, and the Mac adds only small companions for SFTP, volume access and camera auto-source (the drive estimate went with `DriveBenchmarkService`).
4. Merge the two UI shells one screen at a time, starting with Compare. **Wave 1 done 2026-09-25** ([plan](superpowers/plans/2026-09-25-ui-unification.md)): one Setup, Progress, Outcome, Compare, Master Report and History (Transfers) screen on every platform; one source and backup box component over one `TransferReadiness` rule, one `DestinationSelectionPolicy` and one `BackupTargetPolicy`; live progress and per-file results in `LiveProgressFeed` and `LiveResultsFeed`; time left from observed copy speed. **Wave 2 done 2026-09-25:** shared project presets (`ProjectSetupCard`), the per-transfer PDF on iPad and iPhone, and the [accessibility audit](audits/2026-09-25-accessibility.md) (except the items that need a VoiceOver pass on a device, listed in its status section).
5. Extract the engine into a Swift package; adopt Swift 6 strict concurrency. **Done 2026-09-25** ([plan](superpowers/plans/2026-09-25-engine-package.md), C01-C30): `Packages/BitMatchEngine` (about 6,300 lines, 99 tests of its own) holds `TransferPipeline`, `CardSource`, `DestinationWriter`, `ChecksumEngine`, `TransferJournal`, `EvidenceWriter`/`EvidenceReader`, `TransferCompletion`, `FolderComparer` and the safety rules; verification runs as structured child tasks; each run pauses only itself; the apps and tests build in Swift 6 with no warnings. The one `@Observable` app model is the remaining piece of the target shape.

Target shape: an engine package (`CardSource`, `DestinationWriter`, `ChecksumEngine`, `TransferPipeline`, `TransferJournal`, `EvidenceWriter`) tested against real folders, one `@Observable` app model whose verdict is computed from results, and one adaptive SwiftUI UI. Roughly 40k lines down to 20–24k, almost all of it from removing duplication rather than safety logic.

## Decisions, 2026-09-25

Mike delegated these to the recommendations; implementation plans should follow them.

**Verification (P2)**
- The overall verdict for a Quick transfer stays amber (already the case). Per-file rows say "Copied, not verified" without a green check, and a Quick Compare says "Sizes match, not verified" in amber.
- Paranoid means byte-by-byte comparison plus SHA-256, everywhere (copy, reuse check, and Compare), as the README says.
- The engine writes result text from one typed `ResultOutcome`, and the success rule reads it back through the same type, so the two cannot drift. Older saved text keeps the fail-safe "✅" rule; unknown text is never a success.

**Engine (step 5)**
- iPad and iPhone get a PDF report too (P3, P5). **Done 2026-09-25**: one `ReportPDFRenderer` on every platform. Page breaks never split a row and pages render one at a time (2026-09-26).
- Delete `DriveBenchmarkService`; estimate time from observed copy speed. **Done 2026-09-25** on branch `cloud/estimate-from-speed`: the benchmark, `TransferEstimateModel` and the iOS per-file-count guess are gone, so Setup shows no time estimate on any platform. The progress screen shows time left from measured copy speed across every backup, and "Estimating…" until two seconds of copying are measured.

**UI (step 4)**
- Compare blocks a same-folder or nested compare, and the mode switcher is disabled during any running operation on every platform.
- New transfer clears the source and keeps the backups. Retry and Export appear on the Mac completion screen.
- Cancel asks for one confirmation. The Mac prevents sleep while copying.
- Master Report uses a date picker, defaulting to today.
- One free-space rule everywhere: source size plus 1 GB.
- Choosing Project blocks Start until a card is prepared (the iPad rule).
- The Mac restores last-used backups at launch only when all of them are mounted.

**App state (step 3)**
- iPad and iPhone remember report and camera settings across launches, and use per-card camera-label memory, as the Mac does.
- The Mac's stricter readiness check applies on every platform.

**Step 2 scope additions** (found in the UI plan, section 8): clear `.resuming`; automatic pauses must pause the engine or not claim to; never report an estimated byte count as evidence (the 1,000,000,000 fallback).

## Must fix before the next release

- ~~Unexplained backup auto-add~~ **Resolved 2026-09-25.** Root cause confirmed on a Mac: the internal APFS system Recovery volume (`/Volumes/Recovery 2`, disk3s3, same container as Macintosh HD) was mounted and treated as a backup drive, so discovery and the launch restore offered it as a backup, including in the #8 screenshot. `BackupTargetPolicy` now guards every add path. Verified in the running app (a saved "Recovery 2" is no longer restored, and no new mounts at launch) and by `BackupTargetPolicyRealVolumeTests` against real paths.

## Follow-ups (not release blockers)

- ~~A NAS/SMB share root restored at launch may be refused when macOS does not report whether it is internal.~~ **Done 2026-09-25** (branch `cloud/backup-policy-followups`): a volume that reports itself not local (`volumeIsLocal == false`) is never treated as internal, so its root is restored at launch. Discovery still never adds a network share by itself. Not yet checked against a real NAS/SMB mount.
- ~~The source-card same-volume check is skipped if volume facts cannot be read.~~ **Done 2026-09-25**: with facts missing on either side, the mount the other side reports, or the `/Volumes/<name>` a path sits under, stands in for the volume. A target that looks to be on the source's volume is refused unless the facts that can be read show a fixed disk; the source drive's root is always refused. When neither side reveals a mount (for example two folders outside /Volumes), the pick is allowed and the overlap rule still applies.
- ~~Compare system volume names case-insensitively.~~ **Done 2026-09-25**: "RECOVERY", "recovery 2" and "macintosh hd - data" are system names too.
- (Fixed 2026-09-26) ARRI Mini LF from an ALE was named "Alexa LF"; ALE model names are now read regardless of case.
- (Fixed 2026-09-26) PDF page breaks could fall through a file row; reports now paginate by content, one page at a time.
