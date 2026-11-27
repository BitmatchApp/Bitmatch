import Foundation
import CryptoKit
import Testing
@testable import BitMatchEngine

struct IssueNinetyFiveTests {
    @Test func readbackErrorIsPerFileAndKeepsEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue95-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("card")
        let backups = [root.appendingPathComponent("backup-a"), root.appendingPathComponent("backup-b")]
        for folder in [source] + backups { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for name in ["a.mov", "z.mov"] { try Data("clip data".utf8).write(to: source.appendingPathComponent(name)) }
        let hooks = DestinationWriter.FanOutHooks(beforeDestinationRead: { index, path in
            if index == 0 && path == "z.mov" {
                throw NSError(domain: "InjectedReadback", code: 7, userInfo: [NSLocalizedDescriptionKey: "transient read error"])
            }
        })
        let settings = CameraLabelSettings()
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks)
            .performFileOperation(sourceURL: source, destinationURLs: backups, verificationMode: .standard,
                                  settings: settings, progressCallback: { _ in }, onFileResult: nil)
        let backupRoot = SafetyValidator.resolvedDestinationRoot(source: source, destination: backups[0], settings: settings)
        let rows = TransferCompletion.rows(from: operation)
        let failed = try #require(rows.first { $0.path == source.appendingPathComponent("z.mov").path && $0.destinationPath == backupRoot.appendingPathComponent("z.mov").path })
        let verified = try #require(rows.first { $0.path == source.appendingPathComponent("a.mov").path && $0.destinationPath == backupRoot.appendingPathComponent("a.mov").path })
        #expect(!failed.isSuccessStatus)
        #expect(failed.size == 9)
        #expect(failed.failureDetail?.contains("verify readback") == true)
        #expect(failed.failureDetail?.contains("InjectedReadback") == true)
        #expect(failed.failureDetail?.contains("7") == true)
        #expect(verified.isVerifiedStatus && verified.checksum != nil)
        #expect(rows.filter { $0.isVerifiedStatus && $0.checksum != nil }.count == 3)
        let decoded = try JSONDecoder().decode(ResultRow.self, from: JSONEncoder().encode(failed))
        #expect(decoded.failureDetail == failed.failureDetail)
        let reportItem = JSONReportItem(from: failed)
        #expect(reportItem.failureDetail == failed.failureDetail)
        let csv = try EvidenceWriter.makeEnhancedCSV(results: rows, started: Date(), duration: 1, filesPerSecond: 1, project: nil)
        #expect(csv.contains("verify readback"))
        #expect(csv.contains("InjectedReadback"))
        let verdict = TransferCompletion.verdict(rows: rows, sourceFiles: operation.sourceManifest, destinations: backups,
            source: source, settings: settings, mode: .standard, generateASCMHL: false, handoffIssues: [], reportIssue: nil,
            project: .init(didPersist: true, locallySafe: nil))
        #expect(!verdict.success)
        let compared = try await FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .compare(left: source, right: backupRoot, verificationMode: .standard, progress: { _ in })
        #expect(compared.isClean)
        let digest = SHA256.hash(data: Data("clip data".utf8)).map { String(format: "%02x", $0) }.joined()
        let manifest = "<hashlist xmlns=\"urn:ASC:MHL:v2.0\" version=\"2.0\"><hashes>" +
            ["a.mov", "z.mov"].map { "<hash><path>\($0)</path><sha256>\(digest)</sha256></hash>" }.joined() +
            "</hashes></hashlist>"
        let history = backupRoot.appendingPathComponent("ascmhl")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: history.appendingPathComponent("0001_test.mhl"))
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let checked = try await checker.check(try await checker.discover(under: backupRoot)) { _ in }
        #expect(checked.isIntact)
    }
}
