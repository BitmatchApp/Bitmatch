# Pending validation for current work

This is a checklist, not a test result. No build, simulator, or test was run for this batch while CPU capacity was reserved. Record the source revision, exact commands, logs, failures, skips, and environment when validation begins. Fix failures and rerun the relevant gates before relying on any change.

## First checks

1. Review the complete working-tree diff and resolve any compile errors or conflicting changes.
2. Run the repository's engine and Mac suites: `bash test.sh engine-test` and `bash test.sh mac-test`. Run `bash test.sh ipad-build`, then the iPhone/iPad tests with an available simulator destination as described in [development](../../DEVELOPMENT.md).
3. Run the release builds and signed-app checks only when preparing a release, following the standing gates in [TODO](../TODO.md). Keep the existing CI policy.

## Focused coverage

- Bounded workers: hold one or more filesystem operations, select a healthy drive, cancel and reselect, replace/unmount a drive, and release the held call. Check worker/descriptor bounds, capacity unknown versus zero, stale results, and responsiveness. Include Setup, Compare, queue preparation, AppleDouble review, and project-card preparation. A timed-out call can still occupy a worker until the OS returns.
- Storage identity: check known local, network, unavailable-locality, and composite storage. Network and unknown locality must remain unresolved; distinct local identifiers alone do not establish the physical layout of a composite volume.
- Evidence: run the classic and ASC compatibility suites, including the Offloader writer fixtures, BOM variant, unsupported and conflicting digests, digests and sizes carried across generations, changed inventory and media, chain changes, and unchained inventories. Independently verify fixture schemas and expected digests. Check ASC reader behavior with each required algorithm and retain compatibility failures.
- Progress and reports: cover multiple destinations, zero-byte and reused files, retries, failed readback, partial plans, report truncation, and source-read/source-change errors in queue, Review, History, CSV, JSON, and PDF. Check that progress counts never become a final verdict.
- Portable recipes: verify version 1 compatibility, strict version 2 parsing, privacy, duplicate handling, preview invalidation, store failure rollback, persistence, and no automatic selection on Mac, iPad, and iPhone.
- Recovery: interrupt a retry and reopen the journal; confirm the original failure and linked interrupted attempt remain durable. Exercise the broader owned-data interruption matrix before claiming crash recovery.
- UI: inspect narrow iPhone, iPad multitasking, and Mac windows; include Reduce Motion and VoiceOver where affected. Check connected-drive labels and the picker with unavailable, zero, and known capacity.

## Remaining boundaries

Use disposable, explicitly selected media for physical filesystem and disconnect checks, following [hardware testing](../HARDWARE_TESTING.md). Run the outstanding large-app memory probes and retained report checks separately. Neither synthetic nor simulator success establishes physical-device, power-loss, network-storage, composite-drive, or field-report behavior. The open field reports stay open unless their own evidence supports resolution.

Source-fault warnings across later `retryOf`-linked attempts and the blocked-drive executor/camera changes were implemented in source on November 9 and are covered by the focused checks above (executor held-call tests, camera detection tests, lineage and outcome-presentation tests, ASC compatibility matrix including the BOM variant). They remain unvalidated until those runs happen. Sibling repair, imported-drive History, and portable destination configuration are not implemented by this checklist. Follow their separate contracts and the live todo list.
