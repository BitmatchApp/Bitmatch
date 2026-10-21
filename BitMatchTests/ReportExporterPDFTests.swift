import Foundation
import Testing
import XCTest
import Darwin
import Synchronization
import PDFKit
@testable import BitMatch
import BitMatchEngine

/// Guards the Mac's existing per-transfer PDF report (Promise 3) as the PDF
/// renderer becomes shared with iPad and iPhone (THESIS decision, 2026-09-25:
/// "iPad and iPhone get a PDF report too").
struct ReportExporterPDFTests {
    // Plant: in `ReportExporter.export`, change `shouldGenerateFullReport` to
    // `false` right before the `pdfData` assignment.
    @Test
    func macWritesAPDFReportNextToCSVAndJSON() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-mac-pdf-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let fileURL = destination.appendingPathComponent("DSC_0001.CR2")
        try Data(repeating: 0xAB, count: 4096).write(to: fileURL)

        let rows = [
            ResultRow(path: "/card/DSC_0001.CR2", status: "✅ Match", size: 4096,
                      checksum: "abc123", destination: destination.path,
                      destinationPath: fileURL.path)
        ]

        try await ReportExporter.export(
            mode: .copyAndVerify,
            jobID: UUID(),
            started: Date(timeIntervalSince1970: 1_800_000_000),
            finished: Date(timeIntervalSince1970: 1_800_000_060),
            sourceURL: URL(fileURLWithPath: "/card"),
            destinationURLs: [destination],
            results: rows,
            fileCount: 1,
            matchCount: 1,
            prefs: ReportPrefs(makeReport: true),
            workers: 1,
            totalBytesProcessed: 4096,
            safetyState: .safeToErase
        )

        let reportsDir = destination.appendingPathComponent("Reports", isDirectory: true)
        let files = try fm.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil)

        let pdfURL = try #require(files.first { $0.pathExtension == "pdf" }, "no PDF written in \(reportsDir.path)")
        let data = try Data(contentsOf: pdfURL)
        #expect(!data.isEmpty)
        #expect(data.prefix(5) == Data("%PDF-".utf8), "file does not start with a PDF header")

        #expect(files.contains { $0.pathExtension == "csv" })
        #expect(files.contains { $0.pathExtension == "json" })
    }

    @Test
    func automaticReportSeparatesSelectedChecksFromRecordedResults() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-assurance-report-\(UUID())", isDirectory: true)
        let destination = root.appendingPathComponent("Backup", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let rows = [
            ResultRow(path: "/card/clip.mov", status: ResultOutcome.verified.statusText,
                      size: 5, checksum: "digest", destination: destination.path),
            ResultRow(path: "/card/other.mov", status: ResultOutcome.failed.statusText,
                      size: 5, checksum: nil, destination: destination.path),
            ResultRow(path: "/card/._clip.mov", status: ResultOutcome.excludedAppleDouble.statusText,
                      size: 1, checksum: nil, destination: destination.path)
        ]
        try await ReportExporter.export(
            mode: .copyAndVerify, jobID: UUID(), started: Date(timeIntervalSince1970: 1_800_000_000),
            finished: Date(timeIntervalSince1970: 1_800_000_060), sourceURL: URL(fileURLWithPath: "/card"),
            destinationURLs: [destination], results: rows, fileCount: rows.count, matchCount: 1,
            prefs: ReportPrefs(verificationMode: .standard, makeReport: true), workers: 1,
            totalBytesProcessed: 10, safetyState: .needsAttention
        )
        let reports = destination.appendingPathComponent("Reports", isDirectory: true)
        let files = try fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
        let pdfURL = try #require(files.first { $0.pathExtension == "pdf" })
        let pdf = try #require(PDFDocument(data: Data(contentsOf: pdfURL)))
        let text = try #require(pdf.string)
        #expect(text.contains("Check plan:"))
        #expect(text.contains("no separate card reread"))
        #expect(text.contains("Saved: 1/2 selected backup results marked verified"))
        #expect(text.contains("NOT SAFE TO ERASE"))

        let csvURL = try #require(files.first { $0.pathExtension == "csv" })
        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        #expect(csv.contains("Recorded Verified Backup Results,1"))
        #expect(csv.contains("Recorded Excluded Source Files,1"))
        #expect(csv.contains("selected mode does not prove every check finished"))

        let jsonURL = try #require(files.first { $0.pathExtension == "json" })
        let json = try Data(contentsOf: jsonURL)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let verification = try #require(object["verification"] as? [String: Any])
        let scope = try #require(verification["scope"] as? [String: Any])
        #expect(scope["selectedMode"] as? String == "Standard")
        #expect(scope["recordedSelectedResults"] as? Int == 2)
        #expect(scope["recordedVerifiedResults"] as? Int == 1)
        #expect(scope["recordedExcludedSourceFiles"] as? Int == 1)
        #expect(object["safeToErase"] as? Bool == false)
        #expect(EvidenceReader.snapshot(reportData: json, reportURL: jsonURL) != nil)
    }
}

#if os(macOS)
/// Opt-in report-only scale probe. It uses synthetic rows and an actual app
/// PDF renderer, not media files or a transfer-pipeline reproduction.
@MainActor
final class ReportPDFMemoryTests: XCTestCase {
    private let fileCount = 20_000
    private let rowsPerFile = 2

    func testOptInFortyThousandRowPDFMemory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TEST_RUNNER_BITMATCH_REPORT_PDF_MEMORY"] == "1"
                || environment["BITMATCH_REPORT_PDF_MEMORY"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_BITMATCH_REPORT_PDF_MEMORY=1 for the guarded 40k-row PDF probe")
        }
        guard let artifactsPath = environment["TEST_RUNNER_BITMATCH_REPORT_PDF_ARTIFACTS"]
                ?? environment["BITMATCH_REPORT_PDF_ARTIFACTS"] else {
            throw ReportPDFMemoryError.invalidArtifacts
        }
        let fileManager = FileManager.default
        let privateRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let requestedRoot = URL(fileURLWithPath: artifactsPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard requestedRoot.path.hasPrefix(privateRoot.path + "/"),
              !requestedRoot.path.hasPrefix("/Volumes/"),
              !fileManager.fileExists(atPath: requestedRoot.path) else {
            throw ReportPDFMemoryError.invalidArtifacts
        }
        try fileManager.createDirectory(at: requestedRoot, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])

        var outcome = "failed"
        let receiptURL = requestedRoot.appendingPathComponent("report-pdf-memory.json")
        let metrics = ReportPDFMemoryMetrics(maximumSeconds: 1_200, receiptURL: receiptURL,
                                             fileCount: fileCount, resultRows: fileCount * rowsPerFile)
        defer {
            metrics.persist(outcome: outcome)
            print("REPORT_PDF_MEMORY outcome=\(outcome) files=\(fileCount) rows=\(fileCount * rowsPerFile) receipt=\(receiptURL.path)")
        }

        let sampler = Task.detached {
            while !Task.isCancelled {
                _ = metrics.sample()
                metrics.persistCheckpointIfDue()
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
            }
        }

        do {
            metrics.mark("syntheticRows")
            var results: [ResultRow] = []
            results.reserveCapacity(fileCount * rowsPerFile)
            for index in 0..<fileCount {
                autoreleasepool {
                    let name = "PDFMEM-\(String(format: "%05d", index)).dat"
                    let path = "/synthetic-card/\(name)"
                    for backup in ["/synthetic-backup-a", "/synthetic-backup-b"] {
                        results.append(ResultRow(path: path, status: ResultOutcome.verified.statusText,
                                                 size: 1, checksum: String(repeating: "0123456789abcdef", count: 4),
                                                 destination: backup, destinationPath: "\(backup)/\(name)"))
                    }
                }
            }
            guard results.count == fileCount * rowsPerFile else { throw ReportPDFMemoryError.invalidOutput }
            try metrics.requireSafe()

            let summary = ReportSummary(
                jobID: UUID(), started: Date(timeIntervalSince1970: 1_800_000_000),
                finished: Date(timeIntervalSince1970: 1_800_000_060), mode: .copyAndVerify,
                source: "/synthetic-card", destinations: ["/synthetic-backup-a", "/synthetic-backup-b"],
                totalFiles: results.count, matched: results.count, issues: 0, workers: 2,
                appVersion: "test", osVersion: "test", client: "", production: "", company: "",
                verificationMethod: "SHA-256", verificationMode: .standard,
                verificationScope: VerificationScopeEvidence(selectedMode: .standard, results: results),
                totalBytesProcessed: Int64(results.count), averageSpeed: 0,
                clientLogoData: nil, companyLogoData: nil, photographyJob: nil, safetyState: .safeToErase
            )
            metrics.mark("pdfRender")
            try metrics.requireSafe()
            // The renderer is synchronous. The memory cap latches a failure but
            // cannot interrupt native PDF work already in progress.
            let pdfData = ReportPDFRenderer.renderPDF(summary: summary, results: results) { phase in
                metrics.observe(phase)
            }
            try pdfData.write(to: requestedRoot.appendingPathComponent("rendered-unvalidated.pdf"), options: .withoutOverwriting)
            if metrics.snapshot().guardTriggered { throw ReportPDFMemoryError.guardTriggered }
            guard metrics.sample() == false, !pdfData.isEmpty else {
                throw ReportPDFMemoryError.invalidOutput
            }

            metrics.mark("pdfDocumentDecode")
            guard let document = PDFDocument(data: pdfData), document.pageCount > 1 else {
                throw ReportPDFMemoryError.invalidOutput
            }
            metrics.mark("pdfTextExtraction")
            guard let text = document.string else { throw ReportPDFMemoryError.invalidOutput }

            metrics.mark("pdfCoverage")
            let expression = try NSRegularExpression(pattern: "PDFMEM-[0-9]{5}\\.dat")
            let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            var occurrences: [String: Int] = [:]
            for match in matches {
                guard let range = Range(match.range, in: text) else { throw ReportPDFMemoryError.invalidOutput }
                occurrences[String(text[range]), default: 0] += 1
            }
            guard occurrences.count == fileCount,
                  occurrences.values.allSatisfy({ $0 == rowsPerFile }),
                  matches.count == fileCount * rowsPerFile else {
                throw ReportPDFMemoryError.incompleteManifest
            }
            metrics.finish(pdfBytes: pdfData.count, pageCount: document.pageCount)
            guard !metrics.snapshot().guardTriggered,
                  !metrics.snapshot().deadlineTriggered else { throw ReportPDFMemoryError.guardTriggered }
            sampler.cancel()
            await sampler.value
            try metrics.requireSafe()
            outcome = "passed"
        } catch {
            sampler.cancel()
            await sampler.value
            _ = metrics.sample()
            throw error
        }
    }
}

private enum ReportPDFMemoryError: Error {
    case invalidArtifacts, invalidOutput, incompleteManifest, guardTriggered
}

private final class ReportPDFMemoryMetrics: Sendable {
    struct Event: Codable {
        let phase: String
        let completed: Int?
        let total: Int?
        let value: Int?
    }
    struct Snapshot: Codable {
        var phase = "startup"
        var samples = 0
        var initialMiB: Int?
        var lastMiB: Int?
        var peakMiB = 0
        var guardTriggered = false
        var deadlineTriggered = false
        var sampleFailed = false
        var pdfBytes: Int?
        var pageCount: Int?
        var phaseFootprints: [String: PhaseFootprint] = [:]
        var events: [Event] = []
    }
    struct PhaseFootprint: Codable {
        var peakMiB = 0
        var lastMiB = 0
        var samples = 0
    }
    struct Receipt: Codable {
        let outcome: String
        let workload: String
        let fileCount: Int
        let resultRows: Int
        let memoryLimitMiB: Int
        let maximumSeconds: Int
        let metrics: Snapshot
    }

    private let state = Mutex(Snapshot())
    private let started = ProcessInfo.processInfo.systemUptime
    private let maximumSeconds: TimeInterval
    private let limitMiB = 1_024
    private let receiptURL: URL
    private let fileCount: Int
    private let resultRows: Int
    private let lastCheckpointWrite = Mutex(ProcessInfo.processInfo.systemUptime)
    private let receiptWriteLock = Mutex(())

    init(maximumSeconds: TimeInterval, receiptURL: URL, fileCount: Int, resultRows: Int) {
        self.maximumSeconds = maximumSeconds
        self.receiptURL = receiptURL
        self.fileCount = fileCount
        self.resultRows = resultRows
    }
    func snapshot() -> Snapshot { state.withLock { $0 } }

    func mark(_ phase: String) {
        state.withLock { $0.phase = phase }
        _ = sample()
        persist(outcome: "running")
    }

    func observe(_ phase: ReportPDFRenderer.Phase) {
        let event: Event
        switch phase {
        case .blockConstructionStarted(let rowCount):
            event = Event(phase: "blockConstructionStarted", completed: nil, total: rowCount, value: nil)
        case .blockConstructionFinished(let blockCount):
            event = Event(phase: "blockConstructionFinished", completed: blockCount, total: nil, value: nil)
        case .measurementProgress(let completed, let total):
            event = Event(phase: "measurement", completed: completed, total: total, value: nil)
        case .paginationStarted(let blockCount):
            event = Event(phase: "paginationStarted", completed: nil, total: blockCount, value: nil)
        case .paginationFinished(let blockCount, let pageCount):
            event = Event(phase: "paginationFinished", completed: blockCount, total: pageCount, value: nil)
        case .pageRenderingStarted(let pageCount, let blockCount):
            event = Event(phase: "pageRenderingStarted", completed: nil, total: pageCount, value: blockCount)
        case .pageRenderProgress(let completed, let total):
            event = Event(phase: "pageRender", completed: completed, total: total, value: nil)
        case .finalPDFData(let bytes, let pageCount, let blockCount):
            event = Event(phase: "finalPDFData", completed: blockCount, total: pageCount, value: bytes)
        }
        state.withLock {
            $0.phase = event.phase
            $0.events.append(event)
            if case .finalPDFData(let bytes, let pages, _) = phase {
                $0.pdfBytes = bytes
                $0.pageCount = pages
            }
        }
        _ = sample()
        // Renderer callbacks are sparse checkpoints (128 measured blocks or
        // 16 rendered pages), so an interrupted run keeps recent phase data
        // without rewriting the receipt on every 25 ms memory sample.
        persist(outcome: "running")
    }

    func finish(pdfBytes: Int, pageCount: Int) {
        state.withLock {
            $0.pdfBytes = pdfBytes
            $0.pageCount = pageCount
        }
        _ = sample()
        persist(outcome: "running")
    }

    func sample() -> Bool {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let current: Int? = status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
        return state.withLock { value in
            guard let current else {
                value.sampleFailed = true
                value.guardTriggered = true
                return true
            }
            if value.samples == 0 { value.initialMiB = current }
            value.samples += 1
            value.lastMiB = current
            value.peakMiB = max(value.peakMiB, current)
            var phase = value.phaseFootprints[value.phase] ?? PhaseFootprint()
            phase.samples += 1
            phase.lastMiB = current
            phase.peakMiB = max(phase.peakMiB, current)
            value.phaseFootprints[value.phase] = phase
            if current >= limitMiB { value.guardTriggered = true }
            if ProcessInfo.processInfo.systemUptime - started >= maximumSeconds { value.deadlineTriggered = true }
            return value.guardTriggered || value.deadlineTriggered
        }
    }

    func requireSafe() throws {
        guard !sample(), !snapshot().guardTriggered, !snapshot().deadlineTriggered else {
            throw ReportPDFMemoryError.guardTriggered
        }
    }

    func receipt(outcome: String, fileCount: Int, resultRows: Int) -> Receipt {
        Receipt(outcome: outcome, workload: "synthetic-two-backup-report-only", fileCount: fileCount,
                resultRows: resultRows, memoryLimitMiB: limitMiB, maximumSeconds: Int(maximumSeconds),
                metrics: snapshot())
    }

    func persist(outcome: String) {
        receiptWriteLock.withLock { _ in
            guard let data = try? JSONEncoder().encode(receipt(outcome: outcome, fileCount: fileCount,
                                                               resultRows: resultRows)) else { return }
            do {
                try data.write(to: receiptURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
            } catch {
                // The deferred final write remains best-effort too; the probe's
                // own failure should not be replaced by an artifact-write failure.
            }
        }
    }

    func persistCheckpointIfDue() {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldPersist = lastCheckpointWrite.withLock { lastWrite in
            guard now - lastWrite >= 5 else { return false }
            lastWrite = now
            return true
        }
        if shouldPersist { persist(outcome: "running") }
    }
}
#endif
