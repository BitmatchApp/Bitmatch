import Foundation
import Testing
@testable import BitMatchEngine

struct EvidenceWriterCommitOrderTests {
    private enum DeliberateFailure: Error { case encode }

    private struct FailingProject: Codable, Sendable {
        init() {}
        init(from _: Decoder) throws { throw DeliberateFailure.encode }
        func encode(to _: Encoder) throws { throw DeliberateFailure.encode }
    }

    @Test func laterEvidenceFailureNeverLeavesAnEarlierPDFVerdict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-evidence-order-\(UUID())", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let finished = Date(timeIntervalSince1970: 1_800_000_060)
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(
                kind: .copyAndVerify,
                destinationURLs: [destination],
                pdfData: Data("%PDF-1.7 safer verdict".utf8),
                results: [ResultRow(
                    path: "/Card/A.mov", status: ResultOutcome.verified.statusText,
                    size: 4, checksum: "abc", destination: destination.path
                )],
                finished: finished,
                checksumAlgorithm: .sha256,
                jobID: UUID(),
                started: Date(timeIntervalSince1970: 1_800_000_000),
                duration: 60,
                sourceURL: URL(fileURLWithPath: "/Card"),
                fileCount: 1,
                matchCount: 1,
                totalBytesProcessed: 4,
                workers: 1,
                filesPerSecond: 1,
                prefs: ReportPrefs(verificationMode: .standard),
                generateFullReport: true,
                projectCSV: nil,
                projectJSON: FailingProject()
            )
        }

        let reports = destination.appendingPathComponent("Reports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: reports, includingPropertiesForKeys: nil
        )) ?? []
        #expect(!files.contains { $0.pathExtension == "pdf" })
    }
}
