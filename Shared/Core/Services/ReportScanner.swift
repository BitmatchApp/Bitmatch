// ReportScanner.swift - Turns found reports into Master Report cards.
import Foundation
import CryptoKit
import BitMatchEngine

/// The app's side of reading reports: `EvidenceReader` finds and decodes
/// them (the same rules on every platform), and this maps each one to a
/// `TransferCard` for the Master Report. Only choosing the folder differs
/// by platform.
enum ReportScanner {
    typealias SkippedReport = EvidenceReader.SkippedReport
    typealias Snapshot = EvidenceReader.Snapshot

    struct ScanResult {
        let cards: [TransferCard]
        let skipped: [SkippedReport]
    }

    /// Cards for the reports written on the same calendar day as `day`.
    static func scan(at root: URL, day: Date = Date(), calendar: Calendar = .current) async -> [TransferCard] {
        await scanReports(at: root, day: day, calendar: calendar).cards
    }

    /// `scan`, plus the reports from that day that were skipped because they
    /// were too large or could not be read. `maxBytes` exists for tests.
    static func scanReports(at root: URL, day: Date = Date(), calendar: Calendar = .current,
                            maxBytes: Int = EvidenceReader.maxReportBytes) async -> ScanResult {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let found = await EvidenceReader.scanReports(at: root, day: day, calendar: calendar, maxBytes: maxBytes)
        var cards: [TransferCard] = []
        for report in found.reports {
            if Task.isCancelled { break }
            let pdfIsValid = await validatePDF(report.snapshot.pdfEvidence, beside: report.url)
            if Task.isCancelled { break }
            cards.append(transferCard(from: report.snapshot, reportURL: report.url, pdfIsValid: pdfIsValid))
        }
        return ScanResult(cards: cards.sorted { $0.timestamp > $1.timestamp }, skipped: found.skipped)
    }

    /// Returns nil for JSON that is not a BitMatch report.
    static func transferCard(reportData: Data, reportURL: URL) -> TransferCard? {
        EvidenceReader.snapshot(reportData: reportData, reportURL: reportURL)
            .map { transferCard(from: $0, reportURL: reportURL) }
    }

    static func transferCard(from report: Snapshot, reportURL: URL, pdfIsValid: Bool? = nil) -> TransferCard {
        let mode = EvidenceReader.verificationMode(method: report.verification?.method, algorithm: report.verification?.algorithm)
        let verified = EvidenceReader.isVerified(matches: report.statistics.matches, issues: report.statistics.issues, mode: mode,
            totalResults: report.statistics.totalFiles, safeToErase: report.safeToErase)
            && (report.pdfEvidence == nil || pdfIsValid == true)
        let sourceURL = URL(fileURLWithPath: report.source.path)
        let destinationURLs = report.destinations.map { URL(fileURLWithPath: $0.path) }
        let cameraName = cameraName(for: report)
        // The exporter stamps the report when the transfer finished.
        let finished = report.timestamp
        let started = finished.addingTimeInterval(-max(0, report.performance.totalDuration))

        func folder(_ url: URL) -> FolderInfo {
            FolderInfo(url: url, fileCount: report.source.fileCount, totalSize: report.source.totalSize,
                       lastModified: finished, isInternalDrive: !url.path.hasPrefix("/Volumes/"))
        }

        let cameraCard = CameraCard(
            name: cameraName,
            manufacturer: manufacturer(for: cameraName),
            model: cameraName,
            fileCount: report.source.fileCount,
            totalSize: report.source.totalSize,
            detectionConfidence: report.source.cameraDetected != nil ? 0.95 : 0.6,
            metadata: ["reportPath": reportURL.path, "reportTimestamp": finished],
            volumeURL: sourceURL,
            cameraType: cameraType(for: cameraName),
            mediaPath: sourceURL
        )
        let metadata = TransferMetadata(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            startTime: started,
            endTime: finished,
            totalFiles: report.source.fileCount,
            totalSize: report.source.totalSize,
            // An unrecorded mode is shown as Quick, the weakest claim.
            verificationMode: mode ?? .quick,
            cameraSettings: nil
        )
        let message: String
        if verified {
            message = "Verified"
        } else if report.safeToErase == false {
            message = mode == .quick ? "Copied, not verified" : "Review required"
        } else if report.pdfEvidence != nil && pdfIsValid != true {
            message = "Report PDF could not be validated"
        } else if report.statistics.issues > 0 {
            message = "\(report.statistics.issues) issues"
        } else {
            message = "Not verified"
        }
        return TransferCard(
            source: folder(sourceURL),
            destinations: destinationURLs.map(folder),
            cameraCard: cameraCard,
            metadata: metadata,
            progress: 1.0,
            state: .completed(OperationCompletionInfo(success: verified, message: message))
        )
    }

    /// PDF is the writer's final commit marker. A saved JSON must not gain a
    /// green verdict if its requested PDF never published or later changed.
    private static func validatePDF(_ evidence: ReportPDFEvidence?, beside reportURL: URL) async -> Bool {
        guard let evidence else { return true } // Legacy / JSON-only report.
        let name = evidence.filename
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              name.lowercased().hasSuffix(".pdf"), evidence.sha256.count == 64,
              evidence.sha256.lowercased().unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else { return false }
        do {
            try Task.checkCancellation()
            let root = try PinnedDestinationDirectory.open(destination: reportURL.deletingLastPathComponent(), rootComponents: [])
            let file = try root.openRegularFile(at: [name])
            let before = try file.snapshot()
            // JSON scanning already has a size limit. Bound PDF work too,
            // while streaming chunks keeps memory independent of report size.
            guard before.st_size > 0, before.st_size <= 256 * 1024 * 1024 else { return false }
            let handle = try file.readingHandle()
            defer { try? handle.close() }
            var hash = SHA256()
            var bytes: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hash.update(data: chunk)
                bytes += Int64(chunk.count)
            }
            let after = try file.snapshot()
            let live = try root.openRegularFile(at: [name]).snapshot()
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  before.st_dev == live.st_dev, before.st_ino == live.st_ino, before.st_size == live.st_size,
                  bytes == Int64(before.st_size), root.logicalRootStillMatchesPinnedDirectory() else { return false }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == evidence.sha256.lowercased()
        } catch { return false }
    }

    /// The detected camera, else the card's folder name. The Master Report
    /// groups cards by this name.
    static func cameraName(for report: Snapshot) -> String {
        if let detected = report.source.cameraDetected?.trimmingCharacters(in: .whitespaces), !detected.isEmpty {
            return detected
        }
        if let name = report.source.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name != "—" {
            return name
        }
        let last = URL(fileURLWithPath: report.source.path).lastPathComponent
        return last.isEmpty || last == "—" || last == "/" ? "Unknown Camera" : last
    }

    private static func manufacturer(for cameraName: String) -> String {
        let upper = cameraName.uppercased()
        if upper.contains("SONY") || upper.contains("FX") || upper.contains("A7") { return "Sony" }
        if upper.contains("CANON") || upper.contains("C70") || upper.contains("C100") { return "Canon" }
        if upper.contains("RED") || upper.contains("DRAGON") { return "RED" }
        if upper.contains("ARRI") || upper.contains("ALEXA") { return "ARRI" }
        if upper.contains("BLACKMAGIC") || upper.contains("URSA") { return "Blackmagic" }
        if upper.contains("DJI") { return "DJI" }
        if upper.contains("GOPRO") { return "GoPro" }
        return "Unknown"
    }

    private static func cameraType(for cameraName: String) -> CameraType {
        let upper = cameraName.uppercased()
        if upper.contains("SONY") && upper.contains("FX6") { return .sonyFX6 }
        if upper.contains("SONY") && upper.contains("FX3") { return .sonyFX3 }
        if upper.contains("SONY") && upper.contains("A7") { return .sonyA7S }
        if upper.contains("SONY") { return .sony }
        if upper.contains("CANON") && upper.contains("C70") { return .canonC70 }
        if upper.contains("CANON") { return .canon }
        if upper.contains("ARRI") || upper.contains("ALEXA") { return .arriAlexa }
        if upper.contains("RED") { return .redCamera }
        if upper.contains("BLACKMAGIC") { return .blackmagic }
        if upper.contains("GOPRO") { return .gopro }
        if upper.contains("DJI") { return .dji }
        return .generic
    }
}
