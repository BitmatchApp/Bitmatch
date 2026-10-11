# BitMatch 0.2.8 validation

October 10, 2026. Build 18 combines #20 (queue admission/editing/recovery), #21 (saved-evidence compatibility) and #22 (recognized MHL metadata companions). Production source for the archive is `7e549f1e`; later release-record changes are documentation only.

## Local gates

- Full combined Mac suite: **1,099 passed, 13 intentional skips, zero failures**.
- Engine: **124 XCTest cases, 15 intentional skips, zero failures**; the **151-test Swift Testing run passed**, including six opt-in skips. Mounted exFAT handoff and the 54-transfer APFS/HFS+/exFAT AppleDouble matrix ran.
- iPhone 17 Pro simulator: **71 passed**, before combining #20. iPad Air 11-inch (M4) simulator: **72 passed** on the combined code. Both included workflow captures; narrow and wide checksum-warning layouts were inspected.
- Shared iPhone/iPad Release simulator build: **passed**, arm64 and x86_64; rebuilt after #22.
- Independent ASC reference validation: permanent MD5/XXH64/C4 corpus and newly generated BitMatch output passed schemas, byte checks, chain-digest checks and generation append. Deliberately changed media was rejected.
- `git diff --check`: clean.

The [compatibility record](EVIDENCE_COMPATIBILITY_VALIDATION.md) includes observed red states, the earlier timing failure and exact scope. The [queue record](QUEUE_RECOVERY_VALIDATION.md) includes its signed-app conflict/retry/source-replacement walkthrough. GitHub CI was not used as the release gate.

Large-media/memory, external-fixture and hardware-dependent opt-in tests were not rerun for this batch. This is file-content interoperability coverage, not full ASC chain/structure verification or a claim about physical cables, docks and drives. AppKit bitmap captures omit some native layers; the signed-app walkthrough checks actual presentation.

The first signed candidate exposed one regression in the stricter reader: it tried to parse a macOS-generated `._<manifest>.mhl` as XML on exFAT. That candidate was never published. The real-volume and synthetic companion tests failed before #22 and passed after it. The full Mac and engine gates above were rerun after the correction. Only proven metadata-only AppleDouble containers with an existing companion are excluded from the document list; their files remain unchanged.

## Signed release walkthrough

The final universal Developer ID archive and DMG were notarized, stapled and accepted by Gatekeeper. The app was launched from that archive with its production sandbox intact.

- Standard transfer from a disposable mounted APFS card to separate APFS and exFAT backups: four files per destination, ASC MHL enabled, reports enabled. The source contained Unicode, XML-sensitive characters, edge spaces, a hidden camera sidecar and an empty file.
- The app reported four verified files on each backup. Independent SHA-256 checks confirmed all eight copies. Source file contents, sizes, modification times and modes were unchanged. Both backups received an MHL history; the first backup received PDF, CSV and JSON reports, with `safeToErase: true` and eight results.
- Check opened the final exFAT backup and reported four intact files using its saved checksums. The visible qualification correctly limited the result to file contents, excluding MHL history and directory-structure verification.
- A separate fixture with a deliberately truncated manifest showed the damaged-checksums explanation and refused a saved-checksum success path.
- Source ejection worked. Setup options were restored, synthetic rows were removed from the active queue, and the three pre-existing queue rows were preserved. Completed synthetic attempts remain in History by design. The app was quit afterward.

Release artifact SHA-256: `5250931258024b99bf2ca89e2e762dfe2b7e0fc64a6c62e31bc5edb1fd2e3b81`.

Logs, test summaries and small report/MHL evidence are retained locally in `dist/validation/release-0.2.8/`. These are synthetic mounted volumes, not a physical-drive or dock certification.
