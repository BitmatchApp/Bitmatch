import Foundation
import Testing
@testable import BitMatchEngine

struct EvidenceWriterCommitOrderTests {
    @Test func withdrawnExportsReserveNamesAndRepeatedWithdrawalAvoidsCollisions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("withdrawn-exports-\(UUID())")
        let source = root.appendingPathComponent("card")
        let backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let finished = Date()
        var priorFiles: [URL] = []
        for iteration in 0..<2 {
            let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                cameraSettings: .init(), reportSettings: .init())
            try journal.markRunning(id: id)
            let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup],
                pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
                jobID: id, started: finished, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: .init(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
            if iteration == 1 { #expect(Set(files).isDisjoint(with: Set(priorFiles))) }
            try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
            // A pre-existing hidden name for this record must not block withdrawal.
            let collision = files[0].deletingLastPathComponent().appendingPathComponent(".unsettled-\(id.uuidString)-\(files[0].lastPathComponent)")
            try Data("previous".utf8).write(to: collision)
            try journal.interrupt(id: id, summary: "Keep the card", pendingWithdrawalReason: "Unavailable")
            try journal.retryPendingReportWithdrawals(id: id)
            #expect(journal.records.first { $0.id == id }?.pendingWithdrawalPaths == nil)
            #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            #expect(try Data(contentsOf: collision) == Data("previous".utf8))
            priorFiles = files
        }
    }
    private enum DeliberateFailure: Error { case encode }

    private struct FailingProject: Codable, Sendable {
        init() {}
        init(from _: Decoder) throws { throw DeliberateFailure.encode }
        func encode(to _: Encoder) throws { throw DeliberateFailure.encode }
    }

    @Test func orphanJSONReservesTheSameSuffixForEveryReportFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("report-names-\(UUID())")
        let source = root.appendingPathComponent("card")
        let backup = root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = TransferJournal(fileURL: root.appendingPathComponent("history.json"), recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let finished = Date()
        let name = EvidenceWriter.reportFileName(finished: finished, pathExtension: "json")
        try Data("orphan".utf8).write(to: reports.appendingPathComponent(name))
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup],
            pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
            jobID: id, started: finished, duration: 1, sourceURL: source, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let stems = files.map { $0.lastPathComponent.components(separatedBy: ".").first! }
        #expect(Set(stems).count == 1)
        #expect(stems[0].hasSuffix("-2"))
        try journal.recordPendingReportPaths(id: id, paths: files.map(\.path), publicationID: id)
        try journal.interrupt(id: id, summary: "Keep the card", pendingWithdrawalReason: "backup unavailable")
        try journal.retryPendingReportWithdrawals(id: id)
        #expect(journal.records[0].pendingWithdrawalPaths == nil)
        #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent(name).path))
    }

    @Test func stagingUsesResolvedReportsDirectoryAndIsInvisibleToScanner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-staging-volume-\(UUID())")
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        let actualReports = root.appendingPathComponent("OtherVolume/Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actualReports, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("Reports"), withDestinationURL: actualReports)
        defer { try? FileManager.default.removeItem(at: root) }

        try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [destination],
            pdfData: Data("%PDF-1.7".utf8), results: [], finished: Date(), checksumAlgorithm: nil,
            jobID: UUID(), started: Date(), duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
            safeToErase: false, beforePDFWrite: {
                let entries = try FileManager.default.contentsOfDirectory(at: actualReports, includingPropertiesForKeys: nil)
                let staging = try #require(entries.first { $0.lastPathComponent.hasPrefix(".BitMatch-report-staging-") })
                #expect(staging.resolvingSymlinksInPath().deletingLastPathComponent() == actualReports.resolvingSymlinksInPath())
            })

        let hidden = actualReports.appendingPathComponent(".BitMatch-report-staging-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        try Data("{broken".utf8).write(to: hidden.appendingPathComponent("BitMatch_Report_abandoned.json"))
        let scan = await EvidenceReader.scanReports(at: actualReports)
        #expect(scan.reports.count == 1)
        #expect(scan.skipped.isEmpty)
    }

    @Test func failedReplacementKeepsTheOriginalReportDiscoverable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-replace-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: Data("old PDF".utf8), results: [], finished: finished, checksumAlgorithm: nil,
            jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let oldContents = try original.map { try Data(contentsOf: $0) }

        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("new PDF".utf8), results: [], finished: finished, checksumAlgorithm: nil,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: false, beforePDFWrite: { throw DeliberateFailure.encode }, replacing: original)
        }
        #expect(try original.map { try Data(contentsOf: $0) } == oldContents)
        let scan = await EvidenceReader.scanReports(at: root)
        #expect(scan.reports.count == 1)
    }

    @Test func replacementCannotPublishAnUnrecordedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-replace-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: nil,
            jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let contents = try original.map { try Data(contentsOf: $0) }
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, replacing: original)
        }
        #expect(try original.map { try Data(contentsOf: $0) } == contents)
        let entries = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        #expect(Set(entries.map(\.lastPathComponent)) == Set(original.map(\.lastPathComponent)))
    }

    @Test func jsonIsPublishedLastAndFailedRestoreDoesNotLeaveSafePDF() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: Data("cautious".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
            jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let pdf = try #require(original.first { $0.pathExtension == "pdf" })
        let json = try #require(original.first { $0.pathExtension == "json" })
        let oldJSON = try Data(contentsOf: json)
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("safe".utf8), results: [], finished: finished, checksumAlgorithm: .sha256,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, replacing: original, beforePublish: { url in
                    if url.pathExtension == "json" {
                        #expect(try Data(contentsOf: pdf) == Data("safe".utf8))
                        #expect(try Data(contentsOf: json) == oldJSON)
                        let reports = pdf.deletingLastPathComponent().resolvingSymlinksInPath()
                        let entries = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
                        #expect(entries.contains { $0.lastPathComponent.hasSuffix(".sha-256.txt") })
                        #expect(entries.contains { $0.pathExtension == "csv" })
                        let staging = try #require(entries.first { $0.lastPathComponent.hasPrefix(".BitMatch-report-staging-") })
                        // Make the actual final rename fail after the PDF published.
                        try FileManager.default.removeItem(at: staging.appendingPathComponent(json.lastPathComponent))
                    }
                }, beforeRestore: { url in
                    if url.pathExtension == "pdf" { throw DeliberateFailure.encode }
                })
        }
        #expect(!FileManager.default.fileExists(atPath: pdf.path))
        #expect(try Data(contentsOf: json) == oldJSON)
    }

    @Test(arguments: ["csv", "txt", "pdf", "json"])
    func publicationFailureLeavesNoSafeJSONOrPDF(failingExtension: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-publish-failure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("safe".utf8), results: [], finished: Date(), checksumAlgorithm: .sha256,
                jobID: UUID(), started: Date(), duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, beforePublish: { url in
                    if url.pathExtension == failingExtension { throw DeliberateFailure.encode }
                })
        }
        let reports = root.appendingPathComponent("Reports")
        let entries = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
        #expect(entries.isEmpty)
    }

    @Test func stagingCleanupFailureFailsExportAndWithdrawsPublishedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("safe".utf8), results: [], finished: Date(), checksumAlgorithm: nil,
                jobID: UUID(), started: Date(), duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, beforeStagingRemoval: { _ in throw DeliberateFailure.encode })
        }
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
    }

    @Test func simultaneousExportsUseDifferentNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-concurrent-reports-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        @Sendable func export() async throws -> [URL] {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("PDF".utf8), results: [], finished: finished, checksumAlgorithm: nil,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        }
        async let first = export()
        async let second = export()
        let (firstFiles, secondFiles) = try await (first, second)
        #expect(Set(firstFiles).isDisjoint(with: Set(secondFiles)))
        let scan = await EvidenceReader.scanReports(at: root)
        #expect(scan.reports.count == 2)
    }

    @Test func failedReplacementRestoresAlreadyReplacedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-replace-rollback-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let finished = Date()
        let original = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
            pdfData: Data("cautious".utf8), results: [], finished: finished, checksumAlgorithm: nil,
            jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
            totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: false)
        let oldContents = try original.map { try Data(contentsOf: $0) }
        await #expect(throws: (any Error).self) {
            try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [root],
                pdfData: Data("safe".utf8), results: [], finished: finished, checksumAlgorithm: nil,
                jobID: UUID(), started: finished, duration: 1, sourceURL: nil, fileCount: 0, matchCount: 0,
                totalBytesProcessed: 0, workers: 1, filesPerSecond: 1, prefs: ReportPrefs(),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, replacing: original, beforePublish: { url in
                    if url.pathExtension == "json" { throw DeliberateFailure.encode }
                })
        }
        #expect(try original.map { try Data(contentsOf: $0) } == oldContents)
    }

    @Test func pdfWriteFailureLeavesNoPublishedReportAndCleansStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-pdf-failure-\(UUID())")
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) {
            _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [destination],
                pdfData: Data("%PDF-1.7".utf8), results: [ResultRow(path: "/Card/A", status: ResultOutcome.verified.statusText,
                    size: 4, checksum: "abc", destination: destination.path)],
                finished: Date(), checksumAlgorithm: .sha256, jobID: UUID(), started: Date(), duration: 1,
                sourceURL: URL(fileURLWithPath: "/Card"), fileCount: 1, matchCount: 1, totalBytesProcessed: 4,
                workers: 1, filesPerSecond: 1, prefs: ReportPrefs(verificationMode: .standard),
                generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                safeToErase: true, beforePDFWrite: { throw DeliberateFailure.encode })
        }
        let reports = destination.appendingPathComponent("Reports")
        let files = (try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)) ?? []
        #expect(files.isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(!siblings.contains { $0.lastPathComponent.hasPrefix(".BitMatch-report-staging-") })
    }

    @Test func publishedReportRemainsDiscoverableAndStagingIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-staged-report-\(UUID())")
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [destination],
            pdfData: Data("%PDF-1.7".utf8), results: [ResultRow(path: "/Card/A", status: ResultOutcome.verified.statusText,
                size: 4, checksum: "abc", destination: destination.path)],
            finished: Date(), checksumAlgorithm: .sha256, jobID: UUID(), started: Date(), duration: 1,
            sourceURL: URL(fileURLWithPath: "/Card"), fileCount: 1, matchCount: 1, totalBytesProcessed: 4,
            workers: 1, filesPerSecond: 1, prefs: ReportPrefs(verificationMode: .standard),
            generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true)
        let scan = await EvidenceReader.scanReports(at: destination)
        #expect(scan.reports.count == 1)
        #expect(scan.reports.first?.url.deletingLastPathComponent().lastPathComponent == "Reports")
        let siblings = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        #expect(!siblings.contains { $0.lastPathComponent.hasPrefix(".BitMatch-report-staging-") })
    }

    @Test func laterEvidenceFailureNeverLeavesAnEarlierPDFVerdict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-evidence-order-\(UUID())", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let finished = Date(timeIntervalSince1970: 1_800_000_060)
        await #expect(throws: (any Error).self) {
            _ = try await EvidenceWriter.write(
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
