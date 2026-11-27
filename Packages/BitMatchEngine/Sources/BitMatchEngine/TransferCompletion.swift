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
            checksum: result.skippedFinderMetadata ? nil : result.verificationResult?.sourceChecksum,
            destination: destinationLabel(for: result.destinationURL, roots: destinationRoots),
            destinationPath: result.destinationURL.path,
            clipIntegrity: result.clipIntegrity,
            wasReused: result.wasReused,
            failedOutputMarking: result.failedOutputMarking,
            recopyOutcome: result.recopyOutcome,
            failureReason: result.failureReason,
            recordedChecksumBeforeFailure: result.success ? nil : result.recordedChecksumBeforeFailure
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

    /// One label per destination, each distinct within the list. A backup
    /// whose `destinationLabel` (its volume) no other shares keeps it; a
    /// group that shares one adds its trailing path components, one at a
    /// time, until no two read alike: "RAID/ProjectA/Backup", "RAID/ProjectB/Backup".
    static func distinctDestinationLabels(for destinations: [URL]) -> [String] {
        let bases = destinations.map { destinationLabel(for: $0, roots: [$0]) }
        var labels = bases
        for base in Set(bases) {
            let group = bases.indices.filter { bases[$0] == base }
            guard group.count > 1 else { continue }
            // The components after the base: below the volume for /Volumes
            // paths, otherwise the folders above the named last component.
            let tails: [[String]] = group.map { index in
                let comps = destinations[index].standardizedFileURL.pathComponents
                if let volume = comps.firstIndex(of: "Volumes"), volume + 1 < comps.count, comps[volume + 1] == base {
                    return Array(comps.dropFirst(volume + 2))
                }
                return Array(comps.dropFirst().dropLast())
            }
            let isVolume = group.map { index -> Bool in
                let comps = destinations[index].standardizedFileURL.pathComponents
                return comps.firstIndex(of: "Volumes").map { $0 + 1 < comps.count && comps[$0 + 1] == base } ?? false
            }
            let longest = tails.map(\.count).max() ?? 0
            for depth in 1...max(1, longest) {
                let candidates = group.indices.map { position -> String in
                    let part = tails[position].suffix(depth)
                    guard !part.isEmpty else { return base }
                    return isVolume[position]
                        ? ([base] + part).joined(separator: "/")
                        : (part + [base]).joined(separator: "/")
                }
                for (position, index) in group.enumerated() { labels[index] = candidates[position] }
                if Set(candidates).count == candidates.count { break }
            }
        }
        return labels
    }

    // MARK: - Finder view files

    /// The one rule for skipped Finder view files (`.DS_Store`): every site
    /// that lets a skip stand in for a copy asks this. True only when every
    /// skipped row's path is in the engine-proven set (relative to `source`),
    /// each proven path has exactly one skipped row on every destination, at
    /// its own place under that backup's root, and no skipped row falls
    /// outside the set. Status text alone never counts: a skipped row with no
    /// proof, a missing or duplicate row, or a proven path whose rows the
    /// final gate turned into failures all answer false. Every proven path
    /// must also be in `sourceFiles`, the card's complete manifest; a caller
    /// with no manifest (nil) cannot prove any skip. With no proven set and
    /// no skipped row there is nothing to prove, so true.
    public static func finderMetadataSkipsProven(
        rows: [ResultRow], provenPaths: [String]?, sourceFiles: [URL]?,
        destinations: [URL], source: URL, settings: CameraLabelSettings
    ) -> Bool {
        let skipped = rows.filter(\.isSkippedFinderMetadata)
        guard let provenPaths, !provenPaths.isEmpty else { return skipped.isEmpty }
        guard !destinations.isEmpty, let sourceFiles else { return false }
        let manifest = Set(sourceFiles.map { PathContainment.comparablePath($0.path) })
        let sourcePath = PathContainment.comparablePath(source.path)
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        var proven = Set<String>()
        for relative in provenPaths {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.hasPrefix("/"), !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  parts.last.map({ $0.utf8.elementsEqual(".DS_Store".utf8) }) == true else { return false }
            let path = PathContainment.comparablePath(source.appendingPathComponent(relative).path)
            guard path.hasPrefix(sourcePrefix), manifest.contains(path),
                  proven.insert(path).inserted else { return false }
        }
        let roots = destinations.map {
            PathContainment.comparablePath(SafetyValidator.resolvedDestinationRoot(
                source: source, destination: $0, settings: settings
            ).path)
        }
        guard Set(roots).count == roots.count else { return false }
        for first in roots.indices {
            for second in roots.indices where second > first {
                guard !PathContainment.isWithin(roots[first], root: roots[second]),
                      !PathContainment.isWithin(roots[second], root: roots[first]) else { return false }
            }
        }
        var skippedByDestination = Array(repeating: Set<String>(), count: roots.count)
        for row in skipped {
            let path = PathContainment.comparablePath(row.path)
            guard proven.contains(path), path.hasPrefix(sourcePrefix),
                  let destinationPath = row.destinationPath else { return false }
            let relative = String(path.dropFirst(sourcePrefix.count))
            let destination = PathContainment.comparablePath(destinationPath)
            let matching = roots.indices.filter { destination == roots[$0] + "/" + relative }
            guard matching.count == 1, let index = matching.first,
                  skippedByDestination[index].insert(path).inserted else { return false }
        }
        return skippedByDestination.allSatisfy { $0 == proven }
    }

    /// "1 Finder view file (.DS_Store) skipped", "2 Finder view files (.DS_Store) skipped".
    private static func finderMetadataSkipDescription(_ count: Int) -> String {
        "\(count) Finder view \(count == 1 ? "file" : "files") (.DS_Store) skipped"
    }

    // MARK: - ASC MHL

    private struct CoverageEntry: Sendable {
        let source: URL
        let destination: URL?
        var failureReason: String? = nil
    }

    private struct DestinationCoverage: Sendable {
        let destination: URL
        let root: URL
        let entryIndices: [Int]
        /// Expected files with no counted row, including `notVerifiedCount`.
        let missingCount: Int
        /// Of `missingCount`, files that do have a row on this backup, one
        /// that did not verify (or, in Quick, did not copy).
        var notVerifiedCount = 0
        /// The one reason every such row gives, when they all give the same.
        var notVerifiedReason: ResultFailureReason? = nil
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
        settings: CameraLabelSettings,
        notVerifiedEntries: [CoverageEntry] = []
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
        let notVerifiedSources = notVerifiedEntries.map { folders.canonicalPath($0.source) }
        let notVerifiedDestinations = notVerifiedEntries.map { $0.destination.map { folders.canonicalPath($0) } }
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
            let missingPaths = expectedRelativePaths.subtracting(matchedCounts.keys)
            let missingCount = missingPaths.count
                + (expectedPaths.count - expectedRelativePaths.count)
            let duplicateCount = matchedCounts.values.reduce(0) { $0 + max(0, $1 - 1) }
            // A missing file that has a row here, one that did not count, is
            // "not verified"; only a file with no row at all "has no result".
            var notVerifiedReasons: [String: [String?]] = [:]
            if !missingPaths.isEmpty {
                for index in notVerifiedEntries.indices {
                    guard let destinationPath = notVerifiedDestinations[index],
                          destinationPath.hasPrefix(rootPrefix),
                          let relativeSource = relativeToSource(notVerifiedSources[index]),
                          missingPaths.contains(relativeSource),
                          String(destinationPath.dropFirst(rootPrefix.count)) == relativeSource else { continue }
                    notVerifiedReasons[relativeSource, default: []].append(notVerifiedEntries[index].failureReason)
                }
            }
            var item = DestinationCoverage(
                destination: destination,
                root: root,
                entryIndices: indices,
                missingCount: missingCount,
                duplicateCount: duplicateCount,
                unexpectedCount: unexpectedCount
            )
            item.notVerifiedCount = notVerifiedReasons.count
            let reasons = notVerifiedReasons.values.flatMap { $0 }
            if let first = reasons.first ?? nil, reasons.allSatisfy({ $0 == first }) {
                item.notVerifiedReason = ResultFailureReason(rawValue: first)
            }
            destinationCoverage.append(item)
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

    /// `explainReasons` adds a backup's one shared reason in parentheses;
    /// the caller turns it off when its headline already says that reason.
    /// `skippedFinderMetadataCount` adds one line for proven skips, which are
    /// not issues; the caller passes it only when its headline does not
    /// already name them.
    private static func coverageIssues(_ coverage: CoverageAnalysis, notVerifiedWord: String = "not verified",
                                       explainReasons: Bool = true, skippedFinderMetadataCount: Int = 0) -> [String] {
        var issues = coverage.issues
        for item in coverage.destinations {
            let name = destinationLabel(for: item.destination, roots: [item.destination])
            if item.notVerifiedCount > 0 {
                var line = item.notVerifiedCount == 1
                    ? "\(name): 1 file \(notVerifiedWord)"
                    : "\(name): \(item.notVerifiedCount) files \(notVerifiedWord)"
                if explainReasons, let reason = item.notVerifiedReason {
                    line += " (\(reason.rowNote))"
                }
                issues.append(line)
            }
            let absentCount = item.missingCount - item.notVerifiedCount
            if absentCount > 0 {
                issues.append(absentCount == 1
                    ? "\(name): 1 file has no result"
                    : "\(name): \(absentCount) files have no result")
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
        if skippedFinderMetadataCount > 0 {
            issues.append(finderMetadataSkipDescription(skippedFinderMetadataCount) + ": not card content; Finder recreates them")
        }
        return issues
    }

    public struct ASCMHLJob: Sendable {
        public let root: URL
        public let files: [ASCMHLGenerator.VerifiedFile]
        /// The backup as summaries name it (its volume), from the selected destination.
        public let label: String

        public init(root: URL, files: [ASCMHLGenerator.VerifiedFile], label: String? = nil) {
            self.root = root
            self.files = files
            self.label = label ?? TransferCompletion.destinationLabel(for: root, roots: [root])
        }
    }

    /// A history is written only for a backup whose every file verified
    /// with SHA-256; each other backup gets an issue saying why not.
    public static func ascmhlPlan(
        results: [FileOperationResult],
        sourceFiles: [URL]?,
        destinations: [URL],
        source: URL,
        settings: CameraLabelSettings,
        skippedFinderMetadataPaths: [String]? = nil
    ) -> (jobs: [ASCMHLJob], issues: [String]) {
        // A filtered inventory describes only selected, verified destination
        // contents. The report/history retain excluded rows and an unsafe
        // whole-card verdict; the history is never a whole-source assertion.
        // Entries BitMatch does not copy are failures for the verdict, not files
        // the history could describe.
        // Skipped Finder view files were never written, so they are left out
        // of the hashes too (no `<ignore>` element: the reference verifier
        // already ignores `.DS_Store`). Proven paths leave the expected files
        // only when the one predicate holds for the whole run; otherwise the
        // skipped files stay expected with no counted row, so no history is
        // written (a path the final gate failed answers false too).
        let skipsProven = finderMetadataSkipsProven(
            rows: results.map { row(from: $0, destinationRoots: destinations) },
            provenPaths: skippedFinderMetadataPaths, sourceFiles: sourceFiles,
            destinations: destinations, source: source, settings: settings
        )
        let skippedPaths = skipsProven ? Set(skippedFinderMetadataPaths ?? []) : []
        let results = results.filter {
            !$0.excludedAppleDouble && !$0.skippedFinderMetadata
                && $0.failureReason != ResultFailureReason.unsupportedSourceEntry.rawValue
        }
        let excludedPaths = Set(settings.excludedAppleDoublePaths ?? []).union(skippedPaths)
        let sourceFiles = sourceFiles.map { files in files.filter { !excludedPaths.contains($0.relativePath(to: source)) } }
        let entries = results.map { CoverageEntry(source: $0.sourceURL, destination: $0.destinationURL) }
        let coverage = coverageAnalysis(
            entries: entries, sourceFiles: sourceFiles, destinations: destinations,
            source: source, settings: settings
        )
        var jobs: [ASCMHLJob] = []
        var issues = coverage.issues.map { "ASC MHL not created — \($0)" }
        // Name the volume, not the folder two backups often share; backups
        // that would still read alike get just enough of their path.
        let labels = distinctDestinationLabels(for: coverage.destinations.map(\.destination))
        for (position, item) in coverage.destinations.enumerated() {
            let rows = item.entryIndices.map { results[$0] }
            let name = labels[position]
            guard sourceFiles != nil, item.isExact else {
                issues.append("ASC MHL not created on \(name) because verification is incomplete")
                continue
            }
            let notVerified = rows.filter { !($0.success && $0.verificationResult?.isValid == true) }.count
            let notSHA256 = rows.filter { $0.verificationResult?.checksumType != .sha256 }.count
            guard notVerified == 0, notSHA256 == 0 else {
                let count = notVerified > 0 ? notVerified : notSHA256
                let files = count == 1 ? "1 file" : "\(count) files"
                issues.append("ASC MHL not created on \(name): \(files) not verified\(notVerified > 0 ? "" : " with SHA-256")")
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
            }, label: name))
        }
        return (jobs, issues)
    }

    /// Writes each planned history and returns every issue: the plan's and
    /// any write failures. When there is any issue, the list starts with the
    /// backups that did get a history ("ASC MHL saved on B"), so a partial
    /// handoff is never read as none; with no issue the list stays empty.
    /// Blocking file I/O; run it off the main actor.
    public static func writeASCMHL(
        _ jobs: [ASCMHLJob],
        planIssues: [String],
        startTime: Date,
        source: URL,
        toolVersion: String, progress: ASCMHLGenerator.ProgressHandler? = nil, diagnosticRun: UUID? = nil,
        operatorName: String = "", notes: String = ""
    ) throws -> [String] {
        var failures = planIssues
        let totalBytes = jobs.flatMap(\.files).reduce(Int64(0)) { $0 + max(0, $1.size) }
        let totalFiles = jobs.reduce(0) { $0 + $1.files.count }
        var precedingBytes: Int64 = 0
        var precedingFiles = 0
        var saved: [String] = []
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
                    }, diagnosticRun: diagnosticRun, operatorName: operatorName, notes: notes
                )
                saved.append(job.label)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                SharedLogger.transferError(error, run: diagnosticRun)
                failures.append("\(job.label): ASC MHL — \(error.localizedDescription)")
            }
            let last = observed.withLock { $0 }
            precedingBytes += last.bytes
            precedingFiles += last.files
        }
        guard !failures.isEmpty, !saved.isEmpty else { return failures }
        return ["ASC MHL saved on \(saved.joined(separator: ", "))"] + failures
    }

    // MARK: - Verdict

    /// What a project (photographer job) contributed to the outcome.
    public struct ProjectGate: Sendable {
        /// The project's records were saved.
        public let didPersist: Bool
        /// `nil` when no project finalizer ran (an ordinary copy).
        public let locallySafe: Bool?
        /// Positive queue-only evidence, supplied for a known ordinary run or
        /// a separately proven project selection. Unknown project state is not enough.
        public let allowsQueueContinuationForExpectedExclusions: Bool
        public let expectedExclusionQueueIdentity: ExpectedExclusionQueueQualification?

        public init(didPersist: Bool, locallySafe: Bool?, allowsQueueContinuationForExpectedExclusions: Bool = false, expectedExclusionQueueIdentity: ExpectedExclusionQueueQualification? = nil) {
            self.didPersist = didPersist
            self.locallySafe = locallySafe
            self.allowsQueueContinuationForExpectedExclusions = allowsQueueContinuationForExpectedExclusions
            self.expectedExclusionQueueIdentity = expectedExclusionQueueIdentity
        }

        public var permitsExpectedExclusionQueueContinuation: Bool {
            guard didPersist, allowsQueueContinuationForExpectedExclusions,
                  let identity = expectedExclusionQueueIdentity else { return false }
            switch identity {
            case .ordinaryTransfer: return locallySafe == nil
            case .projectTransfer: return locallySafe != nil
            }
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
        project: ProjectGate,
        skippedFinderMetadataPaths: [String]? = nil
    ) -> Verdict {
        // Skipped Finder view files are neither issues nor selected files:
        // they leave the expected files and every count below, and the run
        // is safe only when the one predicate proves them.
        let skipped = rows.filter(\.isSkippedFinderMetadata)
        let skippedSourcePaths = Set(skipped.map(\.path))
        let skipsProven = finderMetadataSkipsProven(
            rows: rows, provenPaths: skippedFinderMetadataPaths, sourceFiles: sourceFiles,
            destinations: destinations, source: source, settings: settings
        )
        let skippedCount = skippedSourcePaths.count
        // With no skipped row this is `rows` and `sourceFiles` unchanged.
        let rowsWithoutSkips = skipped.isEmpty ? rows : rows.filter { !$0.isSkippedFinderMetadata }
        let sourceFiles = skipped.isEmpty ? sourceFiles
            : sourceFiles.map { files in files.filter { !skippedSourcePaths.contains($0.path) } }
        // Safe-to-erase modes count only independently verified readback rows.
        // Quick has no safe verdict; its copied rows remain eligible only for
        // the separate amber "copied, not verified" outcome.
        let counts: (ResultRow) -> Bool = mode == .quick ? \.isSuccessStatus : \.isVerifiedStatus
        let coverageRows = rows.filter(counts)
        // Rows that exist but do not count, so coverage can say "not
        // verified" for them and "has no result" only for absent files.
        let notVerifiedEntries = rows
            .filter { !counts($0) && !$0.isOmittedBySelection }
            .map {
                CoverageEntry(source: URL(fileURLWithPath: $0.path),
                              destination: $0.destinationPath.map { URL(fileURLWithPath: $0) },
                              failureReason: $0.isSuccessStatus ? nil : $0.failureReason)
            }
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
            settings: settings,
            notVerifiedEntries: notVerifiedEntries
        )
        let excluded = rows.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }
        let excludedCount = Set(excluded.map(\.path)).count
        let selectedCoverage: CoverageAnalysis
        if excluded.isEmpty {
            selectedCoverage = coverage
        } else {
            let excludedSourcePaths = Set(excluded.map(\.path))
            let selectedSources = sourceFiles.map { files in files.filter { !excludedSourcePaths.contains($0.path) } }
            selectedCoverage = coverageAnalysis(entries: coverageRows.map {
                CoverageEntry(source: URL(fileURLWithPath: $0.path),
                              destination: $0.destinationPath.map { URL(fileURLWithPath: $0) })
            }, sourceFiles: selectedSources, destinations: destinations, source: source, settings: settings,
               notVerifiedEntries: notVerifiedEntries)
        }
        // Set when the headline below already names the one failure reason.
        var headlineGivesReason = false
        // Set when the headline below already names the proven skips.
        var headlineGivesSkips = false
        let excludedDescription = "\(excludedCount) AppleDouble \(excludedCount == 1 ? "file" : "files") intentionally excluded"
        let skipMismatch = "Skipped-file records do not match this run; keep the card"
        let actualIssueCount = rows.filter { !$0.isSuccessStatus && !$0.isOmittedBySelection }.count
        // An AppleDouble exclusion stays an issue here, so it is never safe.
        let issueCount = rowsWithoutSkips.filter { !$0.isSuccessStatus }.count
        let fileResultsSucceeded = !rowsWithoutSkips.isEmpty && issueCount == 0
        // Outside Quick, a row that was copied but not verified keeps the
        // run from success here too, not only in the app's own verdict: the
        // Dock tile and the finish notification read this success.
        let everyRowVerified = rowsWithoutSkips.allSatisfy(\.isVerifiedStatus)
        let allFilesReused = mode != .quick
            && !rowsWithoutSkips.isEmpty
            && everyRowVerified
            && rowsWithoutSkips.allSatisfy(\.wasReused)
        var fileResultsMessage: String
        if rowsWithoutSkips.isEmpty {
            fileResultsMessage = "No files were copied"
            if !skipsProven {
                fileResultsMessage += "; " + skipMismatch
            } else if skippedCount > 0 {
                fileResultsMessage += "; " + finderMetadataSkipDescription(skippedCount)
                headlineGivesSkips = true
            }
        } else if !skipsProven && actualIssueCount == 0 {
            // Every copied file is fine but the skips are not proven: say that,
            // never "All files copied and verified". With an AppleDouble
            // exclusion too, still say the whole card is not backed up.
            fileResultsMessage = excludedCount > 0
                ? "\(skipMismatch); \(excludedDescription). Keep the source: the whole card is not backed up"
                : skipMismatch
        } else if fileResultsSucceeded {
            if allFilesReused {
                fileResultsMessage = "All files already existed and were verified; nothing new copied"
            } else {
                fileResultsMessage = mode == .quick || !everyRowVerified ? "All files copied" : "All files copied and verified"
            }
            if skippedCount > 0 {
                fileResultsMessage += "; " + finderMetadataSkipDescription(skippedCount)
                headlineGivesSkips = true
            }
        } else if excludedCount > 0 {
            let selected = rows.filter { !$0.isOmittedBySelection }
            let selectedFailures = selected.filter { !$0.isSuccessStatus }
            let onlyUnsupportedFailed = !selectedFailures.isEmpty && selectedFailures.allSatisfy(\.isUnsupportedSourceEntry)
            fileResultsMessage = !selected.isEmpty && selectedCoverage.isExact && selected.allSatisfy(\.isVerifiedStatus)
                ? "Selected files verified; \(excludedDescription). Keep the source: the whole card is not backed up"
                : (mode == .quick && actualIssueCount == 0 && selectedCoverage.isExact
                    ? "Selected files copied without verification; \(excludedDescription). Keep the source"
                    : (onlyUnsupportedFailed
                        ? "\(excludedDescription); the card holds \(Set(selectedFailures.map(\.path)).count == 1 ? "an item" : "items") BitMatch does not copy (a link, pipe, socket or device). Keep the card"
                        : "\(excludedDescription); selected file results need review. Keep the source"))
        } else {
            var failedMessage = issueCount == 1 ? "1 file failed" : "\(issueCount) files failed"
            let reasons = Set(rowsWithoutSkips.filter { !$0.isSuccessStatus }.map(\.failureReason))
            if reasons.count == 1, let token = reasons.first ?? nil, let reason = ResultFailureReason(rawValue: token) {
                headlineGivesReason = true
                switch reason {
                case .outOfSpace:
                    failedMessage += "; a backup ran out of space"
                case .companionConflict:
                    failedMessage += "; the backup keeps its own hidden companion files, so the card's AppleDouble files could not be copied there. Turn on Ignore AppleDouble metadata files"
                case .sourceUnstable:
                    failedMessage += "; the card changed or could not be read consistently. Keep the card"
                case .sourceReadFailed:
                    failedMessage += "; the card could not be read. Keep the card"
                case .sourceNotConnected:
                    failedMessage += "; the card was not connected"
                case .backupRefused:
                    failedMessage += "; a backup was refused before copying started"
                case .unsupportedSourceEntry:
                    let distinctItems = Set(rows.filter(\.isUnsupportedSourceEntry).map(\.path)).count
                    failedMessage += "; the card holds \(distinctItems == 1 ? "an item" : "items") BitMatch does not copy (a link, pipe, socket or device). Keep the card"
                case .destinationChangedAfterCheck:
                    failedMessage += "; a backup's copy changed after BitMatch checked it (something else wrote to it, for example Finder). Keep the source"
                case .destinationMissingAfterCheck:
                    failedMessage += "; a backup's copy was gone when BitMatch checked it again. Keep the source"
                case .destinationSizeChangedAfterCheck:
                    failedMessage += "; a backup's copy changed size after BitMatch checked it. Keep the source"
                case .existingDestinationConflict:
                    failedMessage += "; a different file was already at that name on a backup and was not overwritten. Keep the source"
                case .existingDestinationContentDiffers:
                    failedMessage += "; a file already at that name on a backup has different contents and was not overwritten. Keep the card: it is not proven"
                case .destinationCheckFailed:
                    failedMessage += "; a backup could not be checked at the end of the run. Keep the source"
                }
            }
            fileResultsMessage = failedMessage
        }
        let incompleteCoverageIssues = coverageIssues(
            excludedCount > 0 ? selectedCoverage : coverage,
            notVerifiedWord: mode == .quick ? "failed" : "not verified",
            explainReasons: !headlineGivesReason,
            skippedFinderMetadataCount: skipsProven && !headlineGivesSkips ? skippedCount : 0
        )

        let everythingElseHeld = fileResultsSucceeded && skipsProven && coverage.isExact
            && project.permitsSuccess && handoffIssues.isEmpty && reportIssue == nil
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
