# 0.2.11 release validation

**Status: in preparation, not released.** 0.2.11 is being cut from the current `main`. The October 21 candidate (`f74d8c7d`, tagged `v0.2.11` and held in draft) was retired on October 22 without publication; its evidence is kept in [RELEASE_0_2_11-candidate-f74d8c7d.md](RELEASE_0_2_11-candidate-f74d8c7d.md) and remains valid for the engine behaviour it tested, which is unchanged on `main`. Publication needs fresh approval after the gates below pass. The latest public release is `v0.2.10`.

Base for this record: `main` at `4dbe8f9e` (October 22), which contains everything merged since `v0.2.10`. Local validation uses the Xcode and Swift versions recorded in the candidate record. GitHub Actions remains intentionally disabled; its absence is not a test result.

## Scope

Everything under 0.2.11 in the [changelog](../../CHANGELOG.md). In short:

- Reliability and evidence: stricter backup-independence counting, out-of-space destinations pause for the rest of the attempt, one re-copy after a failed readback, failed files renamed `.bitmatch-failed` and explained in History, drive discovery and card checks off the main thread, diagnostic exports count dropped events, lower PDF memory use.
- Check: classic MHL 1.1 content checks, MD5-only and SHA-1-only inventories, conflicting-date rejection.
- Visual polish ([spec](../superpowers/specs/2026-10-21-visual-polish-design.md), PRs #83, #84, #86, #87, #88, #89, #90): collapsed repeated attempts and a working Remove from queue; the safe-to-erase hero with backups by volume and folder and eject carried through to Removed; the rebuilt queue row; the Mac tab strip kept in History, a bottom action bar and content-following window height; card and backup vocabulary; one motion system; spacing, radius, text-style and iOS tint tokens.

## Gates completed on `main`

| Gate | Result | Where |
|---|---|---|
| Full Mac suite, `./test.sh mac-test`, at `44a67ef6` | TEST SUCCEEDED: 1,208 Swift Testing tests in 113 suites, 352 XCTest executed (33 skipped), 0 failures | Run October 22 under the shared-container test lock |
| iPad/iPhone build, `./test.sh ipad-build`, at `44a67ef6` | BUILD SUCCEEDED | Same run |
| Per-step suites during the polish PRs | Each PR's full Mac suite and iPad build passed in its own worktree before merge (1,202 / 1,205 / 1,208 tests for steps 5–7) | PR bodies #83–#90 |
| Independent review of the polish PRs | Task reviews, scoped re-reviews, one Opus whole-branch review and one fix wave per branch | SDD ledgers were kept in the merged worktrees and are deleted; rulings are summarised in the PR bodies |
| Engine validation for the reliability changes | Focused records exist for the re-copy, out-of-space pause, assurance audit, drive access, failed-readback marking, diagnostic recorder contention and blocked-drive work | [recopy-2026-10-21.md](recopy-2026-10-21.md), [space-pause-2026-10-21.md](space-pause-2026-10-21.md), [assurance-audit-fixes-2026-10-21.md](assurance-audit-fixes-2026-10-21.md), [drive-access-review-2026-10-21.md](drive-access-review-2026-10-21.md), [failed-readback-marking-2026-10-21.md](failed-readback-marking-2026-10-21.md), [diagnostic-recorder-contention-2026-10-21.md](diagnostic-recorder-contention-2026-10-21.md), [blocked-drive-2026-10-21.md](blocked-drive-2026-10-21.md) |
| Debug-build live checks of the polish | The collapsed-attempt row, Remove from queue, the new row and paused strip, the Check and Master Report action bars, the tab strip persisting in History, narrow-window stacking and Window ▸ Fill were observed on Debug builds of the branches | PR comments on #86 and #87 |

## Gates still open before tagging

These are the checks automation could not perform. Each must be recorded here with the build it was run on; an unobserved item is written as a limit, never omitted.

1. **In-person UI checks on a signed candidate.** VoiceOver reachability of waiting rows' Edit, Move and Remove; Return while a text field is focused but untyped; Return with a project card prepared; zoom, tiling and full-screen exit holding the window fit; the iPhone overflow-menu hit area; motion during a real transfer; iOS light mode; Increase Contrast.
2. **Signed-app native walkthrough** on the new shell: window hide/reopen, Quit settlement, Dock badge and icon, a real card inserted and removed, Remove from queue and the eject carry-through on a physical card. The earlier walkthrough in the candidate record was on the previous shell.
3. **Physical evidence for the reliability changes** where the focused records above relied on synthetic fixtures: the out-of-space pause and the one-shot re-copy on real drives, following [HARDWARE_TESTING.md](../HARDWARE_TESTING.md) and recorded with [HARDWARE_REPORT_TEMPLATE.md](../HARDWARE_REPORT_TEMPLATE.md).
4. **Release build**: `Scripts/release_mac.sh` at the final commit, then tag `v0.2.11` there, draft, approval, publish, `Scripts/publish_appcast.sh`. The Sparkle minimum and the macOS 15.5 floor are unchanged.

## Known limits carried into this release

- Sudden power loss remains untested; an OS flush is not a durability guarantee.
- Field reports #10 and #23 remain open; no fix is attributed to them without evidence.
- Physical iOS, real-device VoiceOver and native Dock behaviour were not observed on this code yet (open gates above).
- Three Mac tests are load-sensitive under concurrent test runs (MainScreenQueueTests editCancel, SFTPRemoteBackupProcessTests cancellation, SharedSelectionTests supersededScan); they pass alone and under the test lock. They are not release blockers but should not be read as flakes in CI, which is disabled.
- Visual follow-ups not in this release: History's first-six stagger, the drive plug-in slide, per-destination verify fractions in the row.
