# Quick recovery and result summaries — October 20, 2026

Recovery summaries and finished-result counters now honor the known verification mode. A saved Quick attempt cannot count a legacy “Match” or “Verified” row as a verified copy, reused verification or verified bytes. Interrupted Quick destinations describe copied-but-unverified results. Failures and exclusions retain their precedence.

Destination summaries also recognize explicitly unverified legacy statuses even when a checksum is present. Their wording says the contents were not verified, without inferring a completed size check solely from old status text. Callers without a known mode retain their existing status-based behavior.

This changes derived summaries only. Stored row IDs, statuses, checksums and outcomes remain intact. Existing verdict reconciliation, export behavior and verification policies are unchanged.

## Focused coverage

The Mac app-host run passes 76 logical tests, expanded to 98 executions, with no failures or skips. Cases cover all four modes, completed/cancelled/interrupted saved-record replay, copied/reused rows, duplicate conflicting results, failure/exclusion precedence and unchanged evidence. The actual queue replay route continues to reconcile the overall verdict before presenting the mode-aware counters; Quick never becomes safe to erase in that matrix.

Six isolated mutations produced actual assertion failures: removing the destination Quick guard, ignoring explicitly unverified legacy statuses, treating Quick recovery as verified, ignoring mode in outcome counts, dropping destination-mode propagation, and restoring the interrupted verified-file wording. The restored focused suite passed again. A separate byte filter remains defensive: the zero-verified-count guard also suppresses verified bytes, so removing only that filter is not independently observable in these tests.

## Local integration checks

Xcode 27.1 built both apps and ran the following checks locally. Counts are logical tests; parameterized executions are described above.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Full Mac app suite | 1,320 | 24 | 0 |
| Full iPad Air 11-inch (M4), iPadOS 27.0 simulator suite | 75 | 11 | 0 |
| Full iPhone 18 Pro, iOS 27.0 simulator suite | 75 | 11 | 0 |
| Opt-in Mac recovery renders | 1 | 0 | 0 |
| Opt-in iPad recovery renders | 1 | 0 | 0 |
| Opt-in iPhone recovery renders | 1 | 0 | 0 |

The new capture is skipped by default and ran separately with the existing snapshot opt-in. It renders the actual shared `TransferRecoveryDetails` component with known Quick mode and legacy “Match” rows at Mac widths 580/1,100 pt and mobile widths 375/760 pt. Images were inspected for readable, unverified counts. This is a seeded component check, not a full interactive recovery walkthrough. Existing compiler/toolchain warnings remain. No engine source changed.

## Limits

These are presentation corrections for retained evidence, not new verification or a transfer-engine change. They do not explain either active user report. Physical-device and interactive accessibility checks remain separate from automated model and rendering tests.
