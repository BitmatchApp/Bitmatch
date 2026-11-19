# Reconnect retry identity

Date: 2026-11-18. Branch: fix/reconnect-retry-identity (stacked on fix/udf-volume-identity).

## Intent

A queued, interrupted or failed transfer can be retried after the card or backup drive was unplugged and plugged back in. Today every such retry fails with "Reconnect or reselect X. Its original folder could not be confirmed", and re-picking the folder fails with "X is not the original folder", on every filesystem.

## Why it fails today

`LocalTransferResource` records a folder's identity as the volume ID, `fileResourceIdentifier` (stored as `resourceID`) and the folder's creation date. Apple's `fileResourceIdentifier` is the inode plus the mount's device number, and the device number changes on every remount (measured on APFS, exFAT, FAT and UDF disk images; Apple documents it as not persistent across restarts). So the stored `resourceID` never matches after a remount, `validateIdentity` throws `unavailable`, and `validateReauthorization` throws `identityMismatch` because the fresh identity differs too.

`fileIdentifier` (`URLResourceKey.fileIdentifierKey`, a `UInt64` inode or synthesized file ID without the device number) stayed identical over three detach/reattach cycles on APFS, exFAT, FAT32 and UDF disk images, with other volumes mounted in between to shift device numbers. Security-scoped bookmarks made before the remount resolved to the same folder with `bookmarkDataIsStale == false` on all four. Both are measurements on disk images, not Apple guarantees.

## Goals

- A retry after reconnecting the same card and backup drives starts without re-picking.
- Re-picking the same folder after reconnect is accepted; a different folder or disk at the same path is still refused.
- Records written by 0.2.11 and earlier keep working exactly as they do now.

## Non-goals and anti-goals

- No change to what the journal refuses on fresh selection (issue #91 fix stays as is).
- Never accept a replacement folder because its path or name matches. Identity stays volume + folder + birth time.
- No migration pass over the journal file.

## Approaches

1. **Store the device-free file ID in the existing `resourceID` field.** Smallest diff, but old records hold the device-bearing form, so a queued record from before the update could never be reauthorized: the stored and fresh values would differ in shape and `validateReauthorization` would call that a mismatch. Rejected.
2. **Add an optional `fileID: UInt64?` next to `resourceID`, prefer it when present.** New records carry both. Identity checks compare `fileID` when the stored record has one, else fall back to today's `resourceID` comparison. Old records behave exactly as today; new records survive remounts. Chosen.
3. **Compare only volume ID + creation date + path.** Drops the folder identifier entirely. Weaker than today against a recreated folder at the same path on a FAT volume with coarse timestamps. Rejected.

## Design (approach 2)

`LocalTransferResource` gains `public let fileID: UInt64?`, read from `.fileIdentifierKey` in `init(url:)`. Codable synthesis decodes a missing key as nil, so old journal files load unchanged.

A folder matches a stored identity when:

- the volume ID matches (UUID, or the UDF fallback), and
- the folder matches: `fileID` equal when the stored record has one, otherwise `resourceID` equal (today's rule), and
- the creation date matches when the stored record has one, and
- it is a readable directory.

This rule lives in one helper on `LocalTransferResource` and replaces the inline comparisons at exactly these call sites: `validateIdentity`, `validateReauthorization`, the "same card rechecked" test in `validateQueueOutputs`, and both `retryOf` comparisons in `requeue`/`retry`. All switch together.

An old record (no `fileID`) that is re-picked after the update produces a refreshed resource that does have a `fileID`, but the stored side governs, so the comparison stays on `resourceID` and still fails after a remount, exactly as today. That is intentional and gets a comment, because it reads like a bug.

Stale bookmarks: `resolve()` keeps throwing `unavailable` when the bookmark reports stale. Measured not to happen on a remount; if it does on real media the record stays unavailable as today, which is the same outcome as before this change, never a substitution. `QueueSessionPresentation.attemptKey` uses `fileID` when present so repeated attempts at one card after a remount collapse to one row; otherwise it keeps `resourceID`. `TransferLibraryView.identityCanBeConfirmed` and `SourceAvailabilityModel` keep their current meaning (`fileID` counts as a confirmable folder identity alongside `resourceID`).

`validateReauthorization` keeps requiring both volume and folder identity on both sides; for an old record without `fileID` the refreshed `resourceID` is compared as today.

## Tests (engine, disk images via hdiutil as in UDFCardIdentityTests)

- Enqueue on a mounted image, detach, reattach with another image mounted first, then `markRunning` succeeds. Run on exFAT and UDF (and APFS if cheap).
- Same flow, then `reauthorize` with the same folder succeeds, and with a different folder on the same volume throws `identityMismatch`.
- A journal file whose record has no `fileID` (0.2.11 shape) loads, validates against its unchanged folder in the same mount, and is refused after remount exactly as today.
- Encoding round trip includes `fileID`.
- A folder with the same `fileID` on a different volume is refused (volume check).
- The remount tests go through `prepareToRun`, so bookmark resolution is exercised, not only `validateIdentity`.
- Mac app suite for `attemptKey` collapsing across remount is covered by existing presentation tests plus one new case if the fixture allows.

## Left to the builder

Helper naming, whether `resourceID` keeps being written for new records (yes, for `identityCanBeConfirmed` and diagnostics), and the exact test fixtures.
