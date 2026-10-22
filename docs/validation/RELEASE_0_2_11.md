# 0.2.11 release validation

**Status: released October 22, 2026.** Cut from `main` at `a4974c10` (0.2.11, build 22) after the gates below. The October 21 candidate (`f74d8c7d`, tagged `v0.2.11` and held in draft) was retired without publication; its evidence is kept in [RELEASE_0_2_11-candidate-f74d8c7d.md](RELEASE_0_2_11-candidate-f74d8c7d.md) and remains valid for the engine behaviour it tested, which is unchanged. The exFAT sidecar question in the limits ships as a known behaviour of the non-default setting.

Base for this record: `main` at `e84aba44` (October 22), which contains everything merged since `v0.2.10`. Local validation uses the Xcode and Swift versions recorded in the candidate record. GitHub Actions remains intentionally disabled; its absence is not a test result.

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

## Gates completed on the signed candidate (October 22, build 22)

The candidate was a Developer ID signed Release archive of `main` at `e84aba44` (0.2.11, build 22; sandbox entitlement present, `codesign --verify` clean), launched as the only BitMatch instance. It was not notarized; see the open gate below. Physical hardware: the Sony SD card mounted as `Untitled` (exFAT), the Samsung T9 (exFAT) and the WheeDrive (exFAT), all on this Mac, plus two exFAT disk images on the WheeDrive for the out-of-space runs. Screenshots were taken after each action; the numbers below come from the app, the transfer journal and the diagnostics log.

| Check | Result |
|---|---|
| Three-disk physical matrix, `Scripts/test-physical-drives.py` | Passed on the same three drives, before the signed walkthrough ([physical-three-disk-2026-10-22.md](physical-three-disk-2026-10-22.md)) |
| Queue row controls on the signed build | The ⋯ menu and the expand chevron did nothing on the first candidate (`58931a93`): the motion step's commit-flash and hover overlays were filled shapes at zero opacity and swallowed every click. Fixed in `e84aba44` (`allowsHitTesting(false)` on the decorative layers); on the rebuilt candidate the menu opened (Skip and continue / Remove from queue / Export), Remove from queue asked "Remove … from the queue?" and removed the row, and the chevron expanded and collapsed the row. Full Mac suite and iPad build green on the fix. |
| Real card to two backups | SD card fixture (28 files, 2.01 GB, no sidecars) to T9 and WheeDrive, Standard mode: running row showed "Copying to T9, WheeDrive · 2.01 GB" with the fill advancing, then "Verifying T9 · 1 of 2 backups"; finish hero "BitMatch-walkthrough-20261022 is safe to erase. 28 files read back from both backups and matched to the card. 7s" with a green "Safe to erase" pill; journal `completed`, 56 verified rows, 2 independent destinations; SHA-256 of one clip cross-checked by hand on the card and both backups (`f6e18023…`). |
| Eject carry-through | Eject on the hero: "Ejecting…" then "Removed" once the card left; the reader released the card fully (it is no longer listed by diskutil, so it must be re-inserted). |
| Out-of-space, pre-flight | A 64 MB volume: the bar read "Insufficient space on BMSMALL" and Start stayed off. A 3.6 GB volume filled by another writer between readiness and Start: the engine refused at preparing with an alert "Insufficient space: 2.7GB available, 3.0GB required", the journal recorded `interrupted` with that text, the row paused with "Keep the card", and the "keep the card · Do not erase the card." banner appeared. While the modal alert was up the row read "Copying 1 card" with no controls; it settled the moment OK was pressed. |
| Out-of-space, mid-attempt | Retry from the Review panel with the filler started after pre-flight: the first ENOSPC (POSIX 28, one diagnostics error event) paused BMMID for the rest of the attempt; its three remaining 600 MB clips were recorded as failed with no further write attempts, WheeDrive finished with 29 verified. Row: "Paused 12:29 AM · 3 files failed on BMMID"; Review listed the three clips and "WheeDrive › … 29 verified, 0 unverified, 30 intentionally excluded" and "BMMID 3 files failed"; Copy Summary: "needs attention: 3 files failed on BMMID · do not erase the card". The out-of-space reason itself is not shown anywhere in the app (see limits). |
| Queue collision guard | Starting the T9 copy of the fixture while the finished card of the same name was still in the queue was refused: "Two cards in this queue use the same or nested output folders … Nothing was copied for this attempt." Clear finished, then the same start was admitted. |
| Recreated volume | After a backup volume was detached and recreated with the same name, the bar read "Reconnect or reselect BMMID. Its original folder could not be confirmed." and Start stayed off until it was re-added. |
| Window fit, zoom, History, hide | Window ▸ Zoom filled the screen (1800×1130) and a second Zoom returned to exactly 1000×820; expanding Advanced grew the window to 966 and collapsing the row shrank it back; History kept the tab strip, the back arrow, "Search cards, clips, or backups" and the diagnostics footer, and returning to Copy & Verify refit the window; Cmd+H hid and reactivating reopened the window with state intact. |
| Return in a focused, untyped field | Return in the Custom label field with a card chosen started nothing (journal unchanged). |
| Quit | Cmd+Q with a paused row and nothing running quit at once (idle-quit rule). |
| AppleDouble sidecars from an exFAT card | With "Ignore AppleDouble metadata files" turned off (it had been switched off on this Mac during earlier testing; the shipped default is on), copying the SD fixture with 26 `._` companions to two exFAT backups failed every sidecar row: 52 "Failed", journal summary "52 files failed; T9: 26 files have no result; WheeDrive: 26 files have no result", one Cocoa error 516 (file exists) per destination, while all 50 media rows verified. The backups' exFAT driver creates its own `._` companion when the media file lands, and the engine refuses to overwrite it. With the option on, the same card copied with "26 AppleDouble files intentionally excluded" and selected files verified. Not re-tested on 0.2.10; recorded as an open question below. |
| iOS light mode, Increase Contrast | iPhone 18 Pro simulator, light appearance: tokens render; Increase Contrast showed no visible change on the empty Setup screen. |

## Release build

`Scripts/release_mac.sh 0.2.11` at the release commit: signed, notarized and stapled DMG with its `.sha256`, smoke-tested once from the archive, then tag `v0.2.11`, GitHub release as Latest, `Scripts/bump_cask.sh 0.2.11`, `Scripts/publish_appcast.sh 0.2.11`. Results are appended below.

## Known limits carried into this release

- Sudden power loss remains untested; an OS flush is not a durability guarantee.
- Field reports #10 and #23 remain open; no fix is attributed to them without evidence.
- Not observed on this code: VoiceOver reachability of waiting rows' Edit, Move and Remove; Return with a project card prepared; full-screen exit; the iPhone overflow-menu hit area on a device; physical iOS; the Dock badge count (the banner was observed, the badge was not checked); Quit while a transfer is running.
- When a backup runs out of space the app says "N files failed on <backup>" but never "out of space": the engine attaches the reason to each failed file result and `TransferCompletion.row(from:)` drops it when building the journal row. Tracked in [TODO](../TODO.md); the POSIX code reaches the diagnostics export.
- A modal error alert (for example the pre-flight space refusal) leaves the queue row reading "Copying 1 card" with no controls until the alert is dismissed.
- The signed walkthrough used synthesized clicks on an idle desktop while another session's test apps repeatedly took focus; every observation above was confirmed from the app's own state (journal, diagnostics, accessibility tree), not from screenshots alone.
- Three Mac tests are load-sensitive under concurrent test runs (MainScreenQueueTests editCancel, SFTPRemoteBackupProcessTests cancellation, SharedSelectionTests supersededScan); they pass alone and under the test lock. They are not release blockers but should not be read as flakes in CI, which is disabled.
- Visual follow-ups not in this release: History's first-six stagger, the drive plug-in slide, per-destination verify fractions in the row.
