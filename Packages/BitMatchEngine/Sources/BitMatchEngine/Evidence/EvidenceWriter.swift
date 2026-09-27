// EvidenceWriter.swift - Writes a transfer's CSV, JSON and checksum evidence.
import Foundation

// MARK: - Export Outcome

/// Thrown when the requested automatic report cannot be saved. Carried into the
/// completion message, the journal record, and the queue decision so verified
/// media is never confused with a failed requested report.
public enum ReportExportError: LocalizedError, Sendable {
    case noSaveLocation
    case missingChecksum(String)
    public var errorDescription: String? {
        switch self {
        case .noSaveLocation: "Cannot find a valid directory to save reports"
        case .missingChecksum(let path): "No recorded checksum for \(path)."
        }
    }
}

// MARK: - Enhanced JSON Report Structures
/// `Project` is the optional project section (`photographyJob`); the app
/// supplies its own type, and the engine only encodes it.
public struct EnhancedJSONReport<Project: Codable & Sendable>: Codable, Sendable {
    // Version 3.0 adds the optional photographyJob object. When it is nil,
    // every pre-existing report field retains its 2.0 meaning.
    public let reportVersion: String
    public let timestamp: Date
    public let jobId: UUID
    public let mode: String
    public let source: SourceInfo
    public let destinations: [DestinationInfo]
    
    // Enhanced statistics
    public let statistics: Statistics
    public let extensions: [String: Int]  // File extension breakdown
    public let performance: Performance
    public let verification: Verification
    public let results: [JSONReportItem]
    public let photographyJob: Project?
    public var notes: String? = nil
    
    public struct SourceInfo: Codable, Sendable {
        public let path: String
        public let name: String
        public let totalSize: Int64
        public let fileCount: Int
        public let cameraDetected: String?
        public let driveType: String  // "NVMe", "SSD", "HDD", "Network"

        public init(path: String, name: String, totalSize: Int64, fileCount: Int, cameraDetected: String?, driveType: String) {
            self.path = path
            self.name = name
            self.totalSize = totalSize
            self.fileCount = fileCount
            self.cameraDetected = cameraDetected
            self.driveType = driveType
        }
    }
    
    public struct DestinationInfo: Codable, Sendable {
        public let path: String
        public let name: String
        public let availableSpace: Int64
        public let driveType: String
        /// Not measured per backup; nil rather than a guess (Promise 3).
        public let copyDuration: TimeInterval?
        public let verifyDuration: TimeInterval?

        public init(path: String, name: String, availableSpace: Int64, driveType: String, copyDuration: TimeInterval?, verifyDuration: TimeInterval?) {
            self.path = path
            self.name = name
            self.availableSpace = availableSpace
            self.driveType = driveType
            self.copyDuration = copyDuration
            self.verifyDuration = verifyDuration
        }
    }
    
    public struct Statistics: Codable, Sendable {
        public let totalFiles: Int
        public let totalBytes: Int64
        public let matches: Int
        public let issues: Int
        public let successRate: Double
        public let averageFileSize: Int64
        public let largestFile: FileInfo?
        public let smallestFile: FileInfo?

        public init(totalFiles: Int, totalBytes: Int64, matches: Int, issues: Int, successRate: Double, averageFileSize: Int64, largestFile: FileInfo?, smallestFile: FileInfo?) {
            self.totalFiles = totalFiles
            self.totalBytes = totalBytes
            self.matches = matches
            self.issues = issues
            self.successRate = successRate
            self.averageFileSize = averageFileSize
            self.largestFile = largestFile
            self.smallestFile = smallestFile
        }
    }
    
    public struct FileInfo: Codable, Sendable {
        public let path: String
        public let size: Int64

        public init(path: String, size: Int64) {
            self.path = path
            self.size = size
        }
    }
    
    public struct Performance: Codable, Sendable {
        public let totalDuration: TimeInterval
        public let copyDurationSeconds: TimeInterval?
        public let verifyDurationSeconds: TimeInterval?
        public let throughputMBps: Double
        public let peakSpeedMBps: Double?
        public let averageSpeedMBps: Double
        public let filesPerSecond: Double
        public let workers: Int
        public let bottleneck: String?  // "Source Read", "Destination Write", "CPU", "Network"

        public init(totalDuration: TimeInterval, copyDurationSeconds: TimeInterval?, verifyDurationSeconds: TimeInterval?, throughputMBps: Double, peakSpeedMBps: Double?, averageSpeedMBps: Double, filesPerSecond: Double, workers: Int, bottleneck: String?) {
            self.totalDuration = totalDuration
            self.copyDurationSeconds = copyDurationSeconds
            self.verifyDurationSeconds = verifyDurationSeconds
            self.throughputMBps = throughputMBps
            self.peakSpeedMBps = peakSpeedMBps
            self.averageSpeedMBps = averageSpeedMBps
            self.filesPerSecond = filesPerSecond
            self.workers = workers
            self.bottleneck = bottleneck
        }
    }
    
    public struct Verification: Codable, Sendable {
        public let method: String
        public let algorithm: String?
        public let issuesByType: [String: Int]
        public let checksumCache: CacheStats?

        public init(method: String, algorithm: String?, issuesByType: [String: Int], checksumCache: CacheStats?) {
            self.method = method
            self.algorithm = algorithm
            self.issuesByType = issuesByType
            self.checksumCache = checksumCache
        }
    }
    
    public struct CacheStats: Codable, Sendable {
        public let hits: Int
        public let misses: Int
        public let hitRate: Double

        public init(hits: Int, misses: Int, hitRate: Double) {
            self.hits = hits
            self.misses = misses
            self.hitRate = hitRate
        }
    }

    public init(reportVersion: String, timestamp: Date, jobId: UUID, mode: String, source: SourceInfo, destinations: [DestinationInfo], statistics: Statistics, extensions: [String: Int], performance: Performance, verification: Verification, results: [JSONReportItem], photographyJob: Project?, notes: String? = nil) {
        self.reportVersion = reportVersion
        self.timestamp = timestamp
        self.jobId = jobId
        self.mode = mode
        self.source = source
        self.destinations = destinations
        self.statistics = statistics
        self.extensions = extensions
        self.performance = performance
        self.verification = verification
        self.results = results
        self.photographyJob = photographyJob
        self.notes = notes
    }
}

// MARK: - JSON Report Item Structure
public struct JSONReportItem: Codable, Sendable {
    public let path: String
    public let target: String?
    public let status: String
    public let fileExtension: String
    public let checksum: String?
    public let byteCount: Int64?

    public init(from row: ResultRow) {
        self.path = row.path
        self.target = row.destinationPath ?? row.destination
        self.status = row.status.isEmpty ? "Unknown" : row.status
        self.fileExtension = URL(fileURLWithPath: row.path).pathExtension.uppercased()
        self.checksum = row.checksum
        self.byteCount = row.size
    }
}

// MARK: - Evidence kinds and project evidence

/// What produced the evidence: decides the JSON `mode` and where it is saved.
public enum EvidenceKind: Sendable {
    case copyAndVerify
    case compareFolders
    case masterReport

    public var jsonMode: String {
        switch self {
        case .copyAndVerify: "copy-and-verify"
        case .compareFolders: "compare-folders"
        case .masterReport: "master-report"
        }
    }
}

/// Project details the CSV carries, built by the app from its own project
/// model: the same provenance on every row, plus summary rows at the end.
public struct ProjectCSVEvidence: Sendable {
    public let job: String
    public let photographer: String
    public let camera: String
    public let card: String
    public let packagePath: String
    public let summaryRows: [[String]]

    public init(job: String, photographer: String, camera: String, card: String, packagePath: String, summaryRows: [[String]]) {
        self.job = job
        self.photographer = photographer
        self.camera = camera
        self.card = card
        self.packagePath = packagePath
        self.summaryRows = summaryRows
    }
}

// MARK: - Evidence Writer
public enum EvidenceWriter: Sendable {
    
    /// `BitMatch_Report_<finish time>.<ext>`. The PDF, CSV, JSON and checksum
    /// files share this name; `ReportScanner` looks for the JSON one.
    public static func reportFileName(finished: Date, pathExtension: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        let dateString = formatter.string(from: finished).replacingOccurrences(of: ":", with: "-")
        return "BitMatch_Report_\(dateString).\(pathExtension)"
    }

    public static func normalizedNotes(_ notes: String) -> String? {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func verificationDescription(for prefs: ReportPrefs) -> (method: String, label: String, algorithm: String?, primaryAlgorithm: ChecksumAlgorithm?) {
        switch prefs.verificationMode {
        case .quick:
            return ("size-only", "Size check only — contents not checksum verified", nil, nil)
        case .standard:
            return ("checksum", "SHA-256 checksum", "SHA-256", .sha256)
        case .thorough:
            return ("checksum", "SHA-256 and MD5 checksums", "SHA-256, MD5", .sha256)
        case .paranoid:
            return ("checksum-and-byte-compare", "SHA-256 checksum and byte comparison", "SHA-256", .sha256)
        case nil:
            return prefs.verifyWithChecksum
                ? ("checksum", "\(prefs.checksumAlgorithm.rawValue) Checksum", prefs.checksumAlgorithm.rawValue, prefs.checksumAlgorithm)
                : ("byte-compare", "Byte-to-Byte Comparison", nil, nil)
        }
    }

    /// Saves the evidence next to the transfer: `Reports/` in the first
    /// backup for Copy & Verify, otherwise the Desktop (or Documents).
    public static func write<Project: Codable & Sendable>(kind: EvidenceKind,
                                        destinationURLs: [URL],
                                        pdfData: Data?,
                                        results: [ResultRow],
                                        finished: Date,
                                        checksumAlgorithm: ChecksumAlgorithm?,
                                        jobID: UUID,
                                        started: Date,
                                        duration: TimeInterval,
                                        copyDurationSeconds: TimeInterval? = nil,
                                        verifyDurationSeconds: TimeInterval? = nil,
                                        sourceURL: URL?,
                                        fileCount: Int,
                                        matchCount: Int,
                                        totalBytesProcessed: Int64,
                                        workers: Int,
                                        filesPerSecond: Double,
                                        prefs: ReportPrefs,
                                        generateFullReport: Bool,
                                        projectCSV: ProjectCSVEvidence?,
                                        projectJSON: Project?) async throws {
        
        let fileName = reportFileName(finished: finished, pathExtension: "pdf")
        
        // Determine save location - auto-save to Reports folder
        let saveDirectory: URL
        if kind == .copyAndVerify, let firstDestination = destinationURLs.first {
            // Save to Reports folder inside first destination
            saveDirectory = firstDestination.appendingPathComponent("Reports", isDirectory: true)
        } else {
            // Fallback to Desktop/Reports or Documents/Reports
            guard let fallbackDir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                    ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                SharedLogger.error("No valid directory found for saving reports", category: .transfer)
                throw ReportExportError.noSaveLocation
            }
            saveDirectory = fallbackDir.appendingPathComponent("Reports", isDirectory: true)
        }

        // Create reports directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        } catch {
            SharedLogger.error("Failed to create reports directory: \(error.localizedDescription)", category: .transfer)
            throw error
        }
        
        let pdfURL = saveDirectory.appendingPathComponent(fileName).nonConflictingSibling()
        
        do {
            // Save CSV manifest with enhanced data
            let csvURL = pdfURL.deletingPathExtension().appendingPathExtension("csv").nonConflictingSibling()
            try exportEnhancedCSV(results: results,
                                 to: csvURL,
                                 started: started,
                                 duration: duration,
                                 filesPerSecond: filesPerSecond,
                                 copyDurationSeconds: copyDurationSeconds,
                                 verifyDurationSeconds: verifyDurationSeconds,
                                 project: projectCSV,
                                 prefs: prefs)
            
            try Task.checkCancellation()
            // Save enhanced JSON report
            let jsonURL = pdfURL.deletingPathExtension().appendingPathExtension("json").nonConflictingSibling()
            try exportEnhancedJSONReport(
                results: results,
                to: jsonURL,
                jobID: jobID,
                started: started,
                finished: finished,
                kind: kind,
                sourceURL: sourceURL,
                destinationURLs: destinationURLs,
                fileCount: fileCount,
                matchCount: matchCount,
                totalBytesProcessed: totalBytesProcessed,
                duration: duration,
                copyDurationSeconds: copyDurationSeconds,
                verifyDurationSeconds: verifyDurationSeconds,
                workers: workers,
                prefs: prefs,
                project: projectJSON
            )
            
            // If checksums were used, auto-export checksum file (no dialog)
            if generateFullReport, let algorithm = checksumAlgorithm {
                let checksumURL = pdfURL.deletingPathExtension()
                    .appendingPathExtension("\(algorithm.rawValue.lowercased()).txt")
                    .nonConflictingSibling()
                try writeRecordedChecksumManifest(results: results, algorithm: algorithm, to: checksumURL)
            }

            try Task.checkCancellation()
            // The PDF carries the human-facing safety verdict, so it is the
            // commit marker for a complete requested report. Write it only
            // after every later-failing evidence component has succeeded;
            // otherwise an old, safer verdict could survive a report error.
            if generateFullReport, let pdfData {
                try pdfData.write(to: pdfURL, options: .atomic)
            }
            
            SharedLogger.info("Report auto-saved successfully to: \(pdfURL.path)")

            // No need for success dialog since this is auto-save

        } catch {
            SharedLogger.info("Report export error: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Enhanced CSV Export
    private static func exportEnhancedCSV(results: [ResultRow],
                                          to url: URL,
                                          started: Date,
                                          duration: TimeInterval,
                                          filesPerSecond: Double,
                                          copyDurationSeconds: TimeInterval?,
                                          verifyDurationSeconds: TimeInterval?,
                                          project: ProjectCSVEvidence? = nil,
                                          prefs: ReportPrefs? = nil) throws {
        let csvContent = try makeEnhancedCSV(
            results: results,
            started: started,
            duration: duration,
            filesPerSecond: filesPerSecond,
            copyDurationSeconds: copyDurationSeconds,
            verifyDurationSeconds: verifyDurationSeconds,
            project: project,
            prefs: prefs
        )
        try csvContent.data(using: .utf8)?.write(to: url)
    }

    public static func makeEnhancedCSV(
        results: [ResultRow],
        started: Date,
        duration: TimeInterval,
        filesPerSecond: Double,
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        project: ProjectCSVEvidence?,
        prefs: ReportPrefs? = nil
    ) throws -> String {
        var csvContent = csvRow([
            "Status", "File Path", "Target Path", "Job", "Photographer", "Camera", "Card", "Package Path", "Details", "Timestamp", "Bytes", "Checksum"
        ])
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        
        for result in results {
            let status = result.status
            let path = result.path
            let target = result.destinationPath ?? result.destination ?? "—"
            let job = project?.job ?? ""
            let photographer = project?.photographer ?? ""
            let camera = project?.camera ?? ""
            let card = project?.card ?? ""
            let packagePath = project?.packagePath ?? ""
            let verified = isMatchStatus(result.status) && result.checksum?.isEmpty == false && prefs?.verificationMode != .quick
            let details = verified ? "Verified" : result.status
            
            // Per-file times are not measured; the column stays for existing
            // spreadsheets but is empty rather than interpolated (Promise 3).
            // The run's measured start and finish are in the summary.
            let timestamp = ""

            csvContent += csvRow([
                status, path, target, job, photographer, camera, card, packagePath, details, timestamp,
                String(result.size), result.checksum ?? ""
            ])
        }
        
        // Add summary at the end
        csvContent += "\n# Summary\n"
        csvContent += csvRow(["Total Files", String(results.count)])
        csvContent += csvRow(["Started", dateFormatter.string(from: started)])
        csvContent += csvRow(["Finished", dateFormatter.string(from: started.addingTimeInterval(duration))])
        // Verified and copied-but-unverified are counted apart (Promise 2):
        // a Quick copy is not a match.
        csvContent += csvRow(["Verified", String(results.filter { $0.isVerifiedStatus }.count)])
        csvContent += csvRow(["Copied, not verified", String(results.filter { isMatchStatus($0.status) && !$0.isVerifiedStatus }.count)])
        csvContent += csvRow(["Issues", String(results.filter { !isMatchStatus($0.status) }.count)])
        csvContent += csvRow(["Duration", "\(String(format: "%.2f", duration)) seconds"])
        if copyDurationSeconds != nil || verifyDurationSeconds != nil {
            csvContent += csvRow(["Copy Duration", copyDurationSeconds.map { "\(String(format: "%.2f", $0)) seconds" } ?? ""])
            csvContent += csvRow(["Verify Duration", verifyDurationSeconds.map { "\(String(format: "%.2f", $0)) seconds" } ?? ""])
        }
        csvContent += csvRow(["Files/Second", String(format: "%.2f", filesPerSecond)])
        for row in project?.summaryRows ?? [] {
            csvContent += csvRow(row)
        }
        
        if let prefs {
            csvContent += csvRow(["Verification", verificationDescription(for: prefs).label])
            if let notes = normalizedNotes(prefs.notes) {
                csvContent += csvRow(["Notes", notes])
            }
        }
        return csvContent
    }
    
    // MARK: - Enhanced JSON Report Export (FIXED)
    private static func exportEnhancedJSONReport<Project: Codable & Sendable>(results: [ResultRow],
                                                 to url: URL,
                                                 jobID: UUID,
                                                 started: Date,
                                                 finished: Date,
                                                 kind: EvidenceKind,
                                                 sourceURL: URL?,
                                                 destinationURLs: [URL],
                                                 fileCount: Int,
                                                 matchCount: Int,
                                                 totalBytesProcessed: Int64,
                                                 duration: TimeInterval,
                                                 copyDurationSeconds: TimeInterval?,
                                                 verifyDurationSeconds: TimeInterval?,
                                                 workers: Int,
                                                 prefs: ReportPrefs,
                                                 project: Project?) throws {
        let report = try makeEnhancedJSONReport(
            results: results,
            jobID: jobID,
            started: started,
            finished: finished,
            kind: kind,
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            fileCount: fileCount,
            matchCount: matchCount,
            totalBytesProcessed: totalBytesProcessed,
            duration: duration,
            copyDurationSeconds: copyDurationSeconds,
            verifyDurationSeconds: verifyDurationSeconds,
            workers: workers,
            prefs: prefs,
            project: project
        )
        try encodeEnhancedJSONReport(report).write(to: url)
    }

    /// The bytes written for a JSON report. `ReportScanner` reads these back.
    public static func encodeEnhancedJSONReport<Project>(_ report: EnhancedJSONReport<Project>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    public static func makeEnhancedJSONReport<Project: Codable & Sendable>(
        results: [ResultRow],
        jobID: UUID,
        started: Date,
        finished: Date,
        kind: EvidenceKind,
        sourceURL: URL?,
        destinationURLs: [URL],
        fileCount: Int,
        matchCount: Int,
        totalBytesProcessed: Int64,
        duration: TimeInterval,
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        workers: Int,
        prefs: ReportPrefs,
        project: Project?
    ) throws -> EnhancedJSONReport<Project> {
        // Calculate file extensions breakdown
        var extensions: [String: Int] = [:]
        var largestFile: EnhancedJSONReport<Project>.FileInfo?
        var smallestFile: EnhancedJSONReport<Project>.FileInfo?
        var maxSize: Int64 = 0
        var minSize: Int64 = Int64.max
        
        for result in results {
            let url = URL(fileURLWithPath: result.path)
            let ext = url.pathExtension.uppercased()
            if !ext.isEmpty {
                extensions[ext, default: 0] += 1
            }
            
            // Track largest and smallest files
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                let fileSize = Int64(size)
                if fileSize > maxSize {
                    maxSize = fileSize
                    largestFile = EnhancedJSONReport<Project>.FileInfo(path: result.path, size: fileSize)
                }
                if fileSize < minSize {
                    minSize = fileSize
                    smallestFile = EnhancedJSONReport<Project>.FileInfo(path: result.path, size: fileSize)
                }
            }
        }
        
        // Calculate issues by type
        var issuesByType: [String: Int] = [:]
        for result in results.filter({ !isMatchStatus($0.status) }) {
            let key = normalizedStatus(result.status)
            issuesByType[key, default: 0] += 1
        }
        
        // Calculate performance metrics
        let throughputMBps = duration > 0 ? Double(totalBytesProcessed) / duration / 1_048_576 : 0
        let averageFileSize = fileCount > 0 ? totalBytesProcessed / Int64(fileCount) : 0
        let filesPerSecond = duration > 0 ? Double(fileCount) / duration : 0
        
        // Detect drive type for source
        let sourceDriveType: String = {
            if let source = sourceURL {
                do {
                    let resourceValues = try source.resourceValues(forKeys: [.volumeIsLocalKey, .volumeSupportsFileCloningKey])
                    if !(resourceValues.volumeIsLocal ?? true) {
                        return "Network"
                    } else if resourceValues.volumeSupportsFileCloning ?? false {
                        return "SSD"
                    } else {
                        return "HDD"
                    }
                } catch {
                    return "Unknown"
                }
            }
            return "Unknown"
        }()
        
        // Create source info
        let sourceInfo = EnhancedJSONReport<Project>.SourceInfo(
            path: sourceURL?.path ?? "—",
            name: sourceURL?.lastPathComponent ?? "—",
            totalSize: totalBytesProcessed,
            fileCount: fileCount,
            cameraDetected: nil, // Could be detected if needed
            driveType: sourceDriveType
        )
        
        // Create destination info array
        let destinationInfos: [EnhancedJSONReport<Project>.DestinationInfo] = destinationURLs.map { destURL in
            // Detect drive type for each destination
            let destDriveType: String = {
                do {
                    let resourceValues = try destURL.resourceValues(forKeys: [.volumeIsLocalKey, .volumeSupportsFileCloningKey, .volumeAvailableCapacityKey])
                    if !(resourceValues.volumeIsLocal ?? true) {
                        return "Network"
                    } else if resourceValues.volumeSupportsFileCloning ?? false {
                        return "SSD"
                    } else {
                        return "HDD"
                    }
                } catch {
                    return "Unknown"
                }
            }()
            
            // Get available space
            let availableSpace: Int64 = {
                do {
                    let resourceValues = try destURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                    return Int64(resourceValues.volumeAvailableCapacity ?? 0)
                } catch {
                    return 0
                }
            }()
            
            return EnhancedJSONReport<Project>.DestinationInfo(
                path: destURL.path,
                name: destURL.lastPathComponent,
                availableSpace: availableSpace,
                driveType: destDriveType,
                copyDuration: nil,
                verifyDuration: nil
            )
        }
        
        // Create the enhanced report
        return EnhancedJSONReport<Project>(
            reportVersion: "3.0",
            timestamp: finished,
            jobId: jobID,
            mode: kind.jsonMode,
            source: sourceInfo,
            destinations: destinationInfos,
            statistics: EnhancedJSONReport<Project>.Statistics(
                totalFiles: fileCount,
                totalBytes: totalBytesProcessed,
                matches: matchCount,
                // Failed rows only: a copied-but-unverified file is neither a
                // match nor an issue.
                issues: results.filter { !isMatchStatus($0.status) }.count,
                successRate: fileCount > 0 ? Double(matchCount) / Double(fileCount) * 100 : 100,
                averageFileSize: averageFileSize,
                largestFile: largestFile,
                smallestFile: smallestFile
            ),
            extensions: extensions,
            performance: EnhancedJSONReport<Project>.Performance(
                totalDuration: duration,
                copyDurationSeconds: copyDurationSeconds,
                verifyDurationSeconds: verifyDurationSeconds,
                throughputMBps: throughputMBps,
                peakSpeedMBps: nil,
                averageSpeedMBps: throughputMBps,
                filesPerSecond: filesPerSecond,
                workers: workers,
                bottleneck: nil // Could be determined by analyzing speeds
            ),
            verification: EnhancedJSONReport<Project>.Verification(
                method: verificationDescription(for: prefs).method,
                algorithm: verificationDescription(for: prefs).algorithm,
                issuesByType: issuesByType,
                checksumCache: nil // Would need to track cache stats during operation
            ),
            results: results.map { JSONReportItem(from: $0) },
            photographyJob: project,
            notes: normalizedNotes(prefs.notes)
        )
    }
    
    /// Automatic reports use the checksums retained by verification. Re-reading
    /// files later would replace the evidence and outlive the transfer's access lease.
    public static func writeRecordedChecksumManifest(results: [ResultRow], algorithm: ChecksumAlgorithm, to url: URL) throws {
        var content = "# BitMatch Checksum Manifest\n# Algorithm: \(algorithm.rawValue)\n# Format: CHECKSUM  FILENAME\n\n"
        for row in results where row.isSuccessStatus {
            try Task.checkCancellation()
            guard let checksum = row.checksum, !checksum.isEmpty else {
                throw ReportExportError.missingChecksum(row.path)
            }
            let path = row.destinationPath ?? row.path
            // GNU checksum escaping preserves filenames containing backslashes or newlines.
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\n", with: "\\n")
            content += (escaped == path ? "" : "\\") + checksum + "  " + escaped + "\n"
        }
        try Task.checkCancellation()
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func csvRow(_ values: [String]) -> String {
        values.map(escapeCSV).joined(separator: ",") + "\n"
    }

    private static func escapeCSV(_ string: String) -> String {
        let neutralized = neutralizeCSVFormula(string)
        let needsQuotes = neutralized.contains(",")
            || neutralized.contains("\"")
            || neutralized.contains("\n")
            || neutralized.contains("\r")
        if needsQuotes {
            let escaped = neutralized.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return neutralized
    }

    private static func neutralizeCSVFormula(_ string: String) -> String {
        guard let firstContentScalar = string.unicodeScalars.first(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }), ["=", "+", "-", "@"].contains(String(firstContentScalar)) else {
            return string
        }
        return "'\(string)"
    }
    
    private static func isMatchStatus(_ status: String) -> Bool {
        ResultRow.isSuccessStatus(status)
    }
    
    private static func normalizedStatus(_ status: String) -> String {
        status.isEmpty ? "Unknown" : status
    }
}
