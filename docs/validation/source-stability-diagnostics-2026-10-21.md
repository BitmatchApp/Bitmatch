# Source-stability diagnostics — October 21, 2026

This candidate is isolated, unmerged and not yet compiled or tested. It follows a retained physical SD-to-two-SSD matrix that stopped during Thorough without pipelining: two rows reported “Source file changed during copy.” The previous test did not record the affected file or changed field. The cause is unresolved; a failed guard is not proof of damaged media or a BitMatch defect.

## Change

Source stability rejections now record a closed guard stage, changed-field names, identity-presence/lookup flags and, when available, POSIX errno and verification ordinal. They never record footage names, paths, raw device/inode values, timestamps, digests or error descriptions. Existing private free-form logs remain private.

Instrumentation reuses already-read metadata. It adds no media lookup or read, preserves the guard order, rethrows original lookup errors and keeps the existing rejection errors. Cancellation stays a control signal. This does not loosen identity checks, retry a rejected read, or turn an interruption into success.

The pipeline's final source-coverage guard can supersede an earlier per-file error with its overall “card changed” result. Regression tests check the original error at the per-file callback and separately require that final fail-closed result; they do not change this policy to retain an earlier message.

The physical test adds relative synthetic-file diagnostics with pre/open/post metadata and a failure-only uncached content comparison. Its opt-in Thorough recheck accepts only a validated fixture child, captures a new baseline and creates four exclusive sets of two-backup outputs. It never reseeds, deletes or automatically retries the source. That new baseline cannot establish what happened during the earlier failed run.

Physical workflows also use a private diagnostic store across the pipeline, MHL, Check and assertions, with retained receipts. The direct small retry has its own scope. A host-only regression checks nested event isolation and restoration. Earlier physical tests lacked this override and could write synthetic events into the default unsandboxed application-support ring. This was not measured, and does not establish that the signed app's separate container was affected. Existing logs are not read, erased or repaired by this change; saved transfer history is separate.

## Validation to run

- Engine regressions for closed fields/redaction, old-record decoding, copy mutation, cancellation, verification ordinal and a missing final comparison source.
- Full engine tests, the Mac app suite and iPhone/iPad build.
- The focused physical recheck after the active large-file test ends; retain failed fixtures and exact source/diagnostic observations.

A tiny independent APFS experiment confirmed that renaming an open file changed its descriptor ctime on this Mac. The copy-mutation test therefore expects the earlier descriptor guard, rather than incorrectly expecting the later pathname guard. This test-design observation does not explain the physical SD failure.

No release, signing or updater change is included. Field reports #10 and #23 remain unresolved.
