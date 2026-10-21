# Overnight reliability validation — October 20–21, 2026

This records local reliability work branched from `main` at `0a50ee5c` on October 20. Source changes and this note are unmerged. The evidence distinguishes passing checks from failing, blocked, and still-running work; it does not complete the blocked-drive TODO.

## Source slices

- `BitMatch/Core/Services/VolumeMonitorService.swift` moves mounted-volume snapshots, per-mount analysis, and live identity checks behind a bounded scheduler. It caps active probes at two, waiting work at eight, coalesces mount snapshots, and serializes probes that touch the same lexical mount. Held-probe tests show MainActor responsiveness, a healthy second-mount path, and stale-identity rejection. A blocked kernel call retains its worker slot until the OS returns; timeouts do not cancel it.
- `Shared/Core/Services/Camera/CardLayoutClassifier.swift` keeps the root-anchored classifier rules, breadth-first order, depth limit, and 20,000-entry cap while enumerating each directory incrementally. Cancellation and the entry cap are checked before each entry request, and directory symlinks are not followed.
- The [classic MHL reader](classic-mhl-duplicate-metadata-2026-10-20.md) rejects conflicting parsed modification dates when combining duplicate file records, preserving a valid claim through a missing/unparseable middle value.
- [Path comparison and missing-tail overlap](path-comparison-2026-10-20.md) now separate stable text normalization from live prefix resolution; focused regressions demonstrated both old behaviors before the corrected engine and Mac gates passed.
- The [History app-host probe](history-app-host-2026-10-20.md) measures actual journal, search and rendered History/queue workflows, with failure-preserving receipts.
- Local app test build folders default outside Desktop; eight stubbed routing regressions cover the test runner.
- Shared transfer and safety behavior remains subject to the project promises in [THESIS.md](../THESIS.md). The open reliability item and its remaining boundaries are tracked in [TODO.md](../TODO.md).

## Current gates

Production source at `b30e844f` passed the full Mac suite, iPhone/iPad simulator build, updated engine XCTest and 500-attempt History probe. The engine Swift Testing suite also passed with the independent MHL fixture. The updated physical matrix then stopped at a source-stability rejection during Thorough; its fixtures are retained. A separate 119.6 GB SSD-to-SSD engine run passed. Earlier results remain distinct and do not turn the failed matrix green.

| Gate | Result |
| --- | --- |
| Final updated Mac app suite, `mac-test-20261021T035847Z`, source `b30e844f` | **Passed:** 1,424 passed, 34 skipped, 0 failed (1,458 total), verified from the result bundle. Includes auto-source readability and scratch containment. |
| Final updated iPhone/iPad simulator build, `ios-build-20261021T040049Z` | **BUILD SUCCEEDED:** arm64 and x86_64; no runtime or physical-device claim. |
| Final engine XCTest, `engine-xctest-20261021T040457Z` | **Passed:** 314 total, 82 skipped, zero failures, 87.881 seconds. All normal detaches completed; no force or retry was added. Earlier detach failures remain unresolved and retained. |
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
| Earlier physical mode/pipeline matrix, `physical-matrix-20261021T024314Z`, SD → two SSDs | **Passed:** one non-skipped XCTest executed nine transfers: four modes × pipeline off/on plus Standard reuse. Source hashes unchanged; previous histories preserved on reuse. Worker peak 30 MiB; 827.965 seconds. Predates the path correction. |
| Updated physical matrix, `physical-matrix-20261021T041046Z`, source `1a74707a` | **Failed and retained:** Quick off/on, Standard off/on and Standard reuse completed. Thorough without pipelining returned two “Source file changed during copy” rows; the test stopped at 442.258 seconds. The old test log does not identify the exact file or changed identity field. No crash or successful verdict is claimed. Failure-only breadcrumbs and a focused repeat are needed before attributing this to a defect. |
| Large physical engine workflow, `physical-large-20261021T042204Z`, source checkout `1a74707a` | **Passed:** one actual XCTest, zero failures/skips, 1,898.202 seconds. Eight synthetic MOV containers / 119,600,000,000 selected media bytes; Standard, one separate SSD backup, two overlapping large readers observed. Copy/verify 507.411 s, fresh exFAT MHL read 453.198 s, Saved Check 388.453 s; original source inventory, sizes and hashes matched. Sampled worker footprint 13 → 39 MiB. Not actual GUI memory, playable footage, controlled performance or a field reproduction. |
| Large-app memory smoke | **Blocked before test-data generation:** macOS removable-volume permission and the host-space/runtime guard stopped the attempt. The planned 119.6 GB app was never run. |

The earlier 50,000-row History app-host run observed a 286 MiB process peak. The revised run observed 344 MiB. They are distinct single-run observations that include fixture/test/UI overhead, not a leak proof or a reproduction of #23. The revised run also showed a long responsiveness pulse requiring attribution; see the [app-host record](history-app-host-2026-10-20.md).

## Environment and limits

The gates ran with Xcode 27.1 (27A9275), Swift 6.4, and macOS 27.0.1 (26A434) on a 24 GB Mac. Local result logs and bundles are retained in private evidence storage; this document intentionally omits its absolute paths, run nonces, and raw mount paths.

The blocked-drive TODO remains open. `CardLayoutClassifier` is depth- and entry-bounded, but live classification still examines mounted volumes beyond the selected source; a policy change to avoid surveying unselected storage remains unfinished. Mac auto-source readability now runs behind bounded workers with stale-result checks. `SharedAppCoordinator` automatic-enqueue safety/source-file preflight and the source setter's bookmark/identity work remain open synchronous boundaries. Kernel calls can retain scheduler slots indefinitely, and per-call file-descriptor use is unmeasured. No physical card unplug/replacement or native card UI proof is claimed.

GitHub Actions CI remains disabled and was not run. No release publication, tag, signing-credential, notarization, updater, or public-catalog change occurred. The protected primary branch and frozen release state remained unchanged. This document and the reviewed source changes are draft and unmerged.

## Resource pause

Host free space fell below the 50 GiB external-build floor during earlier pauses while BitMatch builds were stopped and other project jobs were active. Gates were refused or interrupted rather than lowering that floor. Build products, caches and result bundles remain on the owned external APFS image. Headroom later recovered for the updated checks above. No other project's caches or running jobs were changed.

## Probe runner review and cleanup

The physical app probe now has a tracked wrapper and receipt validator that reject skipped/vacuous Xcode success, mismatched workload and hash/count evidence, and incomplete cleanup. Workload flags are replaced explicitly so a smoke invocation cannot inherit the large opt-in. The probe also requires all eight selected basenames in PDF text. Nine stubbed physical-wrapper cases and seven History-wrapper cases passed in the 67-test script suite; these are runner checks only. The actual physical app run remains permission-blocked. The PDF assertion compiled in the passing full Mac gate, but its opt-in physical workflow did not run. History scratch containment also passed two ordinary app tests and the actual 500-attempt probe. The original shell wrapper failed both corrected symlink-escape controls; restored source passed.

The physical engine tests above lacked a private diagnostic-store override and could write synthetic events into the default unsandboxed application-support ring. This was not measured, and does not establish that the signed app's separate container was affected. A separate test-only candidate scopes future pipeline, MHL and Check diagnostics to retained private scratch evidence. Existing logs and saved transfer history are not changed by that correction.

Closed host build/evidence trees were archived on the authorized SSD and verified file-by-file, including recorded metadata, before removal: 16,888 entries, 13,999 regular files, 1,639,322,078 logical bytes. Logs, receipts and the live external build image remain available. Protected primary and frozen-release checkouts stayed clean at their original commits. No user drive was formatted, ejected or unmounted.

## Second independent classic writer

A tiny classic MHL 1.1 inventory from a separately authored Python/lxml implementation is now included with its pinned source revision, MIT notice, synthetic payload and creator-field sanitization record. The literal media filename has leading and trailing spaces. The upstream verifier, upstream schema and primary classic 1.1 schema accepted it. BitMatch controls cover the intact record, same-size media corruption, a missing file, and each individually incorrect recorded digest. Those reader controls passed in the 26-test classic reader suite (`engine-mhl-20261021T034914Z`). The full engine Swift Testing rerun (`engine-swift-20261021T035005Z`) passed 258 reported tests across 41 suites, six opt-in skips, zero failures, in 30.851 seconds. Permanent fixture hashes remained unchanged. This is one more content-evidence fixture, not broad tool certification, empty-file coverage or authenticated custody evidence.

Four additional closed evidence roots were archived and verified before removing their temporary copies: 46,532 entries, 44,951 regular files and 3,391,840,985 logical bytes. Their archive and metadata receipt remain on the authorized SSD. Signed archives, the frozen release and the running app were preserved.
