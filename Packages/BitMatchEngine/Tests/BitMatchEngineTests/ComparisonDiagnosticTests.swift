import Foundation
import XCTest
@testable import BitMatchEngine

final class ComparisonDiagnosticTests: XCTestCase {
    private func events(_ run: UUID, store: TransferDiagnosticStore) throws -> [[String: Any]] {
        let data = try store.exportData()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["events"] as? [[String: Any]]).filter { $0["run"] as? String == run.uuidString }
    }
    func testSummaryCountsArePrivateAndDoNotChangeDifferences() async throws {
        let fm = FileManager.default
        let marker = "PRIVATE_PRODUCTION_\(UUID())"
        let root = fm.temporaryDirectory.appendingPathComponent(marker)
        defer { try? fm.removeItem(at: root) }
        let left = root.appendingPathComponent("Source"), right = root.appendingPathComponent("Backup")
        for folder in [left, right] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("source".utf8).write(to: left.appendingPathComponent(marker))
        try Data("damage".utf8).write(to: right.appendingPathComponent(marker))
        try Data().write(to: left.appendingPathComponent("missing"))
        try Data().write(to: right.appendingPathComponent("extra"))
        let run = UUID()
        let store = TransferDiagnosticStore(directory: root.appendingPathComponent("Diagnostics"))
        let result = try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
            try await TransferDiagnostics.$runID.withValue(run) {
                try await FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
                    .compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
            }
        }
        XCTAssertEqual(result.mismatchedCount, 1)
        let records = try events(run, store: store)
        XCTAssertEqual(records.first?["event"] as? String, "compareStarted")
        XCTAssertEqual(records.last?["comparisonOutcome"] as? String, "completed")
        XCTAssertEqual(records.last?["onlyInSourceCount"] as? Int, 1)
        XCTAssertEqual(records.last?["onlyInDestinationCount"] as? Int, 1)
        XCTAssertEqual(records.last?["mismatchedCount"] as? Int, 1)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self).contains(marker))
    }
    func testCompareIgnoresOnlyBitMatchWorkingEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = root.appendingPathComponent("source"), right = root.appendingPathComponent("backup")
        for directory in [left, right] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for directory in [left, right] { try Data("same".utf8).write(to: directory.appendingPathComponent("clip")) }
        let staging = right.appendingPathComponent(".bitmatch-staging-test")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: staging.appendingPathComponent("report.json"))
        try Data("private".utf8).write(to: right.appendingPathComponent(".unsettled-report.json"))
        let result = try await FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertEqual(result.onlyInRightCount, 0)
        XCTAssertEqual(result.mismatchedCount, 0)
        // Transfer manifests must never silently discard a card's files.
        let sourceListing = try CardSource.enumerateRegularFiles(base: right).map(\.relativePath)
        XCTAssertTrue(sourceListing.contains(".bitmatch-staging-test/report.json"))
        XCTAssertTrue(sourceListing.contains(".unsettled-report.json"))
        try Data().write(to: right.appendingPathComponent(".other-hidden"))
        let other = try await FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .compare(left: left, right: right, verificationMode: .standard, progress: { _ in })
        XCTAssertEqual(other.onlyInRightCount, 1)
    }
    func testReadFailureRetainsPhaseAndDoesNotLogSuccessfulCompletion() async throws {
        let run = UUID()
        let marker = "PRIVATE_PATH_\(UUID())"
        let diagnosticRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-comparison-diagnostics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: diagnosticRoot) }
        let store = TransferDiagnosticStore(directory: diagnosticRoot)
        do {
            _ = try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
                try await TransferDiagnostics.$runID.withValue(run) {
                    try await FolderComparer(fileAccess: FailingListing(), checksum: ChecksumEngine.shared)
                        .compare(left: URL(fileURLWithPath: "/\(marker)"), right: URL(fileURLWithPath: "/backup"), verificationMode: .standard, progress: { _ in })
                }
            }
            XCTFail("Expected unreadable source")
        } catch { XCTAssertEqual((error as NSError).code, 13) }
        let records = try events(run, store: store)
        XCTAssertEqual(records.first { $0["event"] as? String == "comparePhase" }?["comparisonPhase"] as? String, "listingSource")
        XCTAssertEqual(records.last?["comparisonOutcome"] as? String, "failed")
        XCTAssertNil(records.last?["matchingCount"])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: records), as: UTF8.self).contains(marker))
    }
    func testCancellationStillThrowsAndHasNoCompletedSummary() async throws {
        let run = UUID()
        let diagnosticRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-comparison-diagnostics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: diagnosticRoot) }
        let store = TransferDiagnosticStore(directory: diagnosticRoot)
        let task = Task {
            try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
                try await TransferDiagnostics.$runID.withValue(run) {
                    try await FolderComparer(fileAccess: CancelledListing(), checksum: ChecksumEngine.shared)
                        .compare(left: URL(fileURLWithPath: "/source"), right: URL(fileURLWithPath: "/backup"), verificationMode: .standard, progress: { _ in })
                }
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try events(run, store: store).last?["comparisonOutcome"] as? String, "cancelled")
    }
}
private final class FailingListing: FakeFileAccess, @unchecked Sendable {
    override func getFileList(from folderURL: URL) async throws -> [URL] { throw NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSFilePathErrorKey: folderURL.path]) }
}
private final class CancelledListing: FakeFileAccess, @unchecked Sendable {
    override func getFileList(from folderURL: URL) async throws -> [URL] { throw CancellationError() }
}
