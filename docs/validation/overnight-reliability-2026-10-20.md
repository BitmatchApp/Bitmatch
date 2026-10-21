# Overnight reliability validation — October 20–21, 2026

This records local reliability work branched from `main` at `0a50ee5c` on October 20. Source changes and this note are unmerged. The evidence distinguishes passing checks from failing, blocked, and still-running work; it does not complete the blocked-drive TODO.

## Source slices

- `BitMatch/Core/Services/VolumeMonitorService.swift` moves mounted-volume snapshots, per-mount analysis, and live identity checks behind a bounded scheduler. It caps active probes at two, waiting work at eight, coalesces mount snapshots, and serializes probes that touch the same lexical mount. Held-probe tests show MainActor responsiveness, a healthy second-mount path, and stale-identity rejection. A blocked kernel call retains its worker slot until the OS returns; timeouts do not cancel it.
- `Shared/Core/Services/Camera/CardLayoutClassifier.swift` keeps the root-anchored classifier rules, breadth-first order, depth limit, and 20,000-entry cap while enumerating each directory incrementally. Cancellation and the entry cap are checked before each entry request, and directory symlinks are not followed.
- The [classic MHL reader](classic-mhl-duplicate-metadata-2026-10-20.md) rejects conflicting parsed modification dates when combining duplicate file records, preserving a valid claim through a missing/unparseable middle value.
- [Path comparison and missing-tail overlap](path-comparison-2026-10-20.md) now separate stable text normalization from live prefix resolution; the focused regressions passed after demonstrating both old behaviors. The updated engine Swift Testing and full Mac gates passed; other updated gates remain pending.
- The [History app-host probe](history-app-host-2026-10-20.md) measures actual journal, search and rendered History/queue workflows, with failure-preserving receipts.
- Local app test build folders default outside Desktop; eight stubbed routing regressions cover the test runner.
- Shared transfer and safety behavior remains subject to the project promises in [THESIS.md](../THESIS.md). The open reliability item and its remaining boundaries are tracked in [TODO.md](../TODO.md).

## Current gates

Updated production source at `bf3fa22c` passed the engine Swift Testing run and the full Mac app suite, including the path correction, History summary reuse and compiled PDF assertions. The added independent MHL fixture passed its focused reader suite and the updated full engine Swift Testing run. History scratch containment and auto-source readability passed a separate focused run and the full Mac rerun at `b30e844f`. The updated iPhone/iPad simulator build passed. The updated 500-attempt History measurement also passed with a complete cleanup receipt. Updated engine XCTest and physical reruns remain pending. Earlier results are retained below with their source limits; they do not validate later edits.

| Gate | Result |
| --- | --- |
| Final updated Mac app suite, `mac-test-20261021T035847Z`, source `b30e844f` | **Passed:** 1,424 passed, 34 skipped, 0 failed (1,458 total), verified from the result bundle. Includes auto-source readability and scratch containment. |
| Final updated iPhone/iPad simulator build, `ios-build-20261021T040049Z` | **BUILD SUCCEEDED:** arm64 and x86_64; no runtime or physical-device claim. |
| Updated Mac app suite, `mac-test-20261021T033128Z`, source `bf3fa22c` | **Passed:** 1,411 passed, 34 skipped, 0 failed (1,445 total), verified from the result bundle. New opt-in PDF assertions compiled; this does not claim the permission-blocked physical app probe ran. |
| Updated engine Swift Testing, `engine-swift-20261021T032901Z`, source `bf3fa22c` | **Passed:** 257 reported tests across 41 suites, six opt-in skips, zero failures; 25.269 seconds. This precedes the added independent fixture test. |
| Full Mac app suite, `mac-test-20261021T022836Z` | **Passed:** 1,411 passed, 34 skipped, 0 failed (1,445 total). |
| Engine Swift package suite, `engine-swift-20261021T015353Z` | **Passed:** 248 reported tests across 41 suites, 6 skipped; 23.213 seconds. |
| Engine XCTest, `engine-xctest-20261021T020802Z` | **Failed:** 314 total, 82 skipped, 7 failures. The failures were teardown/detach failures; no functional assertion failure was observed. Their cause is unresolved, so this gate is not green. Owned failed-run images were archived on T9 and later detached normally. |
| Engine XCTest rerun, `engine-xctest-20261021T023401Z` | **Passed:** 314 total, 82 skipped, zero failures, 260.652 seconds. All normal detaches completed; no force or retry was added. Detach diagnostics now retain the OS error rather than suppress it. The earlier failures remain separate and unresolved. |
| Focused volume reconciliation, `mac-volume-final-20261021T020526Z` | **Passed:** 22 tests. Held snapshot/probe checks kept MainActor responsive; a healthy mount could finish while another probe was held. Replacement, unmount, late completion, saturation, serial-group bypass, and bounded-worker cases passed. |
| Volume mutation checks | **Expected red, then restored:** removing the off-main snapshot boundary failed the held-snapshot responsiveness assertion; removing same-mount serialization failed the healthy-group bypass case. The restored source also passed its 22 tests in the final combined Mac suite. |
| Focused camera layout suite, `mac-camera-green-20261021T022602Z` | **Passed:** 31 tests, including the incremental-entry cap, in-directory cancellation, depth, and symlink controls. |
| Camera cancellation mutation, `mac-camera-red-cancel-20261021T022744Z` | **Expected red:** removing the inner-loop cancellation check failed `cardListingCancellationStopsInsideWideDirectory` (2 assertions). The restored source also passed its 31 tests in the final combined Mac suite. |
| Local validation scripts, `all-script-tests-final-67.log` | **Passed:** 67 tests under Python 3.12.15, including nine physical-wrapper and seven History-wrapper stub cases; no Xcode or media access. An earlier run under a Python 3.9 build without `dir_fd` failed existing cleanup tests and is not counted as a pass. |
| iPhone/iPad simulator build, `ios-build-20261021T023020Z` | **Passed:** generic iOS Simulator destination, arm64 and x86_64. This is a build result only; no simulator runtime test is claimed. |
| Final History 500-attempt app-host probe, `mac-history-final-20261021T040241Z` | **Passed:** actual non-skipped XCTest, strict receipt checks and cleanup; 50,000 rows, 367 MiB observed peak, 1,242 memory samples and 4,177.1 ms longest main-actor pulse. Not a controlled speedup or #23 reproduction. |
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

After the passing physical matrix and focused path tests, host free space fell below the 50 GiB floor while BitMatch builds were stopped and other project jobs were active. The next History/app gate was refused before launch. Build products, caches and result bundles are on the owned external APFS build image; the host evidence directories are small by comparison. No other project's caches or running jobs were changed. Headroom briefly recovered enough for the updated engine Swift Testing and full Mac passes, then fell below the floor again while BitMatch heavy jobs were stopped. Remaining updated gates and the 119.6 GB engine run remain pending. The independent manifest was generated and reference-validated; its new BitMatch reader test has not yet run.

## Probe runner review and cleanup

The physical app probe now has a tracked wrapper and receipt validator that reject skipped/vacuous Xcode success, mismatched workload and hash/count evidence, and incomplete cleanup. Workload flags are replaced explicitly so a smoke invocation cannot inherit the large opt-in. The probe also requires all eight selected basenames in PDF text. Nine stubbed physical-wrapper cases passed as part of the 60-test script suite; this is runner validation only. The actual physical app run remains permission-blocked. The updated PDF assertion compiled in the passing full Mac gate, but its opt-in physical workflow did not run. A later review also tightened the History probe's scratch-path configuration against symlink escapes; the new shell and app-host regressions are tracked separately until run.

Closed host build/evidence trees were archived on the authorized SSD and verified file-by-file, including recorded metadata, before removal: 16,888 entries, 13,999 regular files, 1,639,322,078 logical bytes. Logs, receipts and the live external build image remain available. Protected primary and frozen-release checkouts stayed clean at their original commits. No user drive was formatted, ejected or unmounted.

## Second independent classic writer

A tiny classic MHL 1.1 inventory from a separately authored Python/lxml implementation is now included with its pinned source revision, MIT notice, synthetic payload and creator-field sanitization record. The literal media filename has leading and trailing spaces. The upstream verifier, upstream schema and primary classic 1.1 schema accepted it. BitMatch controls cover the intact record, same-size media corruption, a missing file, and each individually incorrect recorded digest. Those reader controls passed in the 26-test classic reader suite (`engine-mhl-20261021T034914Z`). The full engine Swift Testing rerun (`engine-swift-20261021T035005Z`) passed 258 reported tests across 41 suites, six opt-in skips, zero failures, in 30.851 seconds. Permanent fixture hashes remained unchanged. This is one more content-evidence fixture, not broad tool certification, empty-file coverage or authenticated custody evidence.

Four additional closed evidence roots were archived and verified before removing their temporary copies: 46,532 entries, 44,951 regular files and 3,391,840,985 logical bytes. Their archive and metadata receipt remain on the authorized SSD. Signed archives, the frozen release and the running app were preserved.
