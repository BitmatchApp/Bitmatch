# Three-disk physical transfer suite — October 22, 2026

Second run of `Scripts/test-physical-drives.py` (Homebrew Python 3.15) with three distinct physical volumes, on `main` at `58931a93` (the 0.2.11 cut, build 22; the engine is unchanged by the later row hit-testing fix). No `--large` case. Fixtures are generated test data in new marked folders; existing footage is never selected or modified, and passing fixtures are cleaned up.

## Volumes

| Role | Volume | Bus | Notes |
| --- | --- | --- | --- |
| Source (sd) | `/Volumes/Untitled` | SD reader | 119 Gi exFAT card, 112 Gi free |
| Backup A (ssdA) | `/Volumes/T9` | USB | 3.6 Ti exFAT, 3.6 Ti free |
| Backup B (ssdB) | `/Volumes/WheeDrive` | USB | 1.8 Ti exFAT, 1.6 Ti free |

The runner verified three distinct physical parent disks before creating any fixture.

## Result

- `PhysicalDriveTransferTests.testCardToTwoPhysicalBackupsAcrossModesAndReuse` passed: 1 test, 0 failures, 762.9 s. Card-to-two-backups across Quick, Standard, Thorough and Paranoid plus the reuse pass, on real media through the real engine.
- Runner summary: `exitStatus 0`, `cleanupWarnings []`, `retainedFixtureRoles []`; all generated fixtures removed after the pass.
- Receipts retained privately at `/private/tmp/bitmatch-physical-r9fydw8x` (`build.log`, `card.log`, `config.json`, `summary.json`). The machine was also running the Mac test suite and a Release archive during the run, so timings are not a benchmark.

## Limits

- The 119.6 GB `--large` case was not run.
- No power-loss test and no fault injection on physical media; synthetic fault coverage remains the engine suites. The out-of-space pause on a physical bus is recorded separately in the [0.2.11 record](RELEASE_0_2_11.md) if it was exercised.
