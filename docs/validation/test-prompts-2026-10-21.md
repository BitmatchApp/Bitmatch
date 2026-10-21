# Test-prompt audit — October 21, 2026

Slice 3 of `docs/TODO.md`: keep ordinary Mac tests free of drive-access
permission prompts, without weakening release entitlements. Physical-drive
probes stay opt-in and separate.

## What was audited

- Every `BITMATCH_*` control read by `BitMatchTests`, `BitMatch-iPadTests`
  and `Packages/BitMatchEngine/Tests` (about 90 names), against the
  `clear_inherited_stress_controls` allow-list in `test.sh`. Ordinary
  `mac-test`, `ipad-test` and `engine-test` jobs clear every inherited
  `BITMATCH_*` / `TEST_RUNNER_BITMATCH_*` name except the six documented
  output-routing controls (`BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS`,
  `BITMATCH_PDF_EDGE_ARTIFACTS`, `BITMATCH_PREVIEW_PDF_OUTPUT`,
  `BITMATCH_REPORT_PDF_ARTIFACTS`, `BITMATCH_MATRIX_ARTIFACTS`,
  `BITMATCH_WORKFLOW_SNAPSHOT_OUTPUT_DIR`). No test reads a non-`BITMATCH_`
  environment variable for fixture routing.
- Owned-fixture discipline: `CoordinatorFolders` / `SharedProjectFixture`
  (per-test UUID folder under `FileManager.default.temporaryDirectory`,
  per-test `UserDefaults` suite, cleanup in `defer`); engine mounted-image
  tests create per-test folders and detach; `UnreadableMediaMonitorTests`
  attaches its blank image `-nomount -nobrowse` (no volume mounts, no
  removable-volume access) from an owned temp folder.
- Seam injection for the newest drive-UI tests: `VolumeMonitorService`
  (`testMountedPathsReader` / `testIdentityReader` / `testAnalysisReader`),
  `MacVolumeAccessModel` (`restorePathExists`, `volumeFacts`, isolated
  defaults suites), `CameraCardDetectionService` (`listVolumes = { [] }`,
  private notification center), `SourceAvailabilityModel` held-worker gates.
  `/Volumes/...` literals elsewhere in ordinary tests are plain model values
  with injected facts; they never reach the filesystem.
- `BackupTargetPolicyTests` (app side) injects fabricated facts for every
  `/Users/...` and `/Volumes/...` case, including the cloud-storage refusals.

## Gap found and fixed

`Packages/BitMatchEngine/Tests/BitMatchEngineTests/BackupTargetPolicyRealVolumeTests.swift`
ran ungated in the ordinary engine suite and touched real drives:

- listed `/Volumes` and read `volumeIsInternalKey` of mounted Recovery
  volumes,
- read real volume facts of `/` and `/Volumes/Macintosh HD`,
- created a folder in the real `~/Library/Caches`.

That is exactly the prompt-prone surface this slice removes from ordinary
runs. The three cases are now `XCTestCase` methods gated by
`BITMATCH_REAL_VOLUME_POLICY=1` (same `XCTSkip` idiom as the FAT32, HFS+,
mounted-matrix and process-death gates); assertions are unchanged when the
gate is set. This is a physical-drive probe, so it stays opt-in and separate
per the slice rules.

## Runner regressions

`Scripts/test_test_runner.py` gains
`test_test_jobs_drop_drive_access_probe_controls`: all three ordinary jobs
must drop 21 drive-access controls plus `TEST_RUNNER_`-prefixed variants of
the volume-policy, physical-app-smoke and mounted-matrix gates, and must
never leak a `/Volumes/...` fixture path through stdout/stderr. Suite now
has 13 tests (12 existing + 1 new).

## Entitlements

Release entitlements are unweakened: `BitMatch/BitMatch.entitlements`
(sandbox, user-selected/download/removable/external read-write, app-scope
bookmarks, network client) is untouched. Ordinary-test builds keep
`CODE_SIGNING_ALLOWED=NO` and derived data outside the checkout
(`/private/tmp/bitmatch-local-tests-<uid>/<checkout-key>`), covered by the
existing runner regressions.

## Physical probes stay opt-in

FAT32 boundary, HFS+ Unicode, mounted transfer matrix, process-death matrix,
recovery mount/type, fault matrix, issue-10 pair, live SFTP, hardware
large-target, soak/bench/codec/race/empty-identity fixtures, many-files
memory, physical app-host smoke/benchmark and the new real-volume policy
gate all skip without their documented variables, and the launcher strips
those variables from ordinary jobs. See
[physical checks](report-memory-2026-10-21.md#physical-checks) for the
separate physical evidence (not rerun here).

## Observed runs

- `python3 Scripts/test_test_runner.py`: **13 tests, 0 failures** (fake
  Xcode/Swift commands only).
- `./test.sh engine-test`: **XCTest 337 executed, 86 skipped, 0 failures;
  Swift Testing 264 tests in 40 suites passed; exit 0.** The three
  newly gated `BackupTargetPolicyRealVolumeTests` cases skip without the
  opt-in variable. Direct opt-in run
  (`BITMATCH_REAL_VOLUME_POLICY=1 ... --filter BackupTargetPolicyRealVolumeTests`):
  **3 tests, 0 failures** — the gate enables the probes without repeating
  any other workload.
- `./test.sh mac-test`: **1,456 passed, 35 skipped, 0 failed
  (1,491 total); `** TEST SUCCEEDED **`**, exit 0. XCTest accounts for 350
  executed / 33 skipped; Swift Testing for 1,141 passed in 110 suites; 35
  `Test skipped` lines reconcile the total. Skips are the documented
  opt-in probes (matrix, many-files, physical, hardware), not coverage of
  this slice.
- No drive-access or permission prompt was observed during any of these
  runs; every run completed without interaction. A local run cannot prove
  no dialog could ever appear on another machine; the guarantee rests on
  the audit above (no ordinary test touches a real drive) plus the launcher
  clearing inherited probe controls.
