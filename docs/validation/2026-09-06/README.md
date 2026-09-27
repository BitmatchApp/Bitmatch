# Development validation — 2026-09-06

This run validates the first-transfer presentation changes in [07df297](https://github.com/BitmatchApp/Bitmatch/commit/07df297b95c9552169cad6e27d749ceea6c87a87). Tests ran against the working tree before that commit, with the same Swift source. Harness cleanup and setup-log retention were also checked as described below. This is development validation, not a new signed release or physical-device certification.

Host: Apple Silicon Mac, macOS 26.6 (25G5057c), Xcode 26.6 (17F113).

| Check | Outcome | Evidence and scope |
| --- | --- | --- |
| macOS unit/integration suite | Passed on rerun | [Final summary](mac-tests-final.json): 446 passed, 1 skipped, 0 failed. Counts use `xcresulttool`'s top-level test totals, before expanding parameterized cases. |
| Initial macOS suite | Failed | [Initial summary](mac-tests-initial.json): the existing pause-reset test exceeded its two-second deadline. Its test class then passed in isolation, followed by the full passing rerun. No timeout or engine change was made. |
| iPad simulator Debug build | Passed | `bash test.sh ipad-build`, exit 0. Compile validation only; no iPad runtime or device tests were performed in this run. |
| Seeded Standard-mode soak | Passed | [Test summary](soak.json) and [iteration evidence](soak-iterations.json): seed 20260711, 25/25 iterations, 9 manifest files per iteration, 2 local destinations, 450 independently hashed destination outputs. |
| Harness cleanup fault injection | Passed | `python3 Scripts/test_harness_cleanup.py`: 4 checks cover result-retention failure, test-configuration cleanup failure, metadata failure, and work-directory cleanup failure. No mounts or physical media involved. |
| APFS disk-image fault harness | Blocked before tests | [setup error](apfs-setup.txt): `hdiutil create` failed with “Resource busy,” exit 1. The final retry retained the same error. No disk-image test result bundle was produced, and no APFS fault pass is claimed. |
| Real app demo | Passed | [Capture and reproduction notes](../../demo/README.md): 12 synthetic files copied to 2 folders on the same Mac; all 24 destination copies independently matched SHA-256. |
| Physical storage, cable removal, and power loss | Not tested | Requires the [hardware procedure](../../HARDWARE_TESTING.md) with disposable media and recorded devices. |

## Reproduce

```sh
bash test.sh mac-test
bash test.sh ipad-build
python3 Scripts/test_harness_cleanup.py
BITMATCH_SOAK_SEED=20260711 BITMATCH_SOAK_ITERATIONS=25 bash Scripts/run_soak_tests.sh
bash Scripts/run_apfs_fault_tests.sh
```

The optional soak test is skipped by the normal suite and exercised separately by its harness. The initial pause-reset failure is retained here because a passing rerun does not establish that its timing sensitivity is resolved.

The JSON files are redacted summaries extracted from the local Xcode result bundles. Device identifiers and private paths have been omitted. The full bundles, build/test logs, and environment records remain local to the validation run; these public summaries are not raw logs. No physical compatibility should be inferred from synthetic transfers on one host filesystem.
