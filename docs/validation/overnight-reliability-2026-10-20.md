# Overnight reliability validation — October 20–21, 2026

This records local reliability work branched from `main` at `0a50ee5c` on October 20. Source changes and this note are unmerged. The evidence distinguishes passing checks from failing, blocked, and still-running work; it does not complete the blocked-drive TODO.

## Source slices

- `BitMatch/Core/Services/VolumeMonitorService.swift` moves mounted-volume snapshots, per-mount analysis, and live identity checks behind a bounded scheduler. It caps active probes at two, waiting work at eight, coalesces mount snapshots, and serializes probes that touch the same lexical mount. Held-probe tests show MainActor responsiveness, a healthy second-mount path, and stale-identity rejection. A blocked kernel call retains its worker slot until the OS returns; timeouts do not cancel it.
- `Shared/Core/Services/Camera/CardLayoutClassifier.swift` keeps the root-anchored classifier rules, breadth-first order, depth limit, and 20,000-entry cap while enumerating each directory incrementally. Cancellation and the entry cap are checked before each entry request, and directory symlinks are not followed.
- The [classic MHL reader](classic-mhl-duplicate-metadata-2026-10-20.md) rejects conflicting parsed modification dates when combining duplicate file records, preserving a valid claim through a missing/unparseable middle value.
- [Path comparison and missing-tail overlap](path-comparison-2026-10-20.md) now separate stable text normalization from live prefix resolution; the focused regressions passed after demonstrating both old behaviors. Full updated gates remain pending.
- The [History app-host probe](history-app-host-2026-10-20.md) measures actual journal, search and rendered History/queue workflows, with failure-preserving receipts.
- Local app test build folders default outside Desktop; eight stubbed routing regressions cover the test runner.
- Shared transfer and safety behavior remains subject to the project promises in [THESIS.md](../THESIS.md). The open reliability item and its remaining boundaries are tracked in [TODO.md](../TODO.md).

## Current gates

The full engine, Mac, iPhone/iPad build and physical matrix results below precede the later path-comparison/prefix-resolution and History presentation changes. The path correction passed its 13 focused tests and a separate 500-attempt History probe; the subsequent presentation reuse and PDF assertion still await fresh app gates. Updated broad gates have not run yet. A subsequent History launch was refused before testing because host free space was below the 50 GiB external-build floor. Earlier passes do not validate the newer source.

| Gate | Result |
| --- | --- |
| Full Mac app suite, `mac-test-20261021T022836Z` | **Passed:** 1,411 passed, 34 skipped, 0 failed (1,445 total). |
| Engine Swift package suite, `engine-swift-20261021T015353Z` | **Passed:** 248 reported tests across 41 suites, 6 skipped; 23.213 seconds. |
| Engine XCTest, `engine-xctest-20261021T020802Z` | **Failed:** 314 total, 82 skipped, 7 failures. The failures were teardown/detach failures; no functional assertion failure was observed. Their cause is unresolved, so this gate is not green. Owned failed-run images were archived on T9 and later detached normally. |
| Engine XCTest rerun, `engine-xctest-20261021T023401Z` | **Passed:** 314 total, 82 skipped, zero failures, 260.652 seconds. All normal detaches completed; no force or retry was added. Detach diagnostics now retain the OS error rather than suppress it. The earlier failures remain separate and unresolved. |
| Focused volume reconciliation, `mac-volume-final-20261021T020526Z` | **Passed:** 22 tests. Held snapshot/probe checks kept MainActor responsive; a healthy mount could finish while another probe was held. Replacement, unmount, late completion, saturation, serial-group bypass, and bounded-worker cases passed. |
| Volume mutation checks | **Expected red, then restored:** removing the off-main snapshot boundary failed the held-snapshot responsiveness assertion; removing same-mount serialization failed the healthy-group bypass case. The restored source also passed its 22 tests in the final combined Mac suite. |
| Focused camera layout suite, `mac-camera-green-20261021T022602Z` | **Passed:** 31 tests, including the incremental-entry cap, in-directory cancellation, depth, and symlink controls. |
| Camera cancellation mutation, `mac-camera-red-cancel-20261021T022744Z` | **Expected red:** removing the inner-loop cancellation check failed `cardListingCancellationStopsInsideWideDirectory` (2 assertions). The restored source also passed its 31 tests in the final combined Mac suite. |
| Local validation scripts, `all-script-tests-final-60.log` | **Passed:** 60 tests, including nine stubbed physical-wrapper cases; no Xcode or media access in these checks. |
| iPhone/iPad simulator build, `ios-build-20261021T023020Z` | **Passed:** generic iOS Simulator destination, arm64 and x86_64. This is a build result only; no simulator runtime test is claimed. |
| Revised History 500-attempt app-host probe | **Passed:** 50,000 rows, 344 MiB observed process peak, 1,460 footprint samples; actual non-skipped XCTest and complete cleanup receipt verified. The separate fine-checkpoint run also passed; both external sampling attempts produced empty call graphs, so neither identifies a hot path. |
| Physical small retry, SD → two SSDs | **Passed:** two Standard transfers, empty-file retry and byte-identical previous MHL histories on both backups; source hashes unchanged. |
| Physical mode/pipeline matrix, SD → two SSDs | **Passed:** one non-skipped XCTest executed nine transfers: four modes × pipeline off/on plus Standard reuse. Source hashes unchanged; previous histories preserved on reuse. Worker peak 30 MiB; 827.965 seconds. |
| Large-app memory smoke | **Blocked before test-data generation:** macOS removable-volume permission and the host-space/runtime guard stopped the attempt. The planned 119.6 GB app was never run. |

The earlier 50,000-row History app-host run observed a 286 MiB process peak. The revised run observed 344 MiB. They are distinct single-run observations that include fixture/test/UI overhead, not a leak proof or a reproduction of #23. The revised run also showed a long responsiveness pulse requiring attribution; see the [app-host record](history-app-host-2026-10-20.md).

## Environment and limits

The gates ran with Xcode 27.1 (27A9275), Swift 6.4, and macOS 27.0.1 (26A434) on a 24 GB Mac. Local result logs and bundles are retained in private evidence storage; this document intentionally omits its absolute paths, run nonces, and raw mount paths.

The blocked-drive TODO remains open. `CardLayoutClassifier` is depth- and entry-bounded, but live classification still examines mounted volumes beyond the selected source; a policy change to avoid surveying unselected storage remains unfinished. `SharedAppCoordinator` automatic-enqueue safety/source-file preflight and the Mac auto-source readability check are still synchronous boundaries. Kernel calls can retain scheduler slots indefinitely, and per-call file-descriptor use is unmeasured. No physical card unplug/replacement or native card UI proof is claimed.

GitHub Actions CI remains disabled and was not run. No release publication, tag, signing-credential, notarization, updater, or public-catalog change occurred. The protected primary branch and frozen release state remained unchanged. This document and the reviewed source changes are draft and unmerged.

## Resource pause

After the passing physical matrix and focused path tests, host free space fell below the 50 GiB floor while BitMatch builds were stopped and other project jobs were active. The next History/app gate was refused before launch. Build products, caches and result bundles are on the owned external APFS build image; the host evidence directories are small by comparison. No other project's caches or running jobs were changed. Updated broad gates, the 119.6 GB engine run and the additional independent-manifest fixture remain pending, rather than counted as passes.

## Probe runner review and cleanup

The physical app probe now has a tracked wrapper and receipt validator that reject skipped/vacuous Xcode success, mismatched workload and hash/count evidence, and incomplete cleanup. Workload flags are replaced explicitly so a smoke invocation cannot inherit the large opt-in. The probe also requires all eight selected basenames in PDF text. Nine stubbed wrapper cases passed as part of the 60-test script suite; this is runner validation only. The actual physical app run remains permission-blocked, and the updated PDF assertion still needs the fresh app gate.

Closed host build/evidence trees were archived on the authorized SSD and verified file-by-file, including recorded metadata, before removal: 16,888 entries, 13,999 regular files, 1,639,322,078 logical bytes. Logs, receipts and the live external build image remain available. Protected primary and frozen-release checkouts stayed clean at their original commits. No user drive was formatted, ejected or unmounted.
