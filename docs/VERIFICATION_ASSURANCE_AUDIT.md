# Verification assurance audit — October 14, 2026

Code review against `main` at `f37c918`, followed by the cloud reliability/evidence batch. This is a source audit, not an executed Apple test report or a change to the default verification policy. Standard remains the fresh-install default; saved preferences remain unchanged.

## Copy & Verify

| Mode | Source bytes used for new copies | Independent checks | Verdict digests | Limit |
| --- | --- | --- | --- | --- |
| Quick | Copy read, without a verdict checksum | File-size/publication and source-stability checks | None | Contents are unverified; never whole-card safe. |
| Standard | SHA-256 from the stable fan-out copy read | Each destination is read back through a pinned, cache-bypassing handle | SHA-256 | No separate source reread. A wrong copy read can be hashed and copied consistently. |
| Thorough | Copy read, then a separate uncached source digest read | Source reread compared with each destination readback | SHA-256 and MD5 | Different bytes can be detected; repeatably wrong source reads cannot all be detected. |
| Paranoid | SHA-256 from the copy read, plus source bytes read for comparison | Pinned destination byte comparison and SHA-256 readback | SHA-256 plus byte comparison | More reading does not establish the original camera bytes or prove source-media health. |

The implementation is in `DestinationWriter.fanOutCopyFile`, `verifyPinnedDestinationFile`, `multiDigestVerification`, `uncachedSourceDigests` and `byteComparison`. These descriptions concern new copies. Reuse independently checks an existing file under the selected mode before accepting it; no unproven pre-existing file may be overwritten. Compare and saved-checksum Check have their own read/algorithm semantics and must not inherit copy-stream claims merely because they share a mode name.

`TransferCompletion.verdict` requires exact coverage, verified rows outside Quick, source stability, destination independence, requested handoff/report success and project finalization. Intentionally excluded AppleDouble entries keep the whole-card verdict unsafe even when selected-file contents verify. Cancellation/interruption and incomplete attempts cannot earn completion by reaching 100% progress.

Existing `FanOutTests` explicitly exercise the known Standard copy-stream corruption tradeoff, Thorough's independent-source detection, destination corruption and source mutation. Their presence is code evidence only in this environment; rerun them on Mac. A simulated one-time differing read does not establish coverage for every hardware fault, and a consistently wrong read cannot be disproved by matching checksums alone.

## Digest inventory and evidence

- Standard collects MD5 alongside SHA-256 during existing source/destination reads for ASC handoff. MD5 is recorded compatibility evidence, not an additional Standard verdict requirement.
- Thorough requires SHA-256 and MD5 to match. SHA-1 is not a current transfer-mode verdict digest.
- Paranoid uses SHA-256 and byte comparison. Destination readback also collects MD5 for handoff; this does not turn its mode into Thorough.
- ASC publication can reuse retained destination digests only with matching filesystem identity. exFAT deliberately gets another read. Exporting a report does not freshly verify a file.
- Saved Check can consume SHA-256, MD5 and XXH64 file evidence. Official C4, SHA-1 and XXH128 inventories in the corpus remain unsupported by that reader. Reference-tool verification of those fixtures is separate from BitMatch support.

Do not change hashes, compatibility options, worker defaults or the verification default without the physical end-to-end measurements requested in TODO. The cloud batch makes none of those changes.

## Local and SFTP assurance

`RemoteBackupCoordinator` constructs a manifest from verified local backup rows and resolves upload files from the retained local package, not camera-card paths. It rechecks local identity, size and SHA-256. `RemoteBackupQueue.finalizeOwnedFinal` keeps upload-only terminal results unverified and requires matching provider evidence for verified mode. The current Mac `SFTPRemoteBackupProvider.verificationEvidence` downloads the remote object to a temporary file and hashes it with SHA-256.

These are separate facts: local source reread, verified local backup, remote upload and remote readback. A later SFTP destination does not prevent an earlier independent local source reread. A remote digest match does not retroactively establish that reread or a whole-card verdict. iPhone/iPad retain settings but do not execute SFTP uploads.

The source audit found two presentation/report issues addressed in this batch:

1. A per-destination remote status said “Fully Backed Up” for any valid remote digest. It now says “Remote readback verified” for downloaded evidence and “Remote checksum verified” for older server-checksum evidence. Upload-only remains “Uploaded · Unverified.”
2. Report construction rejected stale local evidence but still derived `fullyBackedUpAt` from retained remote summaries. It now requires the finalized card's valid local state, timestamp, fingerprint and required copy count before publishing that combined timestamp. Remote evidence remains available separately for audit. New regressions cover a valid control, missing local file evidence, stale fingerprint and cancellation, including CSV summary propagation.

## Wording follow-ups

README and Guide now explain Standard's read scope and the limits of repeated source reads. This does **not** complete the TODO acceptance criterion for all surfaces. Continue on Mac with:

- Setup now takes its compact description from `VerificationMode`, and Mac/iPhone/iPad settings use the same full description. Compare uses its own check plan for mode details rather than copy-mode wording. The iPhone/iPad introduction no longer implies that Quick checks file contents. Review the compact wording on narrow devices during the next signed-app walkthrough.
- History and PDF/CSV/JSON now distinguish the selected check plan from saved-result counts, including selected-file exclusions and older attempts without a saved plan (#27). Finish adds the same scope under **Verification details** inside an expanded transfer row; the normal row stays compact. The plan does not claim that interrupted work completed.
- The October 19 reader follow-up retains explicit selected-mode scope and checks its method, digests and counts against the saved statistics. A generic legacy checksum report can retain its recorded content-match result, but its selected mode stays unknown: MD5 does not establish Thorough or a separate source reread. Contradictory scope cannot override Quick, unknown algorithms, an unsafe verdict or mismatched counts.
- Count validation compares backup-result counts with `statistics.totalFiles` and distinct recorded-source counts with `source.fileCount`. A two-destination report retains one distinct source count. These still describe recorded rows, so the reader does not invent a complete original source plan from them.
- Run the existing SFTP interruption/stale-local-evidence suites, the new report/status regressions and the signed report workflow. Independently inspect exported JSON, CSV and PDFs.

See [the cloud handoff](CLOUD_RELIABILITY_HANDOFF.md) for executed checks, pending commands and issue boundaries. User reports #10 and #23 remain open: these changes do not establish their causes.
