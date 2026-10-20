# Process-death recovery matrix

Twenty local scenarios killed a disposable engine worker with SIGKILL on real
mounted APFS, journaled HFS+, exFAT and FAT32 sparse images. No selected physical
drive was used. The source was a synthetic 12 MiB + 137-byte file on the host.
The images and source therefore do not establish independent physical backups.

| Boundary | APFS | HFS+ | exFAT | FAT32 |
| --- | --- | --- | --- | --- |
| Copy stopped after one chunk was written | Pass | Pass | Pass | Pass |
| Copy and verification drained, before MHL | Pass | Pass | Pass | Pass |
| Private MHL staged, before exclusive publication | Pass | Pass | Not applicable | Not applicable |
| Public MHL directory claimed, still empty | Not applicable | Not applicable | Pass | Pass |
| Public MHL manifest written, before chain | Not applicable | Not applicable | Pass | Pass |
| Manifest and chain written, before COMPLETE record | Not applicable | Not applicable | Pass | Pass |
| MHL fully published, before history settlement | Pass | Pass | Pass | Pass |

The parent launches only this test bundle's explicit worker method through
Foundation `Process`. The child validates the owned root nonce, device/inode,
mounted filesystem and parent identity. It persists a running transfer journal,
executes the actual transfer/readback and reaches an existing engine boundary.
It synchronizes a phase breadcrumb, then stops itself with SIGSTOP. The parent
checks the breadcrumb PID and actual stopped state, examines the on-disk phase,
sends SIGKILL to that direct worker and requires a bounded termination callback
with signal 9. Foundation is the sole child reaper; there is no `fork`/`waitpid`
or cancellation-error substitute for process death.

Every reopened journal persisted `interrupted`, without calling it cancelled or
completed. Source names and SHA-256 values stayed unchanged. Existing files,
orphaned stages, partial output and unrelated destination sentinels were
preserved through retry. The FAT transfer markers matched the actual stopped
state. Partial final media was refused; complete media was independently reread.
Empty history reservations and incomplete public histories blocked replacement.
Unpublished or incomplete histories could not produce an intact saved Check.
Recoverable retries produced a new history that passed a fresh saved Check.

The positive boundary matters: fully published histories remained intact after
the kill and still passed a fresh read and inventory-chain check. Their transfer
journals remained interrupted because terminal settlement had not happened.
Retry preserved those histories and refused to replace them. Process death does
not automatically invalidate evidence that was already completely published.

The final focused run scheduled three XCTest methods: two passed, the internal
worker method skipped in the parent, and there were zero failures. Its twenty
child scenarios completed in 11.790 seconds. These are scenarios inside one
parent test, not twenty additional XCTest passes. Ordinary discovery schedules
three methods, passing the ownership guard and skipping both opt-in methods.
An earlier four-case APFS/exFAT smoke run also passed. Intermediate smoke work
found a harness-only `Process.waitUntilExit` hang after a child had already
exited; the final harness uses bounded termination callbacks instead.
Those wait bounds do not preempt arbitrary synchronous filesystem or OS calls.

Run the smoke before the full matrix:

```sh
BITMATCH_PROCESS_DEATH_MATRIX=smoke swift test \
  --package-path Packages/BitMatchEngine --jobs 4 --disable-swift-testing \
  --filter ProcessDeathRecoveryTests
BITMATCH_PROCESS_DEATH_MATRIX=full swift test \
  --package-path Packages/BitMatchEngine --jobs 4 --disable-swift-testing \
  --filter ProcessDeathRecoveryTests
```

All final images were detached without force, and disposable image/source
payloads were removed. Compact journals, child logs, phase breadcrumbs and a
scenario receipt were retained privately. Failures retain their owned fixtures.
No production change was required. This tests process-death recovery, not power
loss, device removal, every possible instruction boundary, or the cause of an
operating-system memory termination.
