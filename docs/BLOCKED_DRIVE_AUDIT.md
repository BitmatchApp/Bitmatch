# Blocked-drive audit: current work

Status: incomplete and unvalidated. A filesystem call may remain blocked after its caller cancels. A worker slot and its mount reservation must remain occupied until that call actually returns.

## Changed paths

Selected-backup metadata, Setup source scans, Compare folder scans, queued-source preparation, AppleDouble review, and project-card preparation now use bounded blocking workers. Selected-backup results publish separately, and selection generations prevent stale results from being applied. Source enumeration and AppleDouble review receive explicit cancellation checks that work on blocking threads. Project-card preparation checks cancellation between enumeration and analysis.

Connected-drive capacity can now be unknown rather than zero. Unknown capacity remains visible in the Mac picker; transfer admission still performs its own checks. Network storage and unknown locality no longer produce a system physical-disk identity. These are source changes, not measured behavior.

## Remaining work

- `TransferPipeline` performs initial and final source enumeration on Swift tasks. Move both only with a bounded engine-owned executor, explicit cancellation throughout the enumeration, mount exclusion, and shutdown rules. A display timeout must not release a still-running call's reservation or imply transfer completion.
- `CameraLabelModel` runs detection, fingerprinting, and naming in a detached task. Its orchestrator and nested camera services currently use task cancellation at many stage and loop boundaries. Preserve those checks when moving filesystem work to blocking threads; merely dispatching the outer call would lose task-local cancellation. Keep detection advisory and discard stale results after source replacement.
- Audit remaining direct filesystem and metadata calls in admission, identity, evidence, report, and remote paths. Distinguish calls already protected by a bounded blocking worker from detached tasks that still occupy cooperative threads. Avoid probing unselected storage.
- Check whether worker limits should be shared across consumers and whether the mount key is adequate for mobile providers, network mounts, and multiple paths to one underlying volume. A lexical key is a scheduling hint, not proof of device identity.

## Validation

Use deterministic held/released calls to test cancellation, reselection, healthy-drive progress, mount replacement, late results, busy handling, and bounded workers and descriptors. Then measure responsiveness with explicitly selected disposable physical drives and network storage. Report simulator, synthetic, and physical results separately. See [the pending-work checklist](validation/PENDING_LOW_CPU_WORK.md).
