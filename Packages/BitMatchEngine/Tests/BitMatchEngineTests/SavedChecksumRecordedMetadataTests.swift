import CryptoKit
import Foundation
import XCTest
@testable import BitMatchEngine

final class SavedChecksumRecordedMetadataTests: XCTestCase {
    /// The same preserve-all pipeline and MHL handoff as the real mounted
    /// exFAT regression, without requiring a disk image in the normal suite.
    func testPreservedRecordedAppleDoubleIsCheckedAndDamageIsNeverHidden() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("recorded-metadata-\(UUID())")
        let source = root.appendingPathComponent("Card")
        let target = root.appendingPathComponent("Backup")
        for directory in [source, target] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        try Data("synthetic footage".utf8).write(to: source.appendingPathComponent("clip.bin"))
        let companion = metadata()
        try companion.write(to: source.appendingPathComponent("._clip.bin"))
        XCTAssertEqual(try AppleDoubleSelection.review(source: source), ["._clip.bin"])
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .performFileOperation(sourceURL: source, destinationURLs: [target], verificationMode: .standard,
                settings: .init(), estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
        XCTAssertEqual(operation.results.count, 2)
        XCTAssertTrue(operation.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true })
        let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
            destinations: [target], source: source, settings: .init())
        XCTAssertEqual(plan.jobs.count, 1)
        let issues = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues,
            startTime: operation.startTime, source: source, toolVersion: "recorded-metadata-test")
        XCTAssertTrue(issues.isEmpty)
        let output = try XCTUnwrap(plan.jobs.first?.root)
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let evidence = try await checker.discover(under: output)
        XCTAssertEqual(Set(evidence.expectedFiles.keys), ["clip.bin", "._clip.bin"])
        let checked = try await checker.check(evidence) { _ in }
        XCTAssertTrue(checked.isIntact)
        XCTAssertEqual(Set(checked.matchingPaths), ["clip.bin", "._clip.bin"])
        XCTAssertTrue(checked.missingPaths.isEmpty)

        // A valid metadata header does not authorize ignoring its recorded hash.
        var changed = companion
        changed[changed.count - 1] ^= 1
        let destinationCompanion = output.appendingPathComponent("._clip.bin")
        try changed.write(to: destinationCompanion)
        let damaged = try await checker.check(evidence) { _ in }
        XCTAssertFalse(damaged.isIntact)
        XCTAssertEqual(damaged.changedPaths, ["._clip.bin"])
        XCTAssertTrue(damaged.missingPaths.isEmpty)

        try fm.removeItem(at: destinationCompanion)
        let missing = try await checker.check(evidence) { _ in }
        XCTAssertFalse(missing.isIntact)
        XCTAssertEqual(missing.missingPaths, ["._clip.bin"])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("._clip.bin")), companion)
    }

    func testUnrecordedFinderMetadataStaysIgnoredAndReservedTreesStayReserved() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("unrecorded-metadata-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let media = Data("synthetic footage".utf8)
        try media.write(to: root.appendingPathComponent("clip.bin"))
        try metadata().write(to: root.appendingPathComponent("._clip.bin"))
        try Data("Finder view state".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        let report = root.appendingPathComponent("record.json")
        let record = SavedChecksumCheck.Record(url: report, date: Date(), kind: .bitMatchReport)
        let expected = SavedChecksumCheck.ExpectedFile(relativePath: "clip.bin", checksum: sha(media), algorithm: .sha256, record: record)
        let discovery = SavedChecksumCheck.Discovery(root: root, expectedFiles: ["clip.bin": expected], records: [record])
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let result = try await checker.check(discovery) { _ in }
        XCTAssertTrue(result.isIntact)
        XCTAssertEqual(result.matchingPaths, ["clip.bin"])
        XCTAssertTrue(result.newPaths.isEmpty)

        for reserved in ["Reports/._clip.bin", "ascmhl/._clip.bin"] {
            let file = root.appendingPathComponent(reserved)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try metadata().write(to: file)
            let input = SavedChecksumCheck.ExpectedFile(relativePath: reserved, checksum: sha(metadata()), algorithm: .sha256, record: record)
            let reservedDiscovery = SavedChecksumCheck.Discovery(root: root, expectedFiles: [reserved: input], records: [record])
            let reservedResult = try await checker.check(reservedDiscovery) { _ in }
            XCTAssertFalse(reservedResult.isIntact)
            XCTAssertEqual(reservedResult.missingPaths, [reserved])
        }
    }

    private func metadata() -> Data {
        var bytes = [UInt8](repeating: 0, count: 70)
        func put(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
        }
        put(0x00051607, 0); put(0x00020000, 4)
        bytes[25] = 1
        put(9, 26); put(38, 30); put(32, 34)
        bytes[69] = 17
        return Data(bytes)
    }

    private func sha(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
