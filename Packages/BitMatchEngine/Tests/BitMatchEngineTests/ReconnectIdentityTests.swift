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

    // MARK: Helpers

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
