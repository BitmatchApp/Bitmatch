# Cloud destination: proposed contract

Status: design only. BitMatch does not yet provide this destination or a cloud safety verdict. Provider features and APIs must be verified against their current documentation before implementation.

## Evidence and authority

The local transfer remains authoritative for the source and local backups. A cloud job is a separate, linked attempt with its own plan, state, evidence, and failures. An upload acknowledgment, object size, ETag, multipart completion, or provider metadata alone does not establish an independent readback match. Cloud verification requires a fresh read of the committed object, checked against a supported digest of the exact pinned source or a revalidated local backup. Keep card-source provenance, local readback, upload, and cloud readback as separate facts.

The ordinary safe-to-erase rule must continue to use its existing source and local-backup requirements. A remote upload cannot substitute for an independent source reread where the chosen verification mode requires one. Cloud availability, object versioning, or storage-class guarantees do not prove independent local devices or original camera correctness.

## Job lifecycle

1. Require an explicit destination, permission, and disclosure of provider, account, object namespace, expected transfer, and potential cost. Keep credentials in platform credential storage, not the job export, journal, logs, reports, or diagnostics.
2. Before upload, persist a bounded plan and stable attempt ID. Pin the source or revalidate the local backup and its saved digest and identity. Refuse stale, incomplete, conflicting, unsupported, or inaccessible evidence.
3. Publish into an attempt-owned namespace with an exclusive or conditional creation operation. A provider must demonstrate the semantics needed to prevent overwriting existing objects, including concurrent writers and retries; otherwise the operation fails closed. A unique-looking object name is not ownership proof by itself.
4. Persist multipart identifiers and confirmed part state durably before relying on them for recovery. On restart, reconcile with the provider and original plan; never assume a timed-out request failed or duplicate an ambiguous mutation. Preserve earlier evidence and surface unknown outcomes. Do not claim byte-offset resume unless continuity and provider semantics are established.
5. Finalize only after the complete object is committed and a fresh independent readback matches the required digest and size. Record the object version or equivalent identity where supported, readback method, time, digest, and scope. Report an upload-only result as unverified.
6. Treat manifests and reports as separate handoffs. Their failure cannot erase the media result or become a media mismatch. Publish evidence without overwriting previous evidence; retry as a new linked action after revalidating the backing object.

## Staging and cleanup

Staging is optional and must not touch the card. Retire a staged file only after the required readback and durable checkpoint, with a pinned identity and proof that BitMatch owns that exact file. Pause or coordinate cleanup with active transfers. A missing destination or unknown deletion intent retains the recovery copy and raises an issue; it is not permission to recreate a previously deleted object automatically. Persist explicit user deletion intent before any future delete action. Preserve unknown files, links, changed entries, and partial manifests. A crash between any two steps must not make cleanup or completion appear successful.

Do not transplant another application's staging cleanup code into BitMatch's fan-out engine without a separate compatibility, ownership, and license review. This contract takes the recovery lesson from [SD Offload's staging work](https://github.com/t0nyz0/SD-Offload/commit/9d5bae578636002df5084779a962203605df3936), without adopting its implementation.

## Release gates

Exercise duplicate and out-of-order requests, ambiguous timeouts, partial multipart uploads, provider restarts, object replacement, access revocation, source removal, quota and billing errors, corrupted reads, version changes, credential redaction, cancellation, app restart, and cleanup races. Verify provider-specific conditional-write and readback guarantees against authoritative documentation and real disposable accounts. Record synthetic, provider, filesystem, and physical-device results separately. Do not enable a provider until its semantics and failure recovery pass these checks.
