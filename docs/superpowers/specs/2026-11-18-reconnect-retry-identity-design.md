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
- No change for network shares or iOS file-provider volumes: they never get a `fileID` and keep today's refusals.

## Approaches

1. **Store the device-free file ID in the existing `resourceID` field.** Smallest diff, but old records hold the device-bearing form, so a queued record from before the update could never be reauthorized: the stored and fresh values would differ in shape and `validateReauthorization` would call that a mismatch. Rejected.
2. **Add an optional `fileID: UInt64?` next to `resourceID`, prefer it when present.** New records carry both. Identity checks compare `fileID` when the stored record has one, else fall back to today's `resourceID` comparison. Old records behave exactly as today; new records survive remounts. Chosen.
3. **Compare only volume ID + creation date + path.** Drops the folder identifier entirely. Weaker than today against a recreated folder at the same path on a FAT volume with coarse timestamps. Rejected.

## Design (approach 2)

`LocalTransferResource` gains `public let fileID: UInt64?`, read from `.fileIdentifierKey` in `init(url:)`. It is recorded only when the volume is local (`volumeIsLocalKey` is true) and the value is non-zero; on a network share or an unknown volume it stays nil, so those keep today's behavior exactly. Codable synthesis decodes a missing key as nil, so old journal files load unchanged. Fresh selection still requires `volumeID` and `resourceID` as today; `fileID` is additional, never a substitute, so nothing that is refused today becomes accepted on first pick.

**Stored-vs-fresh match** (`validateIdentity`, `validateReauthorization` against the refreshed read). A folder matches a stored identity when all of these hold:

- the volume ID matches (UUID, or the UDF fallback);
- the folder matches, fail closed: if the stored record has a `fileID`, the fresh read must have a non-nil, equal `fileID` (no fallback to `resourceID`); if the stored record has no `fileID`, the fresh `resourceID` must equal the stored one (today's rule);
- the creation date matches when the stored record has one;
- it is a readable directory.

**Stored-vs-stored match** (same-card exemption in `validateQueueOutputs`, both `retryOf` comparisons in the two `replaceQueued` overloads). Two records name the same folder only when their volume IDs are equal, their creation dates are exactly equal as optionals (today's strict rule at these sites, kept; no wildcard), and: both have a `fileID` and they are equal, or neither has one and their `resourceID`s are equal. The comparison is symmetric. A mixed pair (one old, one new) is never the same folder; that fails closed into the output-overlap check and into "not a retry".

`matchesResourceSnapshot` (the stale-snapshot guard behind `prepareToRun` and `reauthorize`) compares `fileID` as one more field. `SourceAvailabilityModel.ResourceKey` adds `fileID` to its key fields.

A record without `fileID` that is reauthorized in the same mount (where `resourceID` still matches) is replaced by the refreshed resource and so gains a `fileID`: the upgrade path for old queued records, stated and tested.

This rule lives in one helper on `LocalTransferResource` and replaces the inline comparisons at exactly these call sites: `validateIdentity`, `validateReauthorization`, the "same card rechecked" test in `validateQueueOutputs`, and both `retryOf` comparisons in `requeue`/`retry`. All switch together.

An old record (no `fileID`) that is re-picked after the update produces a refreshed resource that does have a `fileID`, but the stored side governs, so the comparison stays on `resourceID` and still fails after a remount, exactly as today. That is intentional and gets a comment, because it reads like a bug.

Stale bookmarks: `resolve()` keeps throwing `unavailable` when the bookmark reports stale. Measured not to happen on a remount; if it does on real media the record stays unavailable as today, which is the same outcome as before this change, never a substitution. `QueueSessionPresentation.attemptKey` uses `"\(volumeID)/file:\(fileID)/\(creationDate)"` when a `fileID` is present (birth time included so a reused file ID on a different folder never collapses two cards) and today's `"\(volumeID)/\(resourceID)"` otherwise, so repeated attempts at one card after a remount collapse to one row and the two key forms can never alias. A pre-update attempt and a post-update retry of the same card will not collapse; accepted. `TransferLibraryView.identityCanBeConfirmed` keeps its meaning (volume and `resourceID` present).

## Recreated folders

The one substitution that must never pass is a folder deleted and recreated at the same path. Across a remount this is new ground, because today everything is refused. On FAT and exFAT macOS synthesizes the file ID from the directory entry position, so a recreated folder can present the same `fileID`. The creation date is the discriminator, as it already is for a same-mount recreate today (where `resourceID` is also reused). Measured on disk images: APFS, exFAT, FAT32 and UDF all return a non-nil creation date for folders. FAT stores it at 2 s granularity, in local time, so a folder recreated inside the same 2 s window, or a timezone change between mounts, are known limits; both are pre-existing for same-mount checks. The recreated-folder refusal is a required test on exFAT and FAT32, through `markRunning` and through `reauthorize`.

Twin UDF volumes formatted within one volume-creation tick remain indistinguishable at the root; inherited from the #91 fallback and accepted.

**Accepted limit.** A volume whose complete tuple matches (same volume UUID or fallback, same folder file ID, same birth time), such as a block-level clone, is indistinguishable from the original by any metadata this app can read, before and after this change. The journal's job is to refuse a *different* disk or folder, which such a clone is not in any way the filesystem can show.

Every refusal leaves the journal unchanged; a rejected validation never writes.

`validateReauthorization` keeps requiring both volume and folder identity on both sides; for an old record without `fileID` the refreshed `resourceID` is compared as today.

## Tests (engine, disk images via hdiutil as in UDFCardIdentityTests)

Source and destination each sit on their own image; both are detached and reattached, with a third image attached first to shift device numbers. Every remount test asserts its preconditions: `fileID` non-nil on both sides, and the fresh `resourceID` differs from the stored one (if it does not, the test fails rather than passing vacuously). Mandatory filesystems: APFS, exFAT, FAT32, UDF (UDF as source only, volume root, read-only).

- Remount, then `prepareToRun` and `markRunning` succeed (bookmark resolution included).
- Remount, then `reauthorize` with the same folder succeeds for the source index and a destination index; with a different folder on the same volume it throws `identityMismatch`.
- Folder deleted and recreated at the same path, then remount: refused by `markRunning` and by `reauthorize` (exFAT and FAT32).
- A different image with the same volume name at the same mount point after remount: refused.
- A 0.2.11-shape record (the `fileID` key stripped from the journal file) loads, validates in the same mount, is refused after remount exactly as today, and gains a `fileID` through a same-mount `reauthorize`.
- A folder with the same `fileID` on a different volume is refused.
- A stored record with a `fileID` against a fresh read that yields none is refused, and the journal file is byte-identical afterwards.
- Remount at a different mount point (hdiutil `-mountpoint`): the bookmark resolves there and the retry succeeds.
- Encoding round trip includes `fileID`; a zero `fileID` is stored as nil.
- `attemptKey` collapses a remounted retry with its earlier attempt and keeps old and new key forms distinct (Mac app suite).
- Mac app suite for `attemptKey` collapsing across remount is covered by existing presentation tests plus one new case if the fixture allows.

## Left to the builder

Helper naming, whether `resourceID` keeps being written for new records (yes, for `identityCanBeConfirmed` and diagnostics), and the exact test fixtures.
