// EvidenceReader.swift - Finds and reads BitMatch JSON reports.
import Foundation

/// Finds the JSON reports `EvidenceWriter` writes and decodes the fields the
/// Master Report needs. Mac and iPad/iPhone share this one rule for which
/// files count, how large they may be, which day they belong to, and what
/// "verified" means. The app's `ReportScanner` turns each into a card.
public enum EvidenceReader: Sendable {
    /// Reports larger than this are skipped rather than read into memory.
    /// A JSON report lists every file, so this allows roughly 150,000 files.
    public static let maxReportBytes = 64 * 1024 * 1024

    enum BoundedReadError: Error { case tooLarge }

    /// Enforce the limit while reading as well as before opening. A file may
    /// grow after its metadata was inspected; never read that growth unbounded.
    static func boundedData(from url: URL, maxBytes: Int = maxReportBytes) throws -> Data {
        guard maxBytes >= 0 else { throw BoundedReadError.tooLarge }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= maxBytes else { throw BoundedReadError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let finished = try autoreleasepool {
                // Read one byte beyond the remaining allowance to detect growth.
                let count = min(1024 * 1024, maxBytes - data.count) + 1
                let chunk = try handle.read(upToCount: count) ?? Data()
                guard chunk.count <= maxBytes - data.count else { throw BoundedReadError.tooLarge }
                data.append(chunk)
                return chunk.isEmpty
            }
            if finished { return data }
        }
    }

    /// A report from the chosen day that was found but not listed, so the
    /// Master Report can say so instead of leaving it only in the log.
    public struct SkippedReport: Equatable, Identifiable, Sendable {
        public enum Reason: Equatable, Sendable {
            case tooLarge
            case unreadable
        }
        public let url: URL
        /// The path under the scanned folder, e.g. `Backup/Reports/BitMatch_Report_….json`.
        /// Exporter filenames repeat across backups, so the folder is part of the name.
        public let displayName: String
        public let reason: Reason
        public var id: URL { url }

        public init(url: URL, displayName: String, reason: Reason) {
            self.url = url
            self.displayName = displayName
            self.reason = reason
        }
    }

    /// A report that was found and decoded.
    public struct FoundReport: Sendable {
        public let url: URL
        public let snapshot: Snapshot

        public init(url: URL, snapshot: Snapshot) {
            self.url = url
            self.snapshot = snapshot
        }
    }

    public struct ScanResult: Sendable {
        public let reports: [FoundReport]
        public let skipped: [SkippedReport]

        public init(reports: [FoundReport], skipped: [SkippedReport]) {
            self.reports = reports
            self.skipped = skipped
        }
    }

    /// Scans `root` recursively for reports last written on the same calendar
    /// day as `day`. Starts security-scoped access around the scan, which iOS
    /// needs for a folder from the document picker and which is harmless
    /// elsewhere. Stops early, returning what it found so far, when the task
    /// is cancelled. `maxBytes` exists for tests.
    public static func scanReports(at root: URL, day: Date = Date(), calendar: Calendar = .current,
                            maxBytes: Int = maxReportBytes) async -> ScanResult {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        SharedLogger.info("Starting report scan at: \(root.path)", category: .transfer)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            SharedLogger.error("Failed to create enumerator for: \(root.path)", category: .transfer)
            return ScanResult(reports: [], skipped: [])
        }

        var reports: [FoundReport] = []
        var skipped: [SkippedReport] = []
        func skip(_ url: URL, _ reason: SkippedReport.Reason) {
            skipped.append(SkippedReport(url: url, displayName: displayName(of: url, under: root), reason: reason))
        }
        var filesChecked = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            filesChecked += 1
            if filesChecked % 500 == 0 { await Task.yield() }

            guard isReportFilename(fileURL.lastPathComponent) else { continue }
            do {
                let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let modified = values.contentModificationDate,
                      calendar.isDate(modified, inSameDayAs: day) else { continue }
                let size = values.fileSize ?? 0
                guard size <= maxBytes else {
                    SharedLogger.warning("Skipping oversized report \(fileURL.path) (\(size) bytes)", category: .transfer)
                    skip(fileURL, .tooLarge)
                    continue
                }
                let data = try boundedData(from: fileURL, maxBytes: maxBytes)
                if let snapshot = snapshot(reportData: data, reportURL: fileURL) {
                    reports.append(FoundReport(url: fileURL, snapshot: snapshot))
                } else if isBitMatchNamed(fileURL.lastPathComponent) {
                    // A file BitMatch named that does not parse is a damaged
                    // report. Other apps' `*_report.json` files are ignored.
                    skip(fileURL, .unreadable)
                }
            } catch BoundedReadError.tooLarge {
                skip(fileURL, .tooLarge)
            } catch is CancellationError {
                break
            } catch {
                SharedLogger.error("Error reading report at \(fileURL.path): \(error)", category: .transfer)
                skip(fileURL, .unreadable)
            }
        }

        SharedLogger.info("Report scan finished: \(filesChecked) files checked, \(reports.count) reports found, \(skipped.count) skipped", category: .transfer)
        return ScanResult(
            reports: reports,
            skipped: skipped.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        )
    }

    /// The path of `url` under `root`, or its filename when it is not under it.
    public static func displayName(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksKeepingCase().path
        let path = url.standardizedFileURL.resolvingSymlinksKeepingCase().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(path.dropFirst(prefix.count))
    }

    // MARK: - Rules

    /// One filename rule for every platform. It covers what the exporter
    /// writes (`BitMatch_Report_<date>.json`, and `-2` etc. when that exists),
    /// plus the older names each platform used to look for.
    public static func isReportFilename(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".json") else { return false }
        return lower == "bitmatchreport.json"
            || lower == "bitmatch_report.json"
            || lower.hasPrefix("bitmatch_report_")
            || lower.hasSuffix("_report.json")
    }

    /// Names only BitMatch writes, as opposed to the generic `*_report.json`
    /// that `isReportFilename` also accepts for older reports.
    public static func isBitMatchNamed(_ name: String) -> Bool {
        name.lowercased().hasPrefix("bitmatch")
    }

    /// Reads an explicit selected mode when present and compatible with the
    /// recorded method/digests. Legacy generic checksum reports use Standard
    /// as the weakest content-check classification; MD5 does not prove a
    /// separate source reread. None of these fields proves completion.
    public static func verificationMode(method: String?, algorithm: String?, scope: VerificationScopeEvidence? = nil) -> VerificationMode? {
        guard let method else { return nil }
        let algorithms: Set<String>
        if let algorithm {
            let names = algorithm.lowercased().split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard !names.isEmpty, names.allSatisfy({ ["sha-256", "sha256", "md5", "xxh64", "xxhash64"].contains($0) }) else { return nil }
            algorithms = Set(names)
        } else {
            algorithms = []
        }
        let hasSHA256 = !algorithms.isDisjoint(with: ["sha-256", "sha256"])
        let mode: VerificationMode
        switch method.lowercased() {
        case "size-only", "quick": mode = .quick
        case "checksum":
            guard algorithm != nil else { return nil }
            mode = .standard
        // Older named modes may omit the algorithm. A supplied digest list
        // must support that mode rather than contradict its recorded plan.
        case "standard":
            guard algorithm == nil || hasSHA256 else { return nil }
            mode = .standard
        case "thorough":
            guard algorithm == nil || (hasSHA256 && algorithms.contains("md5")) else { return nil }
            mode = .thorough
        case "paranoid":
            guard algorithm == nil || hasSHA256 else { return nil }
            mode = .paranoid
        case "checksum-and-byte-compare",
             "byte-compare", "byte-to-byte", "byte_compare":
            mode = .paranoid
        default: return nil
        }
        guard let scope else { return mode }
        guard scope.hasConsistentRecordedCounts else { return nil }
        // A selected plan cannot override incompatible recorded checks. In
        // particular, a malformed Quick scope must never become verified.
        switch scope.selectedMode {
        case .quick:
            guard mode == .quick else { return nil }
        case .standard:
            guard mode == .standard, hasSHA256 else { return nil }
        case .thorough:
            guard [.standard, .thorough].contains(mode), hasSHA256, algorithms.contains("md5") else { return nil }
        case .paranoid:
            guard mode == .paranoid, hasSHA256 else { return nil }
        }
        return scope.selectedMode
    }

    /// The actual selected mode, without inventing a copy plan for a legacy
    /// report that recorded only generic checksum evidence.
    public static func recordedVerificationMode(method: String?, algorithm: String?, scope: VerificationScopeEvidence? = nil) -> VerificationMode? {
        if scope == nil {
            // Generic byte-comparison evidence also does not prove that the
            // Paranoid copy plan (including SHA-256) was selected.
            guard ["size-only", "quick", "standard", "thorough", "paranoid"].contains(method?.lowercased() ?? "") else { return nil }
        }
        return verificationMode(method: method, algorithm: algorithm, scope: scope)
    }

    /// Verified means every file matched, at least one file was checked, and
    /// the report says contents were compared. A Quick (size-only) copy or a
    /// report with no recorded method is never verified (promise 2).
    public static func isVerified(matches: Int, issues: Int, mode: VerificationMode?, totalResults: Int? = nil, safeToErase: Bool? = nil, scope: VerificationScopeEvidence? = nil, sourceFileCount: Int? = nil) -> Bool {
        guard let mode, mode != .quick else { return false }
        guard safeToErase != false else { return false }
        if let totalResults { guard totalResults > 0, matches == totalResults else { return false } }
        if let scope {
            guard scope.hasConsistentRecordedCounts, scope.selectedMode == mode,
                  scope.recordedExcludedSourceFiles == 0,
                  scope.recordedVerifiedResults == matches,
                  scope.recordedSelectedResults == totalResults,
                  scope.recordedSelectedSourceFiles == sourceFileCount else { return false }
        }
        return issues == 0 && matches > 0
    }

    // MARK: - Parsing

    /// The fields the Master Report needs. Decoding only these lets older
    /// reports that lack newer fields still be found. A missing `verification`
    /// block reads as "not verified", not as a failure to parse.
    public struct Snapshot: Decodable, Sendable {
        public let timestamp: Date
        public let source: Source
        public let destinations: [Destination]
        public let statistics: Statistics
        public let performance: Performance
        public let verification: Verification?
        public let safeToErase: Bool?
        public let pdfEvidence: ReportPDFEvidence?

        public struct Source: Decodable, Sendable {
            public let path: String
            public let name: String?
            public let totalSize: Int64
            public let fileCount: Int
            public let cameraDetected: String?

            public init(path: String, name: String?, totalSize: Int64, fileCount: Int, cameraDetected: String?) {
                self.path = path
                self.name = name
                self.totalSize = totalSize
                self.fileCount = fileCount
                self.cameraDetected = cameraDetected
            }
        }

        public struct Destination: Decodable, Sendable {
            public let path: String

            public init(path: String) {
                self.path = path
            }
        }
        public struct Statistics: Decodable, Sendable {
            public let matches: Int
            public let issues: Int
            public let totalFiles: Int?

            public init(matches: Int, issues: Int, totalFiles: Int? = nil) {
                self.matches = matches
                self.issues = issues
                self.totalFiles = totalFiles
            }
        }

        public struct Performance: Decodable, Sendable {
            public let totalDuration: TimeInterval
            public let copyDurationSeconds: TimeInterval?
            public let verifyDurationSeconds: TimeInterval?
            public let overlapDurationSeconds: TimeInterval?
            public let copyBytes: Int64?
            public let verifyBytes: Int64?
            public let mhlDurationSeconds: TimeInterval?
            public let mhlBytes: Int64?
            public let destinationRereadsAvoided: Int?
            public let sourceRereadsAvoided: Int?

            public init(
                totalDuration: TimeInterval,
                copyDurationSeconds: TimeInterval? = nil,
                verifyDurationSeconds: TimeInterval? = nil,
                overlapDurationSeconds: TimeInterval? = nil,
                copyBytes: Int64? = nil,
                verifyBytes: Int64? = nil,
                mhlDurationSeconds: TimeInterval? = nil,
                mhlBytes: Int64? = nil,
                destinationRereadsAvoided: Int? = nil,
                sourceRereadsAvoided: Int? = nil
            ) {
                self.totalDuration = totalDuration
                self.copyDurationSeconds = copyDurationSeconds
                self.verifyDurationSeconds = verifyDurationSeconds
                self.overlapDurationSeconds = overlapDurationSeconds
                self.copyBytes = copyBytes
                self.verifyBytes = verifyBytes
                self.mhlDurationSeconds = mhlDurationSeconds
                self.mhlBytes = mhlBytes
                self.destinationRereadsAvoided = destinationRereadsAvoided
                self.sourceRereadsAvoided = sourceRereadsAvoided
            }
        }
        public struct Verification: Decodable, Sendable {
            public let method: String
            public let algorithm: String?
            public let scope: VerificationScopeEvidence?

            public init(method: String, algorithm: String?, scope: VerificationScopeEvidence? = nil) {
                self.method = method
                self.algorithm = algorithm
                self.scope = scope
            }
        }

        public init(timestamp: Date, source: Source, destinations: [Destination], statistics: Statistics, performance: Performance, verification: Verification?, safeToErase: Bool? = nil, pdfEvidence: ReportPDFEvidence? = nil) {
            self.timestamp = timestamp
            self.source = source
            self.destinations = destinations
            self.statistics = statistics
            self.performance = performance
            self.verification = verification
            self.safeToErase = safeToErase
            self.pdfEvidence = pdfEvidence
        }
    }

    /// Returns nil for JSON that is not a BitMatch report.
    public static func snapshot(reportData: Data, reportURL: URL) -> Snapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let report = try? decoder.decode(Snapshot.self, from: reportData) else {
            SharedLogger.warning("Not a readable BitMatch report: \(reportURL.path)", category: .transfer)
            return nil
        }
        return report
    }
}
