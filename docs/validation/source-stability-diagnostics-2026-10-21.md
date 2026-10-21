# Source-stability diagnostics — October 21, 2026

This candidate is isolated and unmerged. It follows a retained physical SD-to-two-SSD matrix that stopped during Thorough without pipelining: two rows reported “Source file changed during copy.” The previous test did not record the affected file or changed field. The cause is unresolved; a failed guard is not proof of damaged media or a BitMatch defect.

## Change

Source stability rejections now record a closed guard stage, changed-field names, identity-presence/lookup flags and, when available, POSIX errno and verification ordinal. They never record footage names, paths, raw device/inode values, timestamps, digests or error descriptions. Existing private free-form logs remain private.

Instrumentation reuses already-read metadata. It adds no media lookup or read, preserves the guard order, rethrows original lookup errors and keeps the existing rejection errors. Cancellation stays a control signal. This does not loosen identity checks, retry a rejected read, or turn an interruption into success.

The pipeline's final source-coverage guard can supersede an earlier per-file error with its overall “card changed” result. Regression tests check the original error at the per-file callback and separately require that final fail-closed result; they do not change this policy to retain an earlier message.

The physical test adds relative synthetic-file diagnostics with pre/open/post metadata and a failure-only uncached content comparison. Its opt-in Thorough recheck accepts only a validated fixture child, captures a new baseline and creates four exclusive sets of two-backup outputs. It never reseeds, deletes or automatically retries the source. That new baseline cannot establish what happened during the earlier failed run.

Physical workflows also use a private diagnostic store across the pipeline, MHL, Check and assertions, with retained receipts. The direct small retry has its own scope. A host-only regression checks nested event isolation and restoration. Earlier physical tests lacked this override and could write synthetic events into the default unsandboxed application-support ring. This was not measured, and does not establish that the signed app's separate container was affected. Existing logs are not read, erased or repaired by this change; saved transfer history is separate.

## Validation

- Focused source-diagnostics gate `engine-source-diagnostics-20261021T050125Z` ran 14 XCTest cases: 0 skipped, 0 failed, 0.219 seconds. The selection was `DestinationIdentityDiagnosticTests` plus `PhysicalDriveTransferTests/testPrivatePhysicalDiagnosticsScopeCapturesWorkflowEventsAndRestoresOuterStore`, on source commit `c5af0e27`.
- Physical Thorough recheck `physical-thorough-20261021T050244Z` ran 1 test with 0 skips and 0 failures in 481.390 seconds. It completed four operations in two cycles, each with pipelining off and on and two SSD backups. A fresh baseline's source hashes were compared after every operation. Peak worker memory was 30 MiB.
- The initial focused compile found a duplicate local variable name in the new test; that test typo was corrected. The first executed run then exposed seven wrong-layer assertions across three mutation tests: they inspected the final pipeline-level `TransferPipeline` code 256 result where the test intended to inspect the earlier per-file guard error. The tests now capture that original error through `onFileResult` and separately assert the final fail-closed result. These were test expectation corrections; they did not establish or fix a production behavior defect.
- The earlier physical Thorough failure was not reproduced by the recheck and remains unresolved. The recheck took a new baseline; it does not explain the earlier run. No fix to the physical failure is claimed.
- The full combined engine suite, Mac app suite and iPhone/iPad build remain pending. This validation does not establish a signed-app or field-device reproduction.

A tiny independent APFS experiment confirmed that renaming an open file changed its descriptor ctime on this Mac. The copy-mutation test therefore expects the earlier descriptor guard, rather than incorrectly expecting the later pathname guard. This test-design observation does not explain the physical SD failure.

No release, signing or updater change is included. Field reports #10 and #23 remain unresolved.
