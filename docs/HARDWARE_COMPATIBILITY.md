# Hardware validation status

No physical-device test reports are recorded in this matrix yet. Mounted disk-image tests exercise APFS, HFS+, exFAT and FAT32, but they do not validate physical enclosures, hubs, readers or cables. Those combinations remain **unverified here** until a reproducible report is published. This is an evidence register, not a certification or a list of unsupported hardware.

| Evidence type | Available workflow | What it establishes |
| --- | --- | --- |
| Automated transfer tests | `bash test.sh mac-test` | Behavior exercised by the test suite on its host; optional tests may skip without their harness. |
| Automated seeded soak | `bash Scripts/run_soak_tests.sh` | Repeated synthetic transfers with independent output hashes on the host filesystem, for the recorded seed and iteration count. |
| Automated APFS fault | `bash Scripts/run_apfs_fault_tests.sh` | Handling of an injected inaccessible destination in a disposable APFS image. |
| Mounted filesystem and feature matrix | [Synthetic transfer matrix](TRANSFER_MATRIX.md) | Copy, verification, ASC MHL, project workflows and reports on disposable mounted images; no physical cable or controller faults. |
| Physical storage and connection tests | [Hardware testing procedure](HARDWARE_TESTING.md) | Only the specific device, filesystem, connection, revision, and scenario recorded in a report. No physical results have been entered. |

These rows describe available tests, not claims that they passed. A published automated result must include the run date, revision, working-tree state, exit status, test totals (including skipped tests), and a link to retained evidence. Automated results do not count as physical cable-pull or power-loss results.

## Recorded automated validation

The entries below are dated records, not a list of current failures. Recent work includes the [mounted filesystem and feature matrix](TRANSFER_MATRIX.md), [large-file verification investigation](VERIFICATION_MEMORY.md), and [Sony metadata and Check investigation](ISSUE8_SONY_VENICE.md). The October 5 validation for 0.2.5 passed the full Mac suite (1,063 passed, eight skipped, zero failures), serial Release engine tests, and Mac/iOS Simulator Release builds. The signed app also completed transfers and saved-checksum checks on mounted images. These results do not reproduce a physical Sony reader or prove the cause of either reporter's failure.

[2026-09-06 development validation](validation/2026-09-06/README.md): the Mac suite passed on rerun, the iPad simulator build passed, and the seeded soak verified 450 destination outputs. The report retains the initial pause-reset timeout. APFS image creation was blocked by the host's “Resource busy” error before tests began. The real app demo independently verified 24 local copies. None of these results establishes physical-device compatibility.

[2026-09-08 development validation](validation/2026-09-08/README.md) covers the shared queue, recovery, ASC MHL reference checks, and Mac/iPhone/iPad interface checks. These are source and simulator results from that date; use the [latest release](https://github.com/BitmatchApp/Bitmatch/releases/latest) for current fixes.

[2026-09-19 release-readiness validation](validation/2026-09-19/README.md) covers the audit integrity fixes and priorities 1–6 in source: retained comparison paths with export, journal-backed completion exports, identity-checked reconnection, report-failure completion with queue stop, and Mac off-site queue restore with bounded retries. Full Mac suite, both app targets, and both Release configurations pass except the known pre-existing `testRejectsPathTraversal` failure. Physical-device results remain unrecorded.

## Known behavior by card and drive type

What the code on `main` does for these cases, with where it lives. These are code and automated-test facts, not physical results; the table below stays the record of those.

| Case | Behavior | Where | Hardware evidence |
| --- | --- | --- | --- |
| Sony VENICE SxS card (UDF) on a Mac | If Disk Arbitration reports a removable disk with no readable filesystem and its description matches SxS, BitMatch shows a setup notice with Sony driver guidance. This notice is a heuristic, not a diagnosis of every Sony card. | `BitMatch/Core/Services/UnreadableMediaMonitor.swift` (`UnreadableMediaNotice.make`), shown by `BitMatch/Views/CopyAndVerify/UnreadableMediaBanner.swift`; tests `UnreadableMediaNoticeTests`, `UnreadableMediaMonitorTests` | None recorded. Detection matches "sxs", or "sony" with "card", in the disk's vendor, model or media name. |
| Sony AXS card on a Mac | If an unreadable disk's description matches AXS, the same notice path links to Sony reader-software support. | same as above | None recorded. Matches "axs" in the disk's description. |
| Any other card macOS sees but cannot read | A generic notice: it may need its maker's driver or use an unsupported format. | same as above | None recorded. |
| exFAT (and FAT) backup drive | Copy publication was fixed in 0.1.7; ASC MHL directory publication was fixed in 0.2.2 and is covered by the [handoff matrix](TRANSFER_MATRIX.md). exFAT has no hard links, so the `linkat` publish failed every file with "Destination file appeared during copy" in 0.1.4–0.1.6. On `ENOTSUP`/`EOPNOTSUPP` BitMatch now claims the final name with an exclusive create and renames the verified temp file onto that empty claim; an existing file still fails the file and is never replaced. | `Packages/BitMatchEngine/Sources/BitMatchEngine/File/DestinationWriter.swift` (`PinnedDestinationDirectory.publishTemporaryFile`, `publishByClaimingName`); test `Packages/BitMatchEngine/Tests/BitMatchEngineTests/ExFATDestinationTests.swift`, which mounts a real exFAT disk image | The bug was first found on real exFAT hardware (lukasisar/Bitmatch#4). The fix is tested on an exFAT disk image, not yet on a physical drive. |
| A folder on the Mac's startup disk as a backup | Allowed when you pick it (for example in your home folder). The startup disk itself ("/", which `/Volumes/Macintosh HD` resolves to), anything under `/System`, and the root of an internal volume with a system name (Recovery, "Recovery 2", Preboot, any letter case) are refused with a reason. Drive discovery and the launch-time restore never add them. The engine's own preflight also refuses `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/var` and `/etc`. | `Packages/BitMatchEngine/Sources/BitMatchEngine/File/BackupTargetPolicy.swift` (`refusal(for:origin:source:)`), `Packages/BitMatchEngine/Sources/BitMatchEngine/File/SafetyValidator.swift` (`isProtectedSystemPath`); tests `BackupTargetPolicyTests`, `BackupTargetPolicyRealVolumeTests` (real paths on the test Mac) | A mounted internal Recovery volume being offered as a backup was confirmed and fixed on a Mac (see [THESIS.md](THESIS.md), "Must fix before the next release"). |
| iPad/iPhone backup chosen in Files (On My iPad, iCloud Drive, an external drive) | Works from 0.1.7. On a device these folders live below `/private/var/mobile`, which the system-folder rule refused, so every backup was refused as a "system folder". `/var/mobile` and `/private/var/mobile` are now user storage on iOS; other system folders stay protected. | `Packages/BitMatchEngine/Sources/BitMatchEngine/File/SafetyValidator.swift` (`isProtectedSystemPath`, `iOSUserStorageRoots`; commit `31bc940`); test `BitMatch-iPadTests/IOSStoragePathTests.swift` | **Not yet confirmed on a physical iPhone or iPad.** The simulator cannot show the bug: its paths are under the Mac's `/Users`. |

## Physical results

| Report | Date | App revision / OS | Source and destinations / filesystems | Connection | Scenario | Outcome |
| --- | --- | --- | --- | --- | --- | --- |
| No reports recorded | — | — | — | — | — | Not tested |

Use **Pass**, **Fail**, **Inconclusive**, or **Not tested**. A pass requires the scenario's expected behavior and independent hashes for all outputs reported as successful. Document failures and incomplete runs as well as passes. Use the [report template](HARDWARE_REPORT_TEMPLATE.md) and link the evidence when adding a row.
