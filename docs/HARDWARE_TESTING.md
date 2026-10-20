# Hardware fault-testing procedure

Hardware fault tests can destroy or corrupt media. Use throwaway source data only. Before any cable-pull exercise, keep two independently verified backups on devices that will not be connected to the test system. A second copy on another partition of the same device is not an independent backup.

## Before each run

1. Disconnect every storage device that is not part of the test.
2. Label the throwaway source and both throwaway destinations unambiguously.
3. Verify the two offline backups by recomputing their hashes; do not rely on file counts or Finder previews.
4. Record macOS version, BitMatch revision, filesystem, enclosure, cable, hub, power source, and verification mode.
5. Start with small synthetic files whose expected SHA-256 manifest is already saved offline.
6. Confirm which device may be unplugged before starting the transfer.

Never remove the last known-good copy. Never run these procedures against client media, irreplaceable camera cards, or a mounted production archive.

## Fault matrix

Run each case with APFS destinations, exFAT destinations, and mixed APFS/exFAT destinations where the hardware supports them. Repeat direct-attached and through a low-power or bus-powered hub, but do not exceed the hub or computer vendor's electrical limits.

### Source removal

Start a Standard transfer to two destinations, wait until active copying is visible, then remove only the throwaway source. Record the displayed failure, whether cancellation remains responsive, whether temporary files remain, and whether previously published outputs still match the offline manifest. Reconnect the source only after the operation has stopped.

### One-destination removal

Start a Standard transfer to two destinations and remove one throwaway destination while leaving the other connected. The removed destination must report failures; the remaining destination must finish and every successful output must match the manifest. Inspect retained files and incomplete-status warnings after reconnecting the removed device. A retained partial file must never be presented as verified.

### Sleep and backgrounding

During copy and again during verification, put the Mac to sleep and wake it after at least 30 seconds. Also send BitMatch to the background and switch users if that is part of the deployment workflow. Record whether progress resumes, fails explicitly, or stalls. Hash all successful outputs independently after the run.

### Cancel and relaunch

Cancel during copy, confirm activity stops, then quit and relaunch BitMatch. Repeat cancellation during verification. Confirm no canceled or failed row is classified as successful. On exFAT/FAT, an interrupted copy deliberately retains its partial bytes and incomplete-status warning; check that recovery refuses to treat them as complete. A relaunch must not silently convert an incomplete transfer into success.

### Low-power hubs

Repeat the one-destination-removal and sleep cases through the approved low-power hub using the intended cable lengths. Watch for both explicit disconnects and transient resets. Record System Information's USB or Thunderbolt topology and system logs with the test notes. Do not intentionally overload, short, or thermally stress hardware.

## Evidence to retain

For every run, retain the seed or source manifest, BitMatch result export, independent post-run hashes, exact fault timing, expected outcome, actual outcome, and photos or topology notes that identify the devices. Treat a hang, silent retry, stale success row, unexpected overwrite, or partial file without its required warning as a failure even if another destination completes. Retained incomplete output is evidence to inspect, not a successful copy.

The automated APFS image test in `Scripts/run_apfs_fault_tests.sh` is a safer first step, but it does not simulate cable, bridge firmware, power-loss, or exFAT behavior. Passing it is not evidence that physical removal is safe.

## Reproducible automated runs

Run these commands from the repository root on a Mac with Xcode selected:

```sh
# Seeded Standard-mode transfers with two destinations and independent hashes.
BITMATCH_EVIDENCE_ROOT="$HOME/Desktop/BitMatch-evidence" \
  BITMATCH_SOAK_SEED=20260711 BITMATCH_SOAK_ITERATIONS=25 \
  bash Scripts/run_soak_tests.sh

# An inaccessible-destination fault inside a disposable 2 GB APFS disk image.
BITMATCH_EVIDENCE_ROOT="$HOME/Desktop/BitMatch-evidence" \
  bash Scripts/run_apfs_fault_tests.sh
```

The APFS harness changes accessibility inside its own mounted disk image; it does **not** unplug a drive or simulate a controller losing power. The soak harness uses temporary directories on the host filesystem, not a physical-device compatibility matrix. Both require space for an Xcode build; the APFS run also needs its disk image.

Each invocation creates a unique evidence directory containing `environment.txt`, build/test logs, and an Xcode result bundle when test execution starts. The APFS run retains disk-image creation and attachment output in `setup.log`, including setup failures before tests start. The soak run also retains `soak-result.json` when produced. Evidence survives test failure and fixture cleanup. The default evidence root is `${TMPDIR:-/tmp}/bitmatch-evidence`; set `BITMATCH_EVIDENCE_ROOT` to a durable location for records you intend to keep. A run stopped before tests begin may have no result bundle. Consult `exit_status`, the logs, and the result bundle together; a missing result is not a pass.

To reuse an existing build directory, set `BITMATCH_DERIVED_DATA_PATH` to an absolute path. Run harnesses sequentially when they share that directory. A caller-supplied build directory is retained; the default temporary build directory is removed. Do not point evidence or build paths at throwaway removable media used for faults. Open a retained bundle with `open /path/to/results.xcresult`.

Before sharing evidence, review it for local paths, usernames, device identifiers, and private filenames. Keep full raw records privately and publish a redacted copy. Record the revision and whether the working tree contained changes; a revision alone does not identify uncommitted source changes.

### Physical app workflow and paired measurements

`PhysicalWorkflowEvidenceTests` is an opt-in Mac app test over an already authorized, owner-marked configuration. Its `sd`, `ssdA`, and `ssdB` roles must identify three separate mounted volumes. It creates unique children only, copies a generated playable clip and streaming payload through the real coordinator, then checks MHL, automatic reports, durable History, regenerated reports, embedded preview pixels, and independent destination hashes. It does not format or eject a drive. Failed fixtures remain for inspection; cleanup refuses changed identities and never follows links.

After reserving the hardware and Mac app test slot, supply `TEST_RUNNER_BITMATCH_HARDWARE_APP_WORKFLOW=1`, `TEST_RUNNER_BITMATCH_HARDWARE_CONFIG` (the marked config JSON), and `TEST_RUNNER_BITMATCH_HARDWARE_APP_ARTIFACTS` (a private directory on the host) to `xcodebuild test -scheme BitMatch -destination 'platform=macOS' -jobs 4 -parallel-testing-enabled NO -only-testing:BitMatchTests/PhysicalWorkflowEvidenceTests/testPhysicalCardToTwoBackupsAndSavedEvidence`. Normal test runs skip this case.

`TEST_RUNNER_BITMATCH_HARDWARE_APP_BENCHMARK=1` adds three Standard/Thorough pairs with alternating order and fresh destination folders. The payload defaults to 256 MiB; `TEST_RUNNER_BITMATCH_HARDWARE_APP_MIB` accepts 32–4096 MiB. The private receipt records process CPU/physical footprint, time through automatic reports and journal settlement, pipeline return, phase durations/overlap, and per-destination pipeline bytes. Saved Check and independent test hashes happen after the measured transfer. These are steady-state measurements without cache purging or device-wide I/O attribution; they are not a cable-pull test or a general performance promise.

Before touching hardware, `TEST_RUNNER_BITMATCH_PHYSICAL_APP_HOST_SMOKE=1` runs the same evidence assertions on small host scratch folders through `testHostEvidenceHarnessSmoke`. Two ordinary tests also check that invalid configuration leaves existing files untouched and descriptor cleanup preserves an outside symlink target and a replacement directory.

## Recording and publishing physical results

Use the [hardware report template](HARDWARE_REPORT_TEMPLATE.md) for each configuration and submit it through the repository's **Hardware test report** issue form. Keep outcomes separate for baseline copy, source removal, one-destination removal, sleep, and cancellation. Mark cases you did not run as **Not tested**. A completed transfer without independent destination hashes is **Inconclusive**, not a verified pass.

The [validation status](HARDWARE_COMPATIBILITY.md) records the scope of published evidence. Add a result only after its report and evidence are available; link the report and record the tested revision. A passing result applies to that configuration and scenario, not every device from the same manufacturer.
