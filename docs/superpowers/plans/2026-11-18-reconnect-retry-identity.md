# Reconnect Retry Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A queued, interrupted or failed transfer can be retried after its card or backup drive was unplugged and plugged back in, without accepting a different disk or folder.

**Architecture:** `LocalTransferResource` records a device-free file identifier (`fileID`) next to the existing device-bearing `resourceID`. Identity checks prefer `fileID` when the stored record has one and fail closed; records without it keep today's rule. One helper per comparison kind (stored-vs-fresh, record-vs-record) replaces the inline comparisons.

**Tech Stack:** Swift 6, Foundation `URLResourceValues`, XCTest with hdiutil disk images (pattern: `UDFCardIdentityTests`).

**Spec:** `docs/superpowers/specs/2026-11-18-reconnect-retry-identity-design.md`

## Global Constraints

- `fileID` is recorded only on macOS, when `volumeIsLocal == true`, `isUbiquitousItem != true`, `creationDate != nil` and the value is non-zero; otherwise nil. A stored `fileID` with nil `creationDate` fails closed.
- Fresh selection still requires `volumeID` and `resourceID`; `fileID` never substitutes.
- Stored `fileID` present → fresh `fileID` must be non-nil and equal; never fall back to `resourceID`.
- Record-vs-record comparison is symmetric, keeps strict optional equality of `creationDate`, and treats a mixed old/new pair as different.
- A refusal never writes the journal.
- No migration pass; old journal files decode unchanged.
- Tests run under the shared lock: `until mkdir /tmp/bitmatch-test-lock; do sleep 5; done`, `rmdir` on exit.

## Review Focus

1. Network share picked as destination: must behave exactly as today (no `fileID`), pinned by the unit test on `fileIDIfTrusted` with `volumeIsLocal == false`.
2. Fresh read returns `fileIdentifier == 0`: treated as missing, pinned in Task 1.
3. Old record re-picked after remount: still refused with `identityMismatch`, pinned in Task 6.
4. Two queued records for one card, one old-shape and one new-shape: same-card exemption must not fire; pinned in Task 4.
5. Remount at a different mount point: bookmark resolves there; pinned in Task 3.

---

### Task 1: Record the device-free file identifier

**Files:**
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/TransferJournal.swift:15-40` (`LocalTransferResource` fields, `init(url:)`, `identityKeys`)
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/ReconnectIdentityTests.swift` (new)

**Interfaces:**
- Produces: `public let fileID: UInt64?` on `LocalTransferResource`; `static func fileIDIfTrusted(fileIdentifier: UInt64?, volumeIsLocal: Bool?, isUbiquitous: Bool?, creationDate: Date?) -> UInt64?` (internal, `@testable`); `identityKeys` gains `.fileIdentifierKey`, `.volumeIsLocalKey`, `.isUbiquitousItemKey`.

- [ ] **Step 1: Write the failing tests**

```swift
func testLocalFolderRecordsFileID() throws {
    let folder = try scratchFolder()
    let resource = try LocalTransferResource(url: folder)
    let expected = try XCTUnwrap(folder.resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier)
    XCTAssertEqual(resource.fileID, expected)
    XCTAssertNotNil(resource.resourceID, "resourceID is still recorded")
}

func testFileIDEligibility() {
    typealias R = LocalTransferResource
    let now = Date()
    XCTAssertEqual(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: true, isUbiquitous: false, creationDate: now), 42)
    XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: false, isUbiquitous: false, creationDate: now))
    XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: nil, isUbiquitous: false, creationDate: now), "unknown locality is not local")
    XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: true, isUbiquitous: true, creationDate: now))
    XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: true, isUbiquitous: false, creationDate: nil))
    XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 0, volumeIsLocal: true, isUbiquitous: false, creationDate: now))
    XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: nil, volumeIsLocal: true, isUbiquitous: false, creationDate: now))
}

func testFileIDRoundTripsThroughCodable() throws {
    let resource = try LocalTransferResource(url: try scratchFolder())
    let data = try JSONEncoder().encode(resource)
    let decoded = try JSONDecoder().decode(LocalTransferResource.self, from: data)
    XCTAssertEqual(decoded.fileID, resource.fileID)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"fileID\""))
}

func testHighBitFileIDSurvivesTheJournalCoder() throws {
    // JSON number handling must not truncate: edit an encoded resource's fileID to UInt64.max and decode it back.
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(try LocalTransferResource(url: try scratchFolder()))) as? [String: Any])
    json["fileID"] = UInt64.max
    let decoded = try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(decoded.fileID, UInt64.max)
}

func testRecordWithoutFileIDDecodesAsNil() throws {
    let resource = try LocalTransferResource(url: try scratchFolder())
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resource)) as? [String: Any])
    json.removeValue(forKey: "fileID")
    let decoded = try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNil(decoded.fileID)
    XCTAssertEqual(decoded.resourceID, resource.resourceID)
}
```

`fileIDIfTrusted(fileIdentifier:volumeIsLocal:isUbiquitous:creationDate:) -> UInt64?` is a pure static function; `init(url:)` feeds it from `values` and, on non-macOS builds, assigns nil without calling it (`#if os(macOS)`). `identityKeys` also gains `.isUbiquitousItemKey`.

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/BitMatchEngine && swift test --filter ReconnectIdentityTests`
Expected: compile error, `fileID` and `fileIDIfTrusted` undefined.

- [ ] **Step 3: Implement**

Add `public let fileID: UInt64?` after `resourceID`. In `init(url:)`, `fileID = Self.fileIDIfTrusted(values)`. Add `.fileIdentifierKey, .volumeIsLocalKey` to `identityKeys`. `fileIDIfTrusted` returns the identifier only when `volumeIsLocal == true` and it is non-zero.

- [ ] **Step 4: Run to verify pass**, then run `swift test --filter UDFCardIdentityTests` (must stay green).

- [ ] **Step 5: Commit** `feat(journal): record a device-free file identifier for local folders`

---

### Task 2: Stored-vs-fresh match helper, used by validateIdentity and validateReauthorization

**Files:**
- Modify: `TransferJournal.swift:66-90` (`validateIdentity`), `:557-592` (`validateReauthorization`)
- Test: `ReconnectIdentityTests.swift`

**Interfaces:**
- Produces: `func folderMatches(fresh: URLResourceValues) -> Bool` on `LocalTransferResource` (internal): stored `fileID` present → stored `creationDate` must be non-nil (else false) and `fresh.fileIdentifier` non-nil, non-zero and equal; else `String(describing: fresh.fileResourceIdentifier) == resourceID`. `func folderMatches(refreshed: LocalTransferResource) -> Bool`: same rule against another resource's `fileID`/`resourceID`.

- [ ] **Step 1: Write the failing tests**

```swift
func testStoredFileIDRequiresEqualFreshFileID() throws   // stored fileID 7, fresh fileID 8, same resourceID → false
func testStoredFileIDDoesNotFallBackToResourceID() throws // stored fileID 7, fresh fileID nil, same resourceID → false
func testLegacyRecordMatchesOnResourceID() throws         // stored fileID nil, resourceID equal → true; resourceID differs → false
func testStoredFileIDWithoutBirthTimeFailsClosed() throws  // stored fileID 7, creationDate nil (JSON-edited), fresh fileID 7 → false
```

Build the stored side by decoding a JSON-edited `LocalTransferResource` (pattern from `UDFCardIdentityTests.testReauthorizationRejectsAFolderWhoseCreationDateChanged`); the fresh side comes from a real folder's `resourceValues`.

- [ ] **Step 2: Verify failure** (helper undefined).

- [ ] **Step 3: Implement** both helpers; replace the `resolvedResourceID` comparison in `validateIdentity` with `folderMatches(fresh: values)` and the `resourceOK` line in `validateReauthorization` with `original.folderMatches(refreshed: refreshed)`. Keep the `guard volumeID != nil, resourceID != nil` fresh-selection requirement as is. Add the comment: an old record re-picked after the update is compared on `resourceID` by design.

- [ ] **Step 4: Verify pass**; `swift test --filter "ReconnectIdentityTests|UDFCardIdentityTests|PreparedJournalResourceTests"` green.

- [ ] **Step 5: Commit** `feat(journal): match folders by file identifier when recorded`

---

### Task 3: Remount retry succeeds through prepareToRun, on four filesystems

**Files:**
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/RemountRetryMatrixTests.swift` (new)

**Interfaces:**
- Consumes: `TransferJournal.enqueue(source:destinations:...)`, `prepareToRun(id:)`, `markRunning(id:sourceURL:destinationURLs:)`, `reauthorize(id:resourceIndex:newURL:)`.

Fixture: a `DiskImage` helper struct (create/attach/detach via `/usr/bin/hdiutil`, `-nobrowse -mountpoint`, log to file; copy `runHdiutil` from `UDFCardIdentityTests`). Source image per filesystem under test (`APFS`, `ExFAT`, `FAT32` 64 MB, `UDF`), destination image always `ExFAT`, plus a third `APFS` "shifter" image attached first on every reattach. Source folder: `<mount>/A002APFV` created before enqueue (UDF: the volume root). The journal file lives in scratch, outside the images.

- [ ] **Step 1: Write the failing test**

```swift
func testRetryAfterRemountOnEveryFilesystem() throws {
    for fs in ["APFS", "ExFAT", "FAT32", "UDF"] {
        let f = try Fixture(sourceFS: fs)
        let id = try f.journal.enqueue(source: try LocalTransferResource(url: f.sourceFolder),
                                       destinations: [try LocalTransferResource(url: f.destinationFolder)], ...)
        let stored = f.journal.records[0]
        XCTAssertNotNil(stored.source.fileID, fs); XCTAssertNotNil(stored.destinations[0].fileID, fs)
        try f.remountAll()   // detach source+destination, attach shifter, reattach both
        let freshSource = try LocalTransferResource(url: f.sourceFolder)
        XCTAssertNotEqual(freshSource.resourceID, stored.source.resourceID, "\(fs): precondition, device-bearing ID must change")
        XCTAssertEqual(freshSource.fileID, stored.source.fileID, fs)
        let access = try f.journal.prepareToRun(id: id)
        defer { access.release() }
        XCTAssertNoThrow(try f.journal.markRunning(id: id, sourceURL: access.sourceURL, destinationURLs: access.destinationURLs), fs)
        XCTAssertEqual(f.journal.records[0].state, .running, fs)
    }
}

func testReadAccessAfterRemount() throws   // exFAT destination; after remountAll, records[0].destinations[0].beginReadAccess() succeeds and its url is readable

func testRetryAfterRemountAtADifferentMountPoint() throws   // exFAT source, reattach at <scratch>/mount-b; prepareToRun + markRunning succeed
```

- [ ] **Step 2: Verify failure**: before Task 2 this throws `unavailable` on `prepareToRun`. (If Tasks 1–2 are already in, this test passes immediately; then run it once with `folderMatches` temporarily returning the legacy comparison to see it fail, and restore.)

- [ ] **Step 3: Verify pass** on all four filesystems.

- [ ] **Step 4: Commit** `test(journal): retry after remount on APFS, exFAT, FAT32 and UDF`

---

### Task 4: Record-vs-record helper for the same-card exemption and retryOf

**Files:**
- Modify: `TransferJournal.swift:652-656` (same-card `continue`), `:724-726` and `:768-770` (both `retryOf` expressions), `:515-527` (`matchesResourceSnapshot` gains `fileID`)
- Test: `ReconnectIdentityTests.swift`

**Interfaces:**
- Produces: `func namesSameFolder(as other: LocalTransferResource) -> Bool` on `LocalTransferResource` (internal, symmetric; never reuse `folderMatches`): `volumeID != nil && volumeID == other.volumeID && creationDate == other.creationDate` and (both `fileID` non-nil and equal, or both nil and `resourceID` non-nil and equal).

- [ ] **Step 1: Write the failing tests**

```swift
func testSameFolderIsSymmetricAndMixedGenerationsDiffer() throws
   // new/new equal fileID → true both ways; old/old equal resourceID → true; old/new → false both ways; creationDate differs → false
func testSameCardRecheckAfterRemountIsStillExempt() throws
   // enqueue record A on exFAT image; remount; enqueue record B for the same card and same destination root;
   // markRunning(B) succeeds (exemption fires on fileID although resourceIDs differ)
func testMixedGenerationPairIsNotTheSameCard() throws
   // record A new-shape, record B with fileID stripped (JSON), same folder, same destination root: markRunning(B) throws (overlap check fires);
   // replaceQueued for B with the new-shape source yields retryOf == nil
func testIdentityLessRecordStillThrowsUnverifiableIdentity() throws
   // JSON-strip volumeID and resourceID and fileID: validateIdentity throws unverifiableIdentity; namesSameFolder(as: itself) is false
func testSnapshotMismatchOnFileIDRejectsPrepareToRun() throws
   // prepareToRun(id:expectedResources:) with a snapshot whose source fileID is JSON-edited → throws invalidState
```

- [ ] **Step 2: Verify failure.**

- [ ] **Step 3: Implement** the helper; replace the three inline comparisons; add `&& current.fileID == expected.fileID` to `matchesResourceSnapshot`.

- [ ] **Step 4: Verify pass**; full `swift test` under the lock, green.

- [ ] **Step 5: Commit** `feat(journal): compare stored folders by file identifier`

---

### Task 5: Negative matrix after remount

**Files:**
- Test: `RemountRetryMatrixTests.swift`

- [ ] **Step 1: Write the failing tests** (exFAT and FAT32 sources unless noted)

```swift
func testRecreatedFolderAtTheSamePathIsRefusedAfterRemount()
   // enqueue; detach; reattach; rmdir + mkdir A002APFV (sleep 3 s first so FAT's 2 s birth time differs); detach; reattach;
   // prepareToRun throws unavailable; reauthorize(id, 0, folder) throws identityMismatch; journal file bytes unchanged
func testDifferentImageWithTheSameVolumeNameIsRefusedAfterRemount()
   // second exFAT image, same volname, attached at the same mount point → prepareToRun throws unavailable; reauthorize(id, 0, folder) throws identityMismatch
func testDifferentFolderOnTheSameVolumeIsRefusedOnReauthorize()
   // after remount, reauthorize(id, 0, <mount>/B001OTHER) throws identityMismatch; reauthorize(id, 1, <sameDestinationFolder>) succeeds
func testSameFileIDOnAnotherVolumeIsRefused()
   // record from image A; folder on image B that reports the same fileID (create folders in the same order on two fresh exFAT images, assert equal fileIDs as precondition) → validateIdentity throws unavailable
func testStoredFileIDWithNoFreshFileIDIsRefused()
   // JSON-edit the record to carry a fileID on a folder whose fresh read is on a non-local volume is not constructible with images;
   // instead call folderMatches(fresh:) with values lacking fileIdentifier (Task 2 covers the rule) and assert prepareToRun leaves the journal file byte-identical after any refusal above
```

- [ ] **Step 2: Verify each fails or passes for the stated reason** (these are regression pins; most pass once Task 4 is in; the recreated-folder test must be watched to fail with `folderMatches` ignoring `creationDate`, then restored).

- [ ] **Step 3: Commit** `test(journal): refuse replacements after remount`

---

### Task 6: Legacy record behavior and upgrade

**Files:**
- Test: `RemountRetryMatrixTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testLegacyRecordValidatesInSameMountAndIsRefusedAfterRemount()
   // enqueue on exFAT; strip "fileID" from source and destination in the journal JSON; reload journal;
   // prepareToRun succeeds before remount; after remount prepareToRun throws unavailable and reauthorize(id, 0, folder) throws identityMismatch
func testLegacyRecordGainsFileIDThroughSameMountReauthorize()
   // same setup, no remount; reauthorize(id, 0, folder) succeeds; records[0].source.fileID != nil; after a remount prepareToRun now succeeds
```

- [ ] **Step 2: Verify**, **Step 3: Commit** `test(journal): legacy records keep their rules and upgrade on reauthorization`

---

### Task 7: Presentation and availability keys

**Files:**
- Modify: `Shared/Core/Models/QueueSessionPresentation.swift:443-450` (`attemptKey`), `Shared/Core/Services/SourceAvailabilityModel.swift:13-26` (`ResourceKey`)
- Test: `BitMatchTests/QueueSessionPresentationTests.swift` (existing file; add cases)

- [ ] **Step 1: Write the failing tests**

```swift
func testAttemptKeyUsesFileIDWithBirthTimeAndKeepsLegacyForm()
   // record with fileID 9, volumeID "V", creationDate D → "V/file:9/<D.timeIntervalSinceReferenceDate>"
   // record without fileID → "V/<resourceID>"; the two never equal for the same folder
func testAttemptKeyDistinguishesReusedFileIDWithDifferentBirthTime()   // birth times 0.25 s apart within one second → different keys
```

Build records via `JSONDecoder` from a JSON literal (see how `QueueSessionPresentationTests` builds records today; reuse its helper).

- [ ] **Step 2: Verify failure**, **Step 3: Implement** (`attemptKey` per spec; `ResourceKey` adds `let fileID: UInt64?`), **Step 4:** `./test.sh mac-test` green, **Step 5: Commit** `feat(queue): collapse remounted retries into one row`

---

### Task 8: Changelog and full verification

- [ ] Add to `CHANGELOG.md` Unreleased: "Fix: Retrying a transfer after unplugging and reconnecting the card or a backup drive works again; the journal now remembers a folder by an identifier that survives remounts. Older records keep their previous rule until they are re-picked once."
- [ ] Run under the lock: `./test.sh engine-test`, `./test.sh mac-test`, `./test.sh ipad-build`; record the three result lines.
- [ ] Commit `docs: changelog for reconnect retries`
