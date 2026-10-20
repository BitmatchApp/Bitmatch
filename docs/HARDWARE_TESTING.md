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

The APFS harness changes accessibility inside its own mounted disk image; it does **not** unplug a drive or simulate a controller losing power. The soak harness uses temporary directories on the host filesystem, not a physical-device compatibility matrix. Both need the selected Xcode toolchain. The soak needs space for a Release engine test build; the APFS run needs an app build and its disk image.

Each invocation creates a unique evidence directory containing `environment.txt` and build/test logs. The APFS run also retains an Xcode result bundle when execution starts, and disk-image creation/attachment output in `setup.log`. The soak runs the engine's actual selected XCTest, with `memory.json` and a format-2 `soak-result.json` recording completed iterations, source hashes before/after, empty-folder inventory, and both backups' hashes. It requires one passing test without skips and exact iteration coverage; a missing or partial receipt is not a pass.

The soak samples the actual worker's physical footprint at a requested 10 ms interval, verifies its PID/executable identity and requests SIGINT at 1 GiB or the runtime limit. `BITMATCH_SOAK_MAX_SECONDS` defaults to 900 (maximum 3600). Missing samples fail the run. OS calls and synchronous work may delay sampling or interruption; this is not an out-of-memory survival guarantee or a leak proof. Failed or interrupted fixtures are retained, and normal cleanup removes only the marked disposable work directory. Review raw logs before sharing them.

The source layout and file sizes are fixed. Payload bytes use the seed's low eight bits, so patterns repeat after 256 consecutive seeds. More iterations add duration, not unlimited input diversity.

The default evidence root is `${TMPDIR:-/tmp}/bitmatch-evidence`; set `BITMATCH_EVIDENCE_ROOT` to a durable location. For reusable builds, set `BITMATCH_ENGINE_SCRATCH_PATH` for the soak or `BITMATCH_DERIVED_DATA_PATH` for the APFS app harness. Run harnesses sequentially when sharing a build directory. Caller-supplied build directories are retained; default disposable builds are removed after success. Do not put evidence or builds on removable media used for faults. Only the APFS harness emits `results.xcresult`; open that bundle with `open /path/to/results.xcresult`.

Before sharing evidence, review it for local paths, usernames, device identifiers, and private filenames. Keep full raw records privately and publish a redacted copy. Record the revision and whether the working tree contained changes; a revision alone does not identify uncommitted source changes.

### Physical engine matrix

`Scripts/test-physical-drives.py` provisions fresh, owner-marked folders on three explicitly selected physical volumes. It runs Quick, Standard, Thorough and Paranoid with pipelining off/on, plus a Standard retry that preserves existing MHL histories. It never formats or ejects those drives or selects existing footage.

After a failed or interrupted run, the runner retains its marked folders, backing image if used, and build for inspection. It detaches an owned image only after the child process ends and its identity and attachment checks pass. A live child or uncertain attachment leaves everything in place. `summary.json` records the retention policy and remaining roles; inspect that evidence before requesting ownership-checked cleanup. Passing runs keep the existing descriptor-checked cleanup. Never remove a volume's contents to clean a test fixture.

### Physical app workflow and paired measurements

`PhysicalWorkflowEvidenceTests` is an opt-in Mac app test over an already authorized, owner-marked configuration. Its `sd`, `ssdA`, and `ssdB` roles must identify three separate mounted volumes. It creates unique children only, copies a generated playable clip, streaming payload and empty sidecar through the real coordinator, then checks MHL, automatic reports, durable History, regenerated reports, embedded preview pixels, and independent destination hashes. It does not format or eject a drive. Failed fixtures remain for inspection; cleanup refuses changed identities and never follows links.

After reserving the hardware and Mac app test slot, supply `TEST_RUNNER_BITMATCH_HARDWARE_APP_WORKFLOW=1`, `TEST_RUNNER_BITMATCH_HARDWARE_CONFIG` (the marked config JSON), and `TEST_RUNNER_BITMATCH_HARDWARE_APP_ARTIFACTS` (a private directory on the host) to `xcodebuild test -scheme BitMatch -destination 'platform=macOS' -jobs 4 -parallel-testing-enabled NO -only-testing:BitMatchTests/PhysicalWorkflowEvidenceTests/testPhysicalCardToTwoBackupsAndSavedEvidence`. Normal test runs skip this case.

`TEST_RUNNER_BITMATCH_HARDWARE_APP_BENCHMARK=1` adds three Standard/Thorough pairs with alternating order and fresh destination folders. The payload defaults to 256 MiB; `TEST_RUNNER_BITMATCH_HARDWARE_APP_MIB` accepts 32–4096 MiB. The private receipt records process CPU/physical footprint, time through automatic reports and journal settlement, pipeline return, phase durations/overlap, and per-destination pipeline bytes. Saved Check and independent test hashes happen after the measured transfer. These are steady-state measurements without cache purging or device-wide I/O attribution; they are not a cable-pull test or a general performance promise.

Before touching hardware, `TEST_RUNNER_BITMATCH_PHYSICAL_APP_HOST_SMOKE=1` runs the same evidence assertions on small host scratch folders through `testHostEvidenceHarnessSmoke`. Two ordinary tests also check that invalid configuration leaves existing files untouched and descriptor cleanup preserves an outside symlink target and a replacement directory.

### Selected-device OS I/O observer

`Scripts/sample-device-io.swift` is a separate, read-only Mac observer for the
already authorized `sd`, `ssdA` and `ssdB` roots in that marked configuration.
It checks the nonce, exact owner marker, pinned directory identity and volume
UUID privately. Disk Arbitration supplies the actual selected volume's IOMedia;
bounded ancestor traversal must identify one unique `IOBlockStorageDriver`.
It never guesses a disk number or sums host-wide I/O. Missing/ambiguous counters,
shared drivers, replacement devices and resets stay explicit, rather than
becoming zero bytes. It reads only the config/owner markers and OS metadata;
it does not start a transfer, open media devices, purge caches, format or eject.

Build on the host, then keep output in a private host directory:

```sh
xcrun swiftc -swift-version 6 -parse-as-library -O \
  -module-cache-path /tmp/bitmatch-device-io-cache \
  Scripts/sample-device-io.swift -o /tmp/bitmatch-device-io
/tmp/bitmatch-device-io --self-test
/tmp/bitmatch-device-io --config "$private_hardware_config" \
  --samples 60 --interval 1 > "$private_observation_log"
```

The self-test uses mocked counters/mappings and tiny host scratch files, including
FIFO/symlink/oversized config controls; it does not access physical volumes.
Sampling accepts 1–600 snapshots, intervals of 0.2–60 seconds, and a requested
window no longer than one hour. Output is bounded to those snapshots. OS calls
themselves can still block on an unhealthy system; this is not a hard deadline
or an unplug watchdog. Exit 2 means invalid arguments/configuration or a fatal
read/export error; exit 3 means at least one unavailable/reset sample. Exit 0
describes observer availability, never transfer success.

JSONL contains only generic roles, counters, controlled status/reason codes,
UTC timestamps and monotonic `uptimeSeconds`. The first sample is a baseline;
later rows include deltas and their elapsed interval. Sampling is sequential,
not a simultaneous hardware timestamp. Align windows to the app receipt's
transfer-start/settled uptime so later independent hashes, Saved Check and
regenerated reports are not attributed to the measured transfer.

Apple documents these [read counters](https://developer.apple.com/documentation/iokit/kioblockstoragedriverstatisticsbytesreadkey)
and [write counters](https://developer.apple.com/documentation/iokit/kioblockstoragedriverstatisticsbyteswrittenkey)
as cumulative since the block driver was instantiated. Deltas include **all
processes and partitions using that driver**, filesystem metadata, background
work and any other tests on the same selected device. They are OS storage-stack
observations, not app-only accounting or proof of NAND/platter traffic. The
app's `F_NOCACHE` request does not prove a cold controller/bridge/device cache.
No cache-purge, power-loss, durability or integrity claim follows from these
counters; copy evidence and independent readback remain separate.

## Recording and publishing physical results

Use the [hardware report template](HARDWARE_REPORT_TEMPLATE.md) for each configuration and submit it through the repository's **Hardware test report** issue form. Keep outcomes separate for baseline copy, source removal, one-destination removal, sleep, and cancellation. Mark cases you did not run as **Not tested**. A completed transfer without independent destination hashes is **Inconclusive**, not a verified pass.

The [validation status](HARDWARE_COMPATIBILITY.md) records the scope of published evidence. Add a result only after its report and evidence are available; link the report and record the tested revision. A passing result applies to that configuration and scenario, not every device from the same manufacturer.
