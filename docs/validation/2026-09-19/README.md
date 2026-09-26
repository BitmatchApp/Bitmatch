# Release-readiness work: audit priorities 1–6

Source validation on 2026-09-19 of the working tree based on `08b34ba` plus
uncommitted changes (17 modified files, 1 deleted, 1 added; full list in git
status output retained with this session's logs). Host: Apple Silicon,
macOS 27.0, Xcode 27.0 (27A266a). This does not describe the downloadable
v0.1.4 binary, which remains the public release.

## What changed since the audit

The 2026-09-19 release-readiness audit named two integrity fixes, seven
priorities, and small interface fixes. Completed in source:

- **Integrity:** cancellation during the final comparison checksum now stays
  cancelled (checked after enumeration, after each file's checksum work,
  before returning stats, and before publishing); source-tree preflight
  applies the same root-only volume-metadata skip as the copy manifest.
- **Priority 1:** `CompareStats` retains sorted missing/extra/mismatched
  paths; Mac and mobile compare screens list them with copyable text and
  JSON/CSV export. Stale results clear when either folder changes.
- **Priority 2:** mobile completion export builds from the finished
  transfer's journal record (authoritative rows, project provenance, ASC MHL
  flag) through the same document history uses, with a real save flow and
  visible errors. The folder-info summary path (`ReportCoordinator`) was
  removed. History exports gained the same provenance fields.
- **Priority 3:** expired access is recoverable. `staleResourceIndexes`
  names dead locations; `reauthorize` refreshes a bookmark only for the
  identical original volume and folder (identifiers plus folder birthtime,
  with URL resource-cache handling), never a substitute. A shared
  Reconnect flow exists on all platforms.
- **Priority 4:** a failed requested automatic report now fails the
  completion into issues: the message keeps "Operation completed
  successfully" beside "report export failed", the journal retains the
  issue, and the queue stops. The exporter throws instead of alerting
  into the void.
- **Priority 5:** the Mac off-site queue restores persisted work at launch,
  runs what is due, arms a one-shot wake-up for the earliest deferred
  backoff, bounds transient retries at 8 attempts before failing closed
  with a manual-retry path, and routes pause/retry/cancel through the
  queue actor. The dashboard shows Retry/Cancel for actionable remote
  states. Pause now actually parks work; cancel and retry leave verified
  uploads alone. The bypassing store-direct pause/retry paths were removed.
- **Quick wins:** four missing string interpolations fixed, cancelled
  transfers stay in the Queue tab, neutral "Backup folder" wording,
  Settings accessibility labels.
- **Priority 6:** the one supported handoff workflow is written down in
  [../ascmhl/SUPPORTED_WORKFLOW.md](../ascmhl/SUPPORTED_WORKFLOW.md); stale
  "full MHL compliance / complete verification chain" claims were removed
  from FEATURES.md and the README points at the scope doc.

## Automated checks

- macOS unit and integration suite: `bash test.sh mac-test` — exit 65.
  **522 passing executions (503 unique tests), 1 failed, 2 skipped.**
  The failure is `SafetyValidatorTests.testRejectsPathTraversal`, which
  also fails on the clean tree and is unrelated to this work. Skips: the
  opt-in soak test (`BITMATCH_RUN_SOAK=1`) and the nested-metadata
  collision test, which needs a case-sensitive filesystem.
  [Recorded summary](test-summary.json).
- Shared mobile target: `bash test.sh ipad-build` — exit 0.
- Mac target: `bash test.sh mac-build` — exit 0.
- Release configurations: `bash test.sh release-builds` — exit 0 for both
  the Mac and the mobile target.

New coverage includes cancellation during the final checksum, preflight and
manifest agreement on volume metadata, retained comparison paths and their
export, completion exports from the journal record, stale-location
detection and identity-checked reauthorization (including a same-path
replacement and URL resource-cache behavior), report-failure completion
with queue stop, and remote-queue startup restore, deferred wake-up,
retry exhaustion, pause, and terminal-state protection.

## Not done (needs hardware or a release decision)

- Physical storage validation: no cards, readers, hubs, APFS/exFAT
  devices, disconnect/reconnect runs, full destinations, or iOS
  interruption/relaunch results were recorded. The physical-results table
  below stays "Not tested".
- Receiving-tool acceptance for ASC inventories (Hedge/OffShoot, ShotPut
  Pro, Silverstack) and production camera media.
- Version bump, signing, notarization, and publishing. The build checks above
  pass; the recorded Mac test run still had the failure described above.

A later [review and fix pass](review.md) records the corrected test run and
additional integration fixes.
