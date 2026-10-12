# BitMatch 0.2.9 validation

This release fixes two confirmed large-file memory-retention bugs. It does not yet establish the cause of the roughly 55 GB use reported in [issue #23](https://github.com/BitmatchApp/Bitmatch/issues/23): the reporter's app version, transfer stage and diagnostic export are still needed to connect that run to either path. See [the investigation](ISSUE23_MEMORY_AUDIT.md) for the code paths and test commands.

## Local results

- **Regression tests, red → green:** with a 512 MiB sparse file, ASC MHL destination rereading rose from 10 to 521 MiB before the fix; after the fix it stayed at 10 MiB across all 128 read chunks and published the manifest and chain. The separate saved-checksum XXH64 Check path rose from 5 to 521 MiB before the fix; after the fix it ended at 9 MiB and still reported a deliberately mismatched checksum as changed. These tests use isolated test hosts and opt-in memory flags.
- **Mounted exFAT:** the existing Standard copy → verification → ASC MHL handoff test passed. A separate 1 GiB destination reread on a disposable mounted exFAT image completed all 256 chunks with physical footprint rising from 2 to 8 MiB. The MHL manifest and chain were published, a saved Check matched, and independent SHA-256, size and modification-time checks found the source and destination unchanged.
- **Suites and builds:** the full serial engine suite passed: 126 XCTest cases, 17 intentional opt-in skips, zero failures, plus 151 Swift Testing cases passed. The Mac app suite passed with 1,099 tests, 13 skips and zero failures. The shared iPad/iPhone simulator build passed. Both Mac and mobile **Release** builds from `e7c095f3` passed.
- **Signed artifact:** the 0.2.9 (build 19) app and DMG were signed with the existing Developer ID, accepted by Apple's notary service, stapled and accepted by Gatekeeper. The DMG SHA-256 is `2a2a500883e0103da9e3b7b80228f416bdefa50cf3ba7e570eb334ac9811f2e9`.
- **Signed-app transfer:** the archived 0.2.9 app ran a Standard transfer of five files (34 MB) from a disposable APFS card image to APFS and mounted exFAT destinations. It displayed **Safe to erase** and offered Eject. Independent hashes of all ten destination files matched the five unchanged source files. Both ASC MHL manifests and chains were valid; the PDF report rendered as two pages, and the JSON reported `safeToErase: true`, ten matches and zero issues.

**Signed-app walkthrough complete:** Eject unmounted the disposable source card. The archived signed app quit and relaunched, with the completed transfer row preserved. Afterward, only that disposable row and its two destination selections were removed from the UI.

## Limits

The memory regressions use sparse files; the 1 GiB exFAT run uses a disposable disk image, not the reporter's physical drive or footage. Neither reproduces his exact workload. GitHub PR #24's engine and Mac CI jobs failed on the Xcode 26.3 runner's isolation-checker/toolchain errors; its iOS build passed. The local engine and Mac suites above passed on Xcode 27 and were the release gates. Local logs are under the ignored `dist/validation/release-0.2.9/` directory.
