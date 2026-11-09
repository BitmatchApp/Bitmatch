# Verified sibling repair: proposed contract

Status: design only. No sibling repair or new safety verdict is implemented by this document.

The sibling-recovery idea is also present in [FilmCan](https://github.com/qtld88/FilmCan), which is GPL-licensed. This contract is written for BitMatch's own engine and does not incorporate that project's code. [SD Offload's staging-maintenance changes](https://github.com/t0nyz0/SD-Offload/commit/9d5bae578636002df5084779a962203605df3936) motivate the explicit treatment of durable evidence and intentional deletion; BitMatch does not adopt its staging or cleanup implementation here.

## Purpose and scope

Offer a new, explicitly requested repair attempt when a previously verified backup can supply files for another backup and the card is unavailable. A prior receipt identifies candidate content; it does not prove that the sibling is still intact. A successful repair establishes what was read and written in the new attempt. It does not establish that the original card was healthy or safe to erase.

## Admission

- Require an unambiguous previous attempt, file inventory, sizes, and supported strong digests. Reject missing, conflicting, unsupported, or incomplete evidence; never infer verification from a filename or green historical label alone.
- Ask the operator to select the sibling and destination. Resolve permissions and revalidate original folder and volume identities. A changed or unprovable identity requires a new selection and explicit validation, not an automatic continuation.
- Require evidence that the sibling and repair destination are distinct storage devices. Unknown, composite, network, and provider-backed identities cannot establish physical independence merely because their paths differ. Do not offer sibling repair when the required distinction cannot be proved.
- Retain the existing source attempt and its outputs. An output that is missing or was deliberately removed is not silently reconstructed by background recovery.

## Attempt and publication

1. Create and durably record a separate attempt linked to the prior attempt, the chosen sibling, and the target. Record the expected evidence and its scope before writing.
2. Pin and reread each sibling file, verify its size and every required digest against the prior evidence, and check identity and stability around the read. Reject changed files and any disagreement. An earlier verification is not enough.
3. Write only to a new, exclusively owned output. Reuse the existing no-overwrite and ownership checks; preserve a conflicting or failed prior output. Do not delete, rename, or mark a file belonging to another writer.
4. Independently read the new output and compare it with the recorded digests and the verified sibling read. Check source, output, and root identity again before publishing evidence. A failure, cancellation, or unprovable handoff remains an issue.
5. Save separate evidence for sibling revalidation, output verification, and publication. Report their timestamps and scope, the linked prior attempt, and all failures. A later report or manifest failure must not be described as a media mismatch, and must not erase the verified-media facts.

Do not introduce a temporary-file cleanup policy until exclusive ownership, interruption recovery, and replacement races are specified and validated for each filesystem. On restart, an unfinished attempt is interrupted; inspecting or cleaning its artifacts requires fresh identity and ownership proofs. Never promote a partial attempt to completed solely because an output exists.

## Presentation and tests

Show “verified against an earlier record using a backup” with the actual recorded algorithms and scope. Keep card-health warnings and card-safe-to-erase claims separate. History and exported evidence must preserve all attempts, including failed and interrupted work. A previously verified sibling is a historical fact until reread in this attempt.

Before enabling the action, exercise replacement during each read and publication boundary; stale, malformed, missing, and contradictory evidence; shared or unknown storage; absent or deliberately deleted files; output name races and other-writer files; cancellation, disconnection, and restart at every state; and report/manifest failures after media verification. Include both app platforms, real filesystem behavior, independent digest references, and owned disposable media. Record synthetic and physical results separately.
