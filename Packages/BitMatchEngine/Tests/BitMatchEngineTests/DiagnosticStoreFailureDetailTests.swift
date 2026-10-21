import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import BitMatchEngine

final class DiagnosticStoreFailureDetailTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func object(_ store: TransferDiagnosticStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
    }

    private func assertDetailUnavailable(in root: URL) throws {
        let exported = try object(TransferDiagnosticStore(directory: root))
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailAvailable"] as? Bool, false)
        XCTAssertNil(exported["recordingFailureDetailSource"] as? String)
        XCTAssertNil(exported["recordingFailureDetail"] as? [String: Any])
    }

    func testOversizedEventExportsOnlyClosedStageAndNumericCode() throws {
        let root = try fixture().appendingPathComponent("private-source-name")
        TransferDiagnosticStore(directory: root, limit: 1).record(.admitted, run: nil)

        let store = TransferDiagnosticStore(directory: root)
        let exported = try object(store)
        let detail = try XCTUnwrap(exported["recordingFailureDetail"] as? [String: Any])
        XCTAssertEqual(detail["stage"] as? String, "oversized")
        XCTAssertEqual(detail["code"] as? Int, Int(EFBIG))
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailAvailable"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailSource"] as? String, "persistedMarker")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".recording-error")).count, 0,
                       "The legacy marker remains zero bytes")
        let exportText = String(decoding: try store.exportData(), as: UTF8.self)
        XCTAssertFalse(exportText.contains(root.lastPathComponent))
        XCTAssertFalse(exportText.contains("NSError"))
        XCTAssertFalse(exportText.contains("localizedDescription"))
    }

    func testLegacyEmptyMarkerStillMeansErrorWithUnavailableDetail() throws {
        let root = try fixture()
        try Data().write(to: root.appendingPathComponent(".recording-error"))

        let exported = try object(TransferDiagnosticStore(directory: root))
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailAvailable"] as? Bool, false)
        XCTAssertNil(exported["recordingFailureDetailSource"] as? String)
        XCTAssertNil(exported["recordingFailureDetail"] as? [String: Any])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".recording-error")).count, 0)
    }

    func testFirstPersistedFailureDetailIsNotReplacedByLaterFailure() throws {
        let root = try fixture()
        TransferDiagnosticStore(directory: root, limit: 1).record(.admitted, run: nil)
        let outside = root.appendingPathComponent("SECRET_FOOTAGE")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("current.jsonl"),
                                                   withDestinationURL: outside)

        let laterStore = TransferDiagnosticStore(directory: root)
        laterStore.record(.pipelineDrained, run: nil)
        let exported = try object(laterStore)
        XCTAssertEqual(exported["recordingFailureDetailAvailable"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailSource"] as? String, "persistedMarker")
        let detail = try XCTUnwrap(exported["recordingFailureDetail"] as? [String: Any])
        XCTAssertEqual(detail["stage"] as? String, "oversized")
        XCTAssertEqual(detail["code"] as? Int, Int(EFBIG))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }

    func testMalformedDetailIsUnavailableAndDoesNotLeakContents() throws {
        let root = try fixture()
        try Data().write(to: root.appendingPathComponent(".recording-error"))
        try Data("SECRET_FOOTAGE /Users/private\n".utf8)
            .write(to: root.appendingPathComponent(".recording-error-detail"))

        let exported = try object(TransferDiagnosticStore(directory: root))
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailAvailable"] as? Bool, false)
        XCTAssertNil(exported["recordingFailureDetailSource"] as? String)
        XCTAssertNil(exported["recordingFailureDetail"] as? [String: Any])
        XCTAssertFalse(String(decoding: try TransferDiagnosticStore(directory: root).exportData(), as: UTF8.self)
            .contains("SECRET_FOOTAGE"))
    }

    func testLinkedDetailIsNotFollowed() throws {
        let root = try fixture()
        try Data().write(to: root.appendingPathComponent(".recording-error"))
        let outside = root.appendingPathComponent("SECRET_FOOTAGE")
        try Data("v1\nstage=write\ncode=5\nSECRET_FOOTAGE".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".recording-error-detail"),
                                                   withDestinationURL: outside)

        let store = TransferDiagnosticStore(directory: root)
        let exported = try object(store)
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailAvailable"] as? Bool, false)
        XCTAssertNil(exported["recordingFailureDetailSource"] as? String)
        XCTAssertNil(exported["recordingFailureDetail"] as? [String: Any])
        XCTAssertFalse(String(decoding: try store.exportData(), as: UTF8.self).contains("SECRET_FOOTAGE"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testValidPrefixWithExtraBytesIsUnavailable() throws {
        let root = try fixture()
        try Data().write(to: root.appendingPathComponent(".recording-error"))
        try Data("v1\nstage=write\ncode=5\nextra".utf8)
            .write(to: root.appendingPathComponent(".recording-error-detail"))

        try assertDetailUnavailable(in: root)
    }

    func testOversizedDetailIsUnavailable() throws {
        let root = try fixture()
        try Data().write(to: root.appendingPathComponent(".recording-error"))
        try Data(repeating: 0x78, count: 129)
            .write(to: root.appendingPathComponent(".recording-error-detail"))

        try assertDetailUnavailable(in: root)
    }

    func testHardlinkedDetailIsUnavailable() throws {
        let root = try fixture()
        try Data().write(to: root.appendingPathComponent(".recording-error"))
        let detail = root.appendingPathComponent(".recording-error-detail")
        let alias = root.appendingPathComponent("other-name")
        try Data("v1\nstage=write\ncode=5\n".utf8).write(to: detail)
        XCTAssertEqual(link(detail.path, alias.path), 0)

        try assertDetailUnavailable(in: root)
    }

    func testFIFOFailureDetailIsUnavailable() throws {
        let root = try fixture()
        try Data().write(to: root.appendingPathComponent(".recording-error"))
        let detail = root.appendingPathComponent(".recording-error-detail")
        XCTAssertEqual(mkfifo(detail.path, 0o600), 0)

        try assertDetailUnavailable(in: root)
    }

    func testDirectoryOpenFailureExportsCurrentInstanceProvenanceWithoutPath() throws {
        let root = try fixture().appendingPathComponent("SECRET_DIAGNOSTICS_PATH")
        try Data("not a directory".utf8).write(to: root)
        let store = TransferDiagnosticStore(directory: root)
        store.record(.admitted, run: nil)

        let exported = try object(store)
        let detail = try XCTUnwrap(exported["recordingFailureDetail"] as? [String: Any])
        XCTAssertEqual(detail["stage"] as? String, "directoryOpen")
        XCTAssertNotNil(detail["code"] as? Int)
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailAvailable"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailSource"] as? String, "currentInstance")
        let exportText = String(decoding: try store.exportData(), as: UTF8.self)
        XCTAssertFalse(exportText.contains(root.lastPathComponent))
        XCTAssertFalse(exportText.contains(root.path))
    }
}
