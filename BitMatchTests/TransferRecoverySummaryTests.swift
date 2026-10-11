import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct TransferRecoverySummaryTests {
    @Test func savedEvidenceSeparatesDestinationsAndDoesNotInflateDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-counts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card")
        let backups = [root.appendingPathComponent("Backup A"), root.appendingPathComponent("Backup B")]
        for url in [source] + backups { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: source),
            destinations: try backups.map(LocalTransferResource.init(url:)), verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), retryOf: UUID())
        record.state = .interrupted
        record.plannedFileCounts = [5, 5]
        func row(_ path: String, _ outcome: ResultOutcome, _ destination: Int, reused: Bool = false) -> ResultRow {
            ResultRow(path: path, status: outcome.statusText, size: 1, checksum: outcome.isVerified ? "abc" : nil,
                      destination: backups[destination].lastPathComponent,
                      destinationPath: backups[destination].appendingPathComponent("Card/\(path)").path, wasReused: reused)
        }
        record.results = [row("a", .verified, 0, reused: true), row("a", .verified, 0, reused: true),
                          row("b", .verified, 0), row("c", .failed, 0), row("._a", .excludedAppleDouble, 0),
                          row("a", .copiedUnverified, 1), row("b", .verified, 1), row("b", .checksumMismatch, 1)]
        var groups = TransferRecoverySummary.make(record)
        #expect(groups.count == 2)
        #expect(groups[0].reused == 1)
        #expect(groups[0].copied == 1)
        #expect(groups[0].failed == 1)
        #expect(groups[0].excluded == 1)
        #expect(groups[0].pending == 2)
        #expect(groups[1].reused == 0)
        #expect(groups[1].copied == 0)
        #expect(groups[1].unverified == 1)
        #expect(groups[1].failed == 1)
        #expect(groups[1].pending == 3)
        record.plannedFileCounts = nil
        #expect(TransferRecoverySummary.make(record).allSatisfy { $0.pending == nil })
        record.plannedFileCounts = [1, 5] // Inconsistent evidence cannot fabricate zero pending.
        #expect(TransferRecoverySummary.make(record)[0].pending == nil)
        record.results.append(ResultRow(path: "unknown", status: ResultOutcome.verified.statusText, size: 1,
                                        checksum: "abc", destination: "Unmatched backup"))
        groups = TransferRecoverySummary.make(record)
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.pending == nil })
        // Presentation must not mutate the unsafe terminal state or its underlying evidence.
        #expect(record.state == .interrupted)
        #expect(record.results.count == 9)
    }
}
