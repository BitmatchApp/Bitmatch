# Assurance wording audit fixes — October 21, 2026

Follow-on to `docs/VERIFICATION_ASSURANCE_AUDIT.md` (October 14) and the
Wonder wording audit of the same day. Read-only audit across History,
Finish/queue, reports, verdict core, mode wording and remote surfaces;
fixes below are the code-provable mismatches. Signed-app/physical
wording checks remain open in the audit doc.

Source: worktree `wt-assurance-audit`, branch
`todo/assurance-audit-20261021`.

## Fixes

1. **P1 — unresolved drive identity satisfied safety counts.**
   `BackupIndependencePolicy.independentCopyCount` counts each
   unresolved destination as independent (deliberate setup policy), and
   the project finalizer consumed it, so two folders on one unresolved
   (network/composite/iOS) volume could satisfy
   `requiredLocalCopyCount`. Safety gates now use the new
   `provenIndependentCopyCount` (resolved distinct groups only).
   Setup/start gating is unchanged — transfers to unresolved storage
   can still start; they just cannot prove independence.
2. **P1 — swapped file reported at the wrong name.** When marking's
   post-rename check found a swap and restore failed, the result still
   pointed at the original name. It now reports the real marked path
   with outcome `swappedNotRestored` and matching History wording.
3. **P2 — weaker verified test in final evidence.**
   `PhotographerJobModels.isVerified` accepted any success row with a
   checksum; it now requires `isVerifiedStatus`, so a copied-unverified
   row carrying a checksum cannot count as verified.
4. **P2 — completed-with-no-rows resolved to success.**
   `CompletionVerdict.resolve` now returns `.issues` when a completed
   claim has no successful rows.
5. **Marking wording reaches reports.** The canonical note lives on
   `ResultRow.markingNote` (single source; History delegates to it) and
   is now appended in CSV status and JSON report items. JSON exports
   already carried the structured field.

## Tests

- `BackupIndependencePolicyTests`: proven count excludes unresolved
  (0 for an unresolved pair, policy count still 2).
- `ResultPresentationTests`: completed-true with zero rows → issues.
- `TransferLibraryPresentationTests`: `swappedNotRestored` wording.
- Full engine suite: XCTest 344 executed (86 skipped), Swift Testing
  269 — all passing. App suites above pass.
