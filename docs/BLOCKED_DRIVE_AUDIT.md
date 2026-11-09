# Blocked-drive audit: current work

Status: incomplete and unvalidated. A filesystem call may remain blocked after its caller cancels. A worker slot and its mount reservation must remain occupied until that call actually returns.

## Changed paths

Selected-backup metadata, Setup source scans, Compare folder scans, queued-source preparation, AppleDouble review, and project-card preparation now use bounded blocking workers. The production `DriveAccessWorker.shared` instance and the coordinator's default drive-access worker are now also created with `useBlockingThreads: true`, so their synchronous filesystem work no longer runs on Swift's cooperative executor; injected workers in tests are unchanged. Selected-backup results publish separately, and selection generations prevent stale results from being applied. Source enumeration and AppleDouble review receive explicit cancellation checks that work on blocking threads. Project-card preparation checks cancellation between enumeration and analysis.

Connected-drive capacity can now be unknown rather than zero. Unknown capacity remains visible in the Mac picker; transfer admission still performs its own checks. Network storage and unknown locality no longer produce a system physical-disk identity. These are source changes, not measured behavior.

## Remaining work

- `TransferPipeline` initial and final source enumeration, `LocalFileAccess.getFileList`, and the iOS file-list service now run on the engine's `BoundedBlockingExecutor` (bounded concurrency and queue, blocking dispatch threads, caller cancellation settles without releasing the slot until the call returns, explicit cancellation checks inside enumeration). Mount exclusion inside the engine executor is by concurrency bound only; per-mount reservation remains the app workers' job at admission. These changes are source-only and unvalidated until the held-call tests run.
- `CameraLabelModel` detection, fingerprinting, and naming now run on a bounded blocking `DriveAccessWorker`; the orchestrator takes an explicit cancellation check (defaulting to task cancellation for existing callers) fed by the worker, and stale results are still discarded by generation. `SharedCameraDetectionService` likewise routes layout classification, orchestrator heuristics, and its file listing through the engine blocking executor. Nested camera services still rely on stage-boundary checks rather than per-loop checks. Source-only and unvalidated.
- Audit remaining direct filesystem and metadata calls in admission, identity, evidence, report, and remote paths. Distinguish calls already protected by a bounded blocking worker from detached tasks that still occupy cooperative threads. Avoid probing unselected storage.
- Check whether worker limits should be shared across consumers and whether the mount key is adequate for mobile providers, network mounts, and multiple paths to one underlying volume. A lexical key is a scheduling hint, not proof of device identity.

## Validation

Use deterministic held/released calls to test cancellation, reselection, healthy-drive progress, mount replacement, late results, busy handling, and bounded workers and descriptors. Then measure responsiveness with explicitly selected disposable physical drives and network storage. Report simulator, synthetic, and physical results separately. See [the pending-work checklist](validation/PENDING_LOW_CPU_WORK.md).
