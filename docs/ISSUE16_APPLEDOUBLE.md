# Issue #16: reviewed AppleDouble exclusions

Validated October 10, 2026 against `main` at `1c5c51ac`, on branch `fix/issue16-appledouble`.

## What was reproduced

The [report](https://github.com/BitmatchApp/Bitmatch/issues/16) asks for an exclusion toggle because transfers fail on `._*` files. It has no diagnostic attachment, filesystem details or comments yet. Its exact failing path remains unconfirmed.

On disposable mounted exFAT images, an initially empty backup acquired a companion during publication. The publication hooks observed `._clip.bin` absent before publication and present afterward. That macOS-generated file differed from the source's AppleDouble bytes. BitMatch refused the conflict, retained the existing file and verified the media independently. Repeated copies also refused it. This reproduces a failure mechanism, not the reporter's complete setup.

Overwriting or deleting the generated companion is not the fix: its ownership and metadata must not be assumed. The default preserves all enumerated source files and still refuses genuine conflicts.

## The optional policy

**Advanced → Exclude AppleDouble companion files** is off by default on Mac, iPad and iPhone. It reviews paired AppleDouble v2 containers, shows the count and an expandable list, and rechecks that exact list at Start before any destination writes. A changed review refuses the transfer. The format checks follow [RFC 1740](https://www.rfc-editor.org/rfc/rfc1740.html), with minimum lengths for fixed-size metadata entries. Filename prefixes alone cannot authorize exclusion: malformed containers, unknown entry types, data-fork entries, orphan companions and ordinary `._` files remain selected.

The engine retains the complete source manifest separately from the selected copy/verification set. Source-change checks still inspect that full manifest. Excluded rows are emitted for every destination and retained in queue settings, results and saved history. Progress and timing count selected work rather than excluded bytes.

Selected media uses the existing verification/readback policy. Existing destination companions are left alone. ASC MHL inventories list the selected destination files, including legitimate `._` files. Existing histories are never replaced. PDF notes, CSV summaries and JSON selection evidence describe the omissions. JSON selection counts explicitly describe retained result rows: a partial export must not imply a complete source inventory. Diagnostics record only an exclusion count, without filenames or paths.

A filtered transfer can say **Selected files verified**, but it cannot earn a whole-card safe-to-erase verdict or an already-verified history match. Quick remains unverified. Missing selected media, copy/read failures, source changes, handoff/report failures and cancellation remain unsafe. Keep the source.

## Local validation

| Check | Result |
| --- | --- |
| `bash test.sh engine-test` | 121 XCTest cases: 15 skipped, 0 failures; 132 Swift Testing cases passed |
| `bash test.sh mac-test` | 1,069 passed, 7 skipped, 0 failures; app and tests built |
| `bash test.sh ipad-test` | 49 passed, 0 skipped, 0 failures; iPad Air 11-inch (M4), iOS 26.5 simulator |
| `bash test.sh mac-build` / `ipad-build` | Debug builds passed; final changes also rebuilt by the test runs |
| UI captures | Mac 580-point controls, phone 320-point controls, iPad 500- and 820-point controls rendered and inspected |
| `git diff --check` | Clean |

The filesystem matrix mounted six sparse images: source and backup volumes for APFS, HFS+ and exFAT. It ran **54 transfers**: three source filesystems × three primary backup filesystems × six scenarios, each with two destinations. Scenarios were initial and repeated preservation, a deliberately conflicting companion, filtered reuse with that conflict preserved, and fresh/repeated filtered copies. All selected destination bytes were independently hashed; source paths, contents and modification dates stayed unchanged.

Fresh filtered copies also exercised the actual Standard → ASC MHL handoff on all three destination filesystems, including the exFAT destination reread. Repeated handoffs refused existing histories and retained their files byte for byte.

Other regressions cover all four verification modes, stale reviews before writes, malformed/data-bearing containers, legitimate `._` files, older settings decoding, history/report scope, a caller requesting an unsafe report verdict, queued policy isolation and cancellation after exclusion rows publish. Cancellation propagates and cannot produce a completed verdict or automatic report.

An earlier engine run had one disposable-image teardown fail with `hdiutil` busy (16). The retained image was detached normally and removed, and the complete engine suite subsequently passed on its own. No force-detach was used. Earlier test-development failures were corrected; they are not passing evidence.

Logs, result summaries and rendered images are retained locally under `dist/validation/issue16`. Generated images are test fixtures, not reporter footage.

## Limits and next evidence

Disk images exercise the actual filesystem drivers, not physical drives, docks, disconnects or on-device Files providers. The UI captures are seeded renderer tests, not a physical-device walkthrough. These tests do not prove why the reporter's transfer failed, or that every AppleDouble variant can be safely excluded. Older/unknown containers are preserved.

Keep #16 open. A useful follow-up is the exact error and **History → Export diagnostics**, plus source/destination filesystems and whether an existing copy was present. The implementation was merged through PR #17. Release validation for 0.2.6 is recorded below.

## 0.2.6 release validation

PR #17 was merged on October 10. The release is version 0.2.6, build 16.

- Release-mode engine suite: 121 XCTest cases, 15 opt-in/platform skips, zero failures; 132 Swift Testing cases passed. The mounted filesystem matrix ran again.
- Final full Mac suite: 1,068 passed, nine opt-in/platform skips, zero failures (1,077 total). Two skipped cases are the opt-in seeded screenshot captures already run for the feature review.
- Final iOS Simulator Release build passed. iPad simulator tests for the feature review passed (49 cases); no physical-device pass is claimed.
- The signed Mac app's picker-driven Standard transfer copied a source on mounted exFAT to two mounted backups (APFS and exFAT), with ASC MHL and PDF/CSV/JSON reports enabled. The source contained a macOS-generated companion and an ordinary `._notes.txt` file. The review excluded only `._clip.bin`; both selected files matched independent SHA-256 checks on both backups. Each MHL listed those two selected files. The primary JSON report recorded three source files, two selected, one excluded and `safeToErase=false`. Source paths, contents and modification dates were unchanged.
- The signed walkthrough found and corrected two presentation gaps: the Start caption counted full source inventory as copy work, and expanded queue/destination summaries called exclusions failures. Filtered starts now avoid the full-inventory copy claim; intentional exclusions have their own count. A new regression preserves actual failed-file counts and an unsafe verdict for filtered transfers. The rebuilt signed app showed each backup as “2 verified, 0 unverified, 1 intentionally excluded” after relaunch, with no false failed-file label.

The app and DMG both passed Apple notarization, ticket stapling and Gatekeeper assessment through the existing release script, with the existing Developer ID and notary profile. No credentials changed. Test preferences and destinations were restored afterward; existing user queue items were retained.

The mounted fixtures are disposable disk images, not physical hardware. Reports and validation logs are retained locally in `dist/validation/issue16-release`. The original report still needs a user retest; #16 stays open.
