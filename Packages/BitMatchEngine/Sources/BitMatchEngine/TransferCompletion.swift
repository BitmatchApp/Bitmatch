// TransferCompletion.swift - What a finished copy run means.
import Foundation
import Synchronization

/// The engine's decisions once the pipeline returns: one result row per file
/// per backup, which backups get an ASC MHL history, and the verdict. The
/// app's `CopyVerifyExecutor` runs these and owns progress, timing and the
/// project lifecycle.
public enum TransferCompletion: Sendable {
    // MARK: - Rows

    public static func row(from result: FileOperationResult, destinationRoots: [URL]) -> ResultRow {
        ResultRow(
            path: result.sourceURL.path,
            status: result.statusDescription,
            size: result.fileSize,
            checksum: result.verificationResult?.sourceChecksum,
            destination: destinationLabel(for: result.destinationURL, roots: destinationRoots),
            destinationPath: result.destinationURL.path,
            clipIntegrity: result.clipIntegrity,
            wasReused: result.wasReused
        )
    }

    public static func rows(from operation: FileOperation) -> [ResultRow] {
        operation.results.map { row(from: $0, destinationRoots: operation.destinationURLs) }
    }

    /// The backup a written file belongs to, as reports name it: the drive
    /// under /Volumes, otherwise the chosen backup folder. `/var` and
    /// `/private/var` spellings agree (see `ResultPathMatch`).
    public static func destinationLabel(for file: URL, roots: [URL]) -> String {
        let filePath = ResultPathMatch.comparablePath(file.path)
        let root = roots
            .map { URL(fileURLWithPath: ResultPathMatch.comparablePath($0.path)) }
            .filter { filePath == $0.path || filePath.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
        let comps = (root ?? file).pathComponents
        if let volIndex = comps.firstIndex(of: "Volumes"), volIndex + 1 < comps.count {
            return comps[volIndex + 1]
        }
        return root?.lastPathComponent ?? file.deletingLastPathComponent().lastPathComponent
    }

    // MARK: - ASC MHL

    private struct CoverageEntry: Sendable {
        let source: URL
        let destination: URL?
    }

    private struct DestinationCoverage: Sendable {
        let destination: URL
        let root: URL
        let entryIndices: [Int]
        let missingCount: Int
        let duplicateCount: Int
        let unexpectedCount: Int

        var isExact: Bool {
            missingCount == 0 && duplicateCount == 0 && unexpectedCount == 0
        }
    }

    private struct CoverageAnalysis: Sendable {
        let destinations: [DestinationCoverage]
        let issues: [String]

        var isExact: Bool {
            !destinations.isEmpty && destinations.allSatisfy(\.isExact) && issues.isEmpty
        }
    }

    private static func coverageAnalysis(
        entries: [CoverageEntry],
        sourceFiles: [URL]?,
        destinations: [URL],
        source: URL,
        settings: CameraLabelSettings
    ) -> CoverageAnalysis {
        var destinationCoverage: [DestinationCoverage] = []
        var issues: [String] = []
        var assignedIndices = Set<Int>()
        // Resolving touches the file system and a card can hold 100k files,
        // so each folder is resolved once and each path once.
        var folders = CanonicalFolders()
        let expectedPaths = Set((sourceFiles ?? []).map { folders.canonicalPath($0) })
        let canonicalSources = entries.map { folders.canonicalPath($0.source) }
        let canonicalDestinations = entries.map { $0.destination.map { folders.canonicalPath($0) } }
        // A file's place on a backup is the backup root plus its own path
        // inside the card, so each result is checked against exactly that.
        let sourcePath = canonicalPath(source)
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        func relativeToSource(_ path: String) -> String? {
            path.hasPrefix(sourcePrefix) ? String(path.dropFirst(sourcePrefix.count)) : nil
        }
        let expectedRelativePaths = Set(expectedPaths.compactMap(relativeToSource))
        var rootsByIndex: [Int: Int] = [:]

        for destination in destinations {
            let root: URL
            do {
                root = try SafetyValidator.resolvedDestinationRootChecked(
                    source: source, destination: destination, settings: settings
                )
            } catch {
                issues.append("\(destination.lastPathComponent): result coverage could not be checked — \(error.localizedDescription)")
                continue
            }
            // Both sides are already comparable strings, so a prefix test on
            // whole components ("/Volumes/T7/" never matches "/Volumes/T70")
            // replaces isAncestor, which would resolve them again.
            let rootPath = canonicalPath(root)
            let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            let indices = entries.indices.filter {
                guard let destination = canonicalDestinations[$0] else { return false }
                return destination.hasPrefix(rootPrefix)
            }
            assignedIndices.formUnion(indices)
            for index in indices { rootsByIndex[index, default: 0] += 1 }
            // A row counts for this backup only when its source is in the
            // manifest and its copy sits at the matching path under the root.
            var matchedCounts: [String: Int] = [:]
            var unexpectedCount = 0
            for index in indices {
                guard let destinationPath = canonicalDestinations[index],
                      expectedPaths.contains(canonicalSources[index]),
                      let relativeSource = relativeToSource(canonicalSources[index]),
                      String(destinationPath.dropFirst(rootPrefix.count)) == relativeSource else {
                    unexpectedCount += 1
                    continue
                }
                matchedCounts[relativeSource, default: 0] += 1
            }
            let missingCount = expectedRelativePaths.subtracting(matchedCounts.keys).count
                + (expectedPaths.count - expectedRelativePaths.count)
            let duplicateCount = matchedCounts.values.reduce(0) { $0 + max(0, $1 - 1) }
            destinationCoverage.append(DestinationCoverage(
                destination: destination,
                root: root,
                entryIndices: indices,
                missingCount: missingCount,
                duplicateCount: duplicateCount,
                unexpectedCount: unexpectedCount
            ))
        }

        if sourceFiles == nil {
            issues.append("The source manifest is unavailable")
        }
        // Backups are never nested (setup refuses it); if two roots still
        // claim the same result, the coverage cannot be trusted.
        if rootsByIndex.values.contains(where: { $0 > 1 }) {
            issues.append("Some results belong to more than one selected destination")
        }
        let unassignedCount = entries.indices.filter { !assignedIndices.contains($0) }.count
        if unassignedCount > 0 {
            issues.append(unassignedCount == 1
                ? "1 result does not belong to a selected destination"
                : "\(unassignedCount) results do not belong to a selected destination")
        }
        return CoverageAnalysis(destinations: destinationCoverage, issues: issues)
    }

    private static func canonicalPath(_ url: URL) -> String {
        ResultPathMatch.comparablePath(url.standardizedFileURL.resolvingSymlinksKeepingCase().path)
    }

    /// Resolves each folder once. Only the folder can hold a symlink here:
    /// the card manifest refuses symlinked files and copies are written as
    /// regular files, so the file name is appended as is.
    private struct CanonicalFolders {
        private var resolved: [String: String] = [:]

        /// The folder's comparable form is cached too: making a path
        /// comparable standardizes it, which checks the disk.
        mutating func canonicalPath(_ url: URL) -> String {
            let folder = url.deletingLastPathComponent().path
            let comparableFolder: String
            if let cached = resolved[folder] {
                comparableFolder = cached
            } else {
                comparableFolder = ResultPathMatch.comparablePath(
                    URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksKeepingCase().path
                )
                resolved[folder] = comparableFolder
            }
            let name = url.lastPathComponent
            return comparableFolder.hasSuffix("/") ? comparableFolder + name : comparableFolder + "/" + name
        }
    }

    private static func coverageIssues(_ coverage: CoverageAnalysis) -> [String] {
        var issues = coverage.issues
        for item in coverage.destinations {
            let name = destinationLabel(for: item.destination, roots: [item.destination])
            if item.missingCount > 0 {
                issues.append(item.missingCount == 1
                    ? "\(name): 1 file has no result"
                    : "\(name): \(item.missingCount) files have no result")
            }
            if item.duplicateCount > 0 {
                issues.append(item.duplicateCount == 1
                    ? "\(name): 1 file has duplicate results"
                    : "\(name): \(item.duplicateCount) files have duplicate results")
            }
            if item.unexpectedCount > 0 {
                issues.append(item.unexpectedCount == 1
                    ? "\(name): 1 result is not in the source manifest"
                    : "\(name): \(item.unexpectedCount) results are not in the source manifest")
            }
        }
        return issues
    }

    public struct ASCMHLJob: Sendable {
        public let root: URL
        public let files: [ASCMHLGenerator.VerifiedFile]

        public init(root: URL, files: [ASCMHLGenerator.VerifiedFile]) {
            self.root = root
            self.files = files
        }
    }

    /// A history is written only for a backup whose every file verified
    /// with SHA-256; each other backup gets an issue saying why not.
    public static func ascmhlPlan(
        results: [FileOperationResult],
        sourceFiles: [URL]?,
        destinations: [URL],
        source: URL,
        settings: CameraLabelSettings
    ) -> (jobs: [ASCMHLJob], issues: [String]) {
        let entries = results.map { CoverageEntry(source: $0.sourceURL, destination: $0.destinationURL) }
        let coverage = coverageAnalysis(
            entries: entries, sourceFiles: sourceFiles, destinations: destinations,
            source: source, settings: settings
        )
        var jobs: [ASCMHLJob] = []
        var issues = coverage.issues.map { "ASC MHL not created — \($0)" }
        for item in coverage.destinations {
            let rows = item.entryIndices.map { results[$0] }
            guard sourceFiles != nil, item.isExact,
                  rows.allSatisfy({ $0.success && $0.verificationResult?.isValid == true && $0.verificationResult?.checksumType == .sha256 }) else {
                issues.append("\(item.destination.lastPathComponent): ASC MHL not created because verification is incomplete")
                continue
            }
            let canonicalRoot = item.root.standardizedFileURL.resolvingSymlinksKeepingCase()
            jobs.append(ASCMHLJob(root: item.root, files: rows.map {
                let verification = $0.verificationResult
                return ASCMHLGenerator.VerifiedFile(
                    relativePath: $0.destinationURL.standardizedFileURL.resolvingSymlinksKeepingCase().relativePath(to: canonicalRoot),
                    size: $0.fileSize,
                    expectedSHA256: verification?.sourceDigests?.sha256
                        ?? verification?.sourceChecksum
                        ?? "",
                    verifiedSHA256: verification?.destinationDigests?.sha256,
                    verifiedMD5: verification?.destinationDigests?.md5,
                    destinationReadIdentity: verification?.destinationReadIdentity
                )
            }))
        }
        return (jobs, issues)
    }

    /// Writes each planned history and returns every issue: the plan's and
    /// any write failures. Blocking file I/O; run it off the main actor.
    public static func writeASCMHL(
        _ jobs: [ASCMHLJob],
        planIssues: [String],
        startTime: Date,
        source: URL,
        toolVersion: String, progress: ASCMHLGenerator.ProgressHandler? = nil, diagnosticRun: UUID? = nil
    ) throws -> [String] {
        var failures = planIssues
        let totalBytes = jobs.flatMap(\.files).reduce(Int64(0)) { $0 + max(0, $1.size) }
        let totalFiles = jobs.reduce(0) { $0 + $1.files.count }
        var precedingBytes: Int64 = 0
        var precedingFiles = 0
        for job in jobs {
            let byteOffset = precedingBytes
            let fileOffset = precedingFiles
            let precedingJobsSucceeded = failures.isEmpty
            let observed = Mutex<(bytes: Int64, files: Int)>((0, 0))
            try Task.checkCancellation()
            do {
                _ = try ASCMHLGenerator.generateInitialHistory(
                    destinationURL: job.root, files: job.files, startTime: startTime,
                    sourceURL: source, toolVersion: toolVersion,
                    progress: { update in
                        observed.withLock { $0 = (update.bytesProcessed, update.filesProcessed) }
                        progress?(ASCMHLGenerator.Progress(
                            bytesProcessed: byteOffset + update.bytesProcessed, totalBytes: totalBytes,
                            filesProcessed: fileOffset + update.filesProcessed, totalFiles: totalFiles,
                            published: precedingJobsSucceeded && update.published && fileOffset + update.filesProcessed == totalFiles))
                    }, diagnosticRun: diagnosticRun
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                SharedLogger.transferError(error, run: diagnosticRun)
                failures.append("\(job.root.lastPathComponent): ASC MHL — \(error.localizedDescription)")
            }
            let last = observed.withLock { $0 }
            precedingBytes += last.bytes
            precedingFiles += last.files
        }
        return failures
    }

    // MARK: - Verdict

    /// What a project (photographer job) contributed to the outcome.
    public struct ProjectGate: Sendable {
        /// The project's records were saved.
        public let didPersist: Bool
        /// `nil` when no project finalizer ran (an ordinary copy).
        public let locallySafe: Bool?

        public init(didPersist: Bool, locallySafe: Bool?) {
            self.didPersist = didPersist
            self.locallySafe = locallySafe
        }

        public var permitsSuccess: Bool { didPersist && (locallySafe ?? true) }
    }

    /// What every Quick-mode message says, wherever it appears (verdict text
    /// or the journal's own safety net in `TransferJournal.finish`). One
    /// spelling, so the two never say it twice or say it differently.
    public static let quickModeNote = "Not verified: Quick mode only compares file sizes."

    public struct Verdict: Equatable, Sendable {
        public let success: Bool
        public let message: String
        /// Everything that success needs held except a checksum: Quick mode
        /// copied every file and nothing else went wrong. Never a success;
        /// it lets the app say "copied, not verified" instead of "needs
        /// attention" without hiding a report, handoff or project failure.
        public let copiedNotVerified: Bool

        public init(success: Bool, message: String, copiedNotVerified: Bool = false) {
            self.success = success
            self.message = message
            self.copiedNotVerified = copiedNotVerified
        }
    }

    /// Success needs every file on every backup to succeed, a checksum mode
    /// (never Quick), every requested ASC MHL written, the requested report
    /// saved, and the project (if any) saved and locally safe (Promise 2).
    public static func verdict(
        rows: [ResultRow],
        sourceFiles: [URL]?,
        destinations: [URL],
        source: URL,
        settings: CameraLabelSettings,
        mode: VerificationMode,
        generateASCMHL: Bool,
        handoffIssues: [String],
        reportIssue: String?,
        project: ProjectGate
    ) -> Verdict {
        // Safe-to-erase modes count only independently verified readback rows.
        // Quick has no safe verdict; its copied rows remain eligible only for
        // the separate amber "copied, not verified" outcome.
        let coverageRows = mode == .quick
            ? rows.filter(\.isSuccessStatus)
            : rows.filter(\.isVerifiedStatus)
        let coverage = coverageAnalysis(
            entries: coverageRows.map {
                CoverageEntry(
                    source: URL(fileURLWithPath: $0.path),
                    destination: $0.destinationPath.map { URL(fileURLWithPath: $0) }
                )
            },
            sourceFiles: sourceFiles,
            destinations: destinations,
            source: source,
            settings: settings
        )
        let incompleteCoverageIssues = coverageIssues(coverage)
        let issueCount = rows.filter { !$0.isSuccessStatus }.count
        let fileResultsSucceeded = !rows.isEmpty && issueCount == 0
        // Outside Quick, a row that was copied but not verified keeps the
        // run from success here too, not only in the app's own verdict: the
        // Dock tile and the finish notification read this success.
        let everyRowVerified = rows.allSatisfy(\.isVerifiedStatus)
        let allFilesReused = mode != .quick
            && !rows.isEmpty
            && everyRowVerified
            && rows.allSatisfy(\.wasReused)
        let fileResultsMessage: String
        if rows.isEmpty {
            fileResultsMessage = "No files were copied"
        } else if fileResultsSucceeded {
            if allFilesReused {
                fileResultsMessage = "All files already existed and were verified; nothing new copied"
            } else {
                fileResultsMessage = mode == .quick || !everyRowVerified ? "All files copied" : "All files copied and verified"
            }
        } else {
            fileResultsMessage = issueCount == 1 ? "1 file failed" : "\(issueCount) files failed"
        }

        let everythingElseHeld = fileResultsSucceeded && coverage.isExact && project.permitsSuccess && handoffIssues.isEmpty && reportIssue == nil
        let succeeded = everythingElseHeld && mode != .quick && everyRowVerified
        var completionMessage = fileResultsMessage
        if !incompleteCoverageIssues.isEmpty {
            completionMessage += "; " + incompleteCoverageIssues.joined(separator: "; ")
        }
        if !project.didPersist {
            completionMessage += "; the project record was not saved"
        } else if project.locallySafe == false {
            completionMessage += "; the card is not yet verified on all the project's destinations"
        }
        if !handoffIssues.isEmpty {
            completionMessage += "; " + handoffIssues.joined(separator: "; ")
        } else if generateASCMHL && mode != .quick {
            completionMessage += "; ASC MHL handoff records saved"
        }
        if mode == .quick {
            completionMessage += ". \(quickModeNote)"
        }
        if let reportIssue {
            completionMessage += "; the report could not be saved: \(reportIssue)"
        }
        return Verdict(success: succeeded, message: completionMessage,
                       copiedNotVerified: everythingElseHeld && mode == .quick)
    }
}
