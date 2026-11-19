#if os(macOS)
import Foundation
import XCTest
@testable import BitMatchEngine

/// The journal records a device-free file identifier so a retry after a
/// remount can still prove it has the original folder. Design:
/// docs/superpowers/specs/2026-11-18-reconnect-retry-identity-design.md
final class ReconnectIdentityTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconnect-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try FileManager.default.removeItem(at: scratch) }
    }

    // MARK: Task 1: recording the identifier

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
        let local = "/Volumes/CARD/A002APFV"
        XCTAssertEqual(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: true, isUbiquitous: false, creationDate: now, path: local), 42)
        XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: false, isUbiquitous: false, creationDate: now, path: local))
        XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: nil, isUbiquitous: false, creationDate: now, path: local),
                     "unknown locality is not local")
        XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: true, isUbiquitous: true, creationDate: now, path: local))
        XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: true, isUbiquitous: false, creationDate: now,
                                       path: "/Users/x/Library/CloudStorage/Dropbox/Card"))
        XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 42, volumeIsLocal: true, isUbiquitous: false, creationDate: nil, path: local))
        XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: 0, volumeIsLocal: true, isUbiquitous: false, creationDate: now, path: local))
        XCTAssertNil(R.fileIDIfTrusted(fileIdentifier: nil, volumeIsLocal: true, isUbiquitous: false, creationDate: now, path: local))
    }

    func testSymlinkIntoACloudManagedPathGetsNoFileID() throws {
        let provider = scratch.appendingPathComponent("Library/CloudStorage/Provider/Card", isDirectory: true)
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("ProviderLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: scratch.appendingPathComponent("Library/CloudStorage/Provider"))
        let viaLink = link.appendingPathComponent("Card", isDirectory: true)
        XCTAssertNil(try LocalTransferResource(url: viaLink).fileID, "the exclusion must see through symlinks")
        XCTAssertNil(try LocalTransferResource(url: provider).fileID)
    }

    func testFileIDRoundTripsThroughCodable() throws {
        let resource = try LocalTransferResource(url: try scratchFolder())
        let data = try JSONEncoder().encode(resource)
        let decoded = try JSONDecoder().decode(LocalTransferResource.self, from: data)
        XCTAssertEqual(decoded.fileID, resource.fileID)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"fileID\""))
    }

    func testHighBitFileIDSurvivesTheJournalCoder() throws {
        var json = try jsonObject(for: try LocalTransferResource(url: try scratchFolder()))
        json["fileID"] = UInt64.max
        let decoded = try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.fileID, UInt64.max)
    }

    func testRecordWithoutFileIDDecodesAsNil() throws {
        let resource = try LocalTransferResource(url: try scratchFolder())
        var json = try jsonObject(for: resource)
        json.removeValue(forKey: "fileID")
        let decoded = try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.fileID)
        XCTAssertEqual(decoded.resourceID, resource.resourceID)
    }

    // MARK: Task 2: stored-vs-fresh match

    func testStoredFileIDRequiresEqualFreshFileID() throws {
        let folder = try scratchFolder()
        let real = try LocalTransferResource(url: folder)
        let fresh = try folder.resourceValues(forKeys: LocalTransferResource.identityKeys)
        XCTAssertTrue(real.folderMatches(fresh: fresh))
        let stored = try edited(real) { $0["fileID"] = try XCTUnwrap(real.fileID) + 1 }
        XCTAssertFalse(stored.folderMatches(fresh: fresh), "same resourceID, different fileID → not the folder")
    }

    func testStoredFileIDDoesNotFallBackToResourceID() throws {
        let folder = try scratchFolder()
        let real = try LocalTransferResource(url: folder)
        var fresh = try folder.resourceValues(forKeys: LocalTransferResource.identityKeys)
        fresh = try folder.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .fileResourceIdentifierKey, .creationDateKey])
        XCTAssertNil(fresh.fileIdentifier, "precondition: fresh read without a file identifier")
        XCTAssertFalse(real.folderMatches(fresh: fresh), "a stored fileID never falls back to resourceID")
    }

    func testLegacyRecordMatchesOnResourceID() throws {
        let folder = try scratchFolder()
        let real = try LocalTransferResource(url: folder)
        let legacy = try edited(real) { $0.removeValue(forKey: "fileID") }
        let fresh = try folder.resourceValues(forKeys: LocalTransferResource.identityKeys)
        XCTAssertTrue(legacy.folderMatches(fresh: fresh))
        let other = try scratchFolder("B001OTHER")
        let otherFresh = try other.resourceValues(forKeys: LocalTransferResource.identityKeys)
        XCTAssertFalse(legacy.folderMatches(fresh: otherFresh))
    }

    func testStoredFileIDWithoutBirthTimeFailsClosed() throws {
        let folder = try scratchFolder()
        let real = try LocalTransferResource(url: folder)
        let malformed = try edited(real) { $0.removeValue(forKey: "creationDate") }
        let fresh = try folder.resourceValues(forKeys: LocalTransferResource.identityKeys)
        XCTAssertFalse(malformed.folderMatches(fresh: fresh))
        XCTAssertFalse(malformed.folderMatches(refreshed: real))
    }

    func testRefreshedResourceMatchRule() throws {
        let folder = try scratchFolder()
        let real = try LocalTransferResource(url: folder)
        XCTAssertTrue(real.folderMatches(refreshed: real))
        let legacy = try edited(real) { $0.removeValue(forKey: "fileID") }
        XCTAssertTrue(legacy.folderMatches(refreshed: real), "old record re-picked in the same mount compares on resourceID")
        XCTAssertFalse(real.folderMatches(refreshed: legacy), "stored fileID requires a refreshed fileID")
        let moved = try edited(real) { $0["resourceID"] = "elsewhere" }
        XCTAssertTrue(real.folderMatches(refreshed: moved), "with a stored fileID the device-bearing ID is ignored")
    }

    // MARK: Task 4: record-vs-record

    func testSameFolderIsSymmetricAndMixedGenerationsDiffer() throws {
        let folder = try scratchFolder()
        let new1 = try LocalTransferResource(url: folder)
        let new2 = try edited(new1) { $0["resourceID"] = "another device number" }
        let old1 = try edited(new1) { $0.removeValue(forKey: "fileID") }
        let old2 = try edited(old1) { $0["bookmark"] = $0["bookmark"] }
        XCTAssertTrue(new1.namesSameFolder(as: new2)); XCTAssertTrue(new2.namesSameFolder(as: new1))
        XCTAssertTrue(old1.namesSameFolder(as: old2)); XCTAssertTrue(old2.namesSameFolder(as: old1))
        XCTAssertFalse(new1.namesSameFolder(as: old1)); XCTAssertFalse(old1.namesSameFolder(as: new1))
        let later = try edited(new1) { $0["creationDate"] = ($0["creationDate"] as! Double) + 1 }
        XCTAssertFalse(new1.namesSameFolder(as: later), "birth time stays strict")
        let otherFile = try edited(new1) { $0["fileID"] = ($0["fileID"] as! UInt64) + 1 }
        XCTAssertFalse(new1.namesSameFolder(as: otherFile))
    }

    func testIdentityLessRecordStillThrowsUnverifiableIdentity() throws {
        let folder = try scratchFolder()
        let real = try LocalTransferResource(url: folder)
        let blank = try edited(real) { for k in ["volumeID", "resourceID", "fileID"] { $0.removeValue(forKey: k) } }
        XCTAssertFalse(blank.namesSameFolder(as: blank), "nil == nil is never a match")
        XCTAssertThrowsError(try blank.validateIdentity(at: folder)) { error in
            guard case LocalTransferJournalError.unverifiableIdentity = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Helpers

    private func edited(_ resource: LocalTransferResource, _ edit: (inout [String: Any]) throws -> Void) throws -> LocalTransferResource {
        var json = try jsonObject(for: resource)
        try edit(&json)
        return try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func scratchFolder(_ name: String = "A002APFV") throws -> URL {
        let folder = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func jsonObject(for resource: LocalTransferResource) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resource)) as? [String: Any])
    }
}
#endif
