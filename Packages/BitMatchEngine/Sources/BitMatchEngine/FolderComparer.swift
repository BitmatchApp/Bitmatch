// FolderComparer.swift - Compares two folders, file by file.
import Foundation

/// Compares two folder trees with the checks a verification mode asks for
/// (`CompareCheckPlan`). Runs off the main actor and stops at task
/// cancellation. `ComparisonCoordinator` is the app's wrapper around it.
public struct FolderComparer: Sendable {
    public let fileAccess: any FileAccess
    public let checksum: any ChecksumService

    public init(fileAccess: any FileAccess, checksum: any ChecksumService) {
        self.fileAccess = fileAccess
        self.checksum = checksum
    }

    /// Reports progress through `progress`, which is awaited so updates
    /// arrive in order and before the result.
    public func compare(
        left: URL,
        right: URL,
        verificationMode: VerificationMode,
        progress: @Sendable (OperationProgress) async -> Void
    ) async throws -> CompareStats {
        let run = TransferDiagnostics.runID ?? UUID()
        SharedLogger.comparisonEvent(.compareStarted, run: run, mode: verificationMode)
        do {
            let stats = try await compareContents(left: left, right: right,
                                                  verificationMode: verificationMode, run: run, progress: progress)
            SharedLogger.comparisonEvent(.compareFinished, run: run, outcome: .completed, stats: stats)
            return stats
        } catch {
            SharedLogger.transferError(error, run: run)
            SharedLogger.comparisonEvent(.compareFinished, run: run,
                                         outcome: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    private func compareContents(left: URL, right: URL, verificationMode: VerificationMode,
                                 run: UUID, progress: @Sendable (OperationProgress) async -> Void) async throws -> CompareStats {
        try Task.checkCancellation()
        let didStartLeftScope = fileAccess.startAccessing(url: left)
        let didStartRightScope = fileAccess.startAccessing(url: right)
        defer {
            if didStartLeftScope {
                fileAccess.stopAccessing(url: left)
            }
            if didStartRightScope {
                fileAccess.stopAccessing(url: right)
            }
        }

        SharedLogger.comparisonEvent(.comparePhase, run: run, phase: .listingSource)
        let sourceFiles = try await fileAccess.getFileList(from: left)
        try Task.checkCancellation()
        SharedLogger.comparisonEvent(.comparePhase, run: run, phase: .listingDestination)
        let destFiles = try await fileAccess.getFileList(from: right)

        let sourceMap = try buildFileMap(files: sourceFiles, base: left)
        let destMap = try buildFileMap(files: destFiles, base: right)
        try Task.checkCancellation()

        let sourceSet = Set(sourceMap.keys)
        let destSet = Set(destMap.keys)

        // Finder metadata is asymmetric: macOS writes `.DS_Store`, `._`
        // sidecars, and `Icon\r` into browsed folders on its own (notably on
        // exFAT/FAT destinations), so a metadata file that exists ONLY on the
        // destination side is view state, not a difference. A metadata file
        // on the SOURCE side that was never copied is a real gap: the card
        // held a `._` sidecar the backup does not have, and doubt fails
        // closed. Files present on both sides are never content-compared.
        let onlyInSource = sourceSet.subtracting(destSet)
        let onlyInDest = destSet.subtracting(sourceSet).filter { path in
            guard !Self.isOffloadManifest(path), !Self.isFinderMetadata(path),
                  !WorkingReportEntry.isWorkingFile(path: path, root: right) else { return false }
            #if canImport(Darwin)
            if let item = destMap[path], TransferStatusMarker.validatedStatus(at: item.url, relativePath: path) != nil {
                return false
            }
            #endif
            return true
        }
        let common = sourceSet.intersection(destSet).filter { !Self.isFinderMetadata($0) }

        var mismatched: Set<String> = []
        // One plan for engine and screen: Paranoid is byte-by-byte plus SHA-256.
        let plan = CompareCheckPlan.make(for: verificationMode)
        let totalCommon = common.count
        var processedCommon = 0
        SharedLogger.comparisonEvent(.comparePhase, run: run, phase: .checkingContents, checked: 0, total: totalCommon)

        await progress(OperationProgress(
            overallProgress: totalCommon == 0 ? 1.0 : 0.0,
            currentFile: nil,
            filesProcessed: 0,
            totalFiles: totalCommon,
            currentStage: .verifying,
            speed: nil))

        for key in common {
            try Task.checkCancellation()
            guard let src = sourceMap[key], let dst = destMap[key] else { continue }

            if src.size != dst.size {
                mismatched.insert(key)
            } else if !(try await contentsMatch(src.url, dst.url, plan: plan)) {
                mismatched.insert(key)
            }
            try Task.checkCancellation()

            processedCommon += 1
            if processedCommon == 1 || processedCommon % 1000 == 0 || processedCommon == totalCommon {
                SharedLogger.comparisonEvent(.compareProgress, run: run, checked: processedCommon, total: totalCommon)
            }
            let overall = totalCommon == 0 ? 1.0 : Double(processedCommon) / Double(totalCommon)
            await progress(OperationProgress(
                overallProgress: overall,
                currentFile: key,
                filesProcessed: processedCommon,
                totalFiles: totalCommon,
                currentStage: .verifying,
                speed: nil))
        }

        let matched = common.subtracting(mismatched)
        try Task.checkCancellation()

        SharedLogger.info("Comparison complete", category: .transfer)
        SharedLogger.debug("Only in source: \(onlyInSource.count), Only in dest: \(onlyInDest.count), Common: \(matched.count), Mismatched: \(mismatched.count)", category: .transfer)

        return CompareStats(
            onlyInLeftCount: onlyInSource.count,
            onlyInRightCount: onlyInDest.count,
            commonCount: matched.count,
            mismatchedCount: mismatched.count,
            onlyInLeftPaths: onlyInSource.sorted(),
            onlyInRightPaths: onlyInDest.sorted(),
            mismatchedPaths: mismatched.sorted()
        )
    }

    // MARK: - Private Helpers

    /// Runs every check in `plan` and stops at the first one that fails.
    /// An empty plan (Quick) reads no contents and reports a match; the
    /// screen labels that "Sizes match, not verified".
    private func contentsMatch(_ source: URL, _ destination: URL, plan: CompareCheckPlan) async throws -> Bool {
        if plan.byteByByte {
            let identical = try await checksum.performByteComparison(
                sourceURL: source,
                destinationURL: destination,
                progressCallback: nil
            )
            if !identical { return false }
            try Task.checkCancellation()
        }
        for type in plan.checksums {
            let result = try await checksum.verifyFileIntegrity(
                sourceURL: source,
                destinationURL: destination,
                type: type,
                progressCallback: nil
            )
            if !result.matches { return false }
        }
        return true
    }

    /// Finder writes these into any folder it displays, so a card and its offload
    /// differ as soon as someone browses one of them (GitHub issue #8). The
    /// AppleDouble `._` sidecar also travels with real footage on FAT-family
    /// media. See `compare`: destination-only metadata is view state and is
    /// not a difference, while source-only metadata is a real gap.
    public static func isFinderMetadata(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        return name == ".DS_Store" || name == "Icon\r" || name.hasPrefix("._")
    }

    /// Hash manifests an offload writes at the destination root: the ASC MHL
    /// `ascmhl/` history and legacy `.mhl` / `.mhl.md5` files (BitMatch 0.1.4
    /// paranoid transfers). Only ignored when the destination alone has them;
    /// one on the source that was not copied is still reported.
    public static func isOffloadManifest(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/")
        if parts.count > 1 { return parts[0].lowercased() == "ascmhl" }
        let name = relativePath.lowercased()
        return name.hasSuffix(".mhl") || name.hasSuffix(".mhl.md5")
    }

    private func buildFileMap(files: [URL], base: URL) throws -> [String: (url: URL, size: Int64)] {
        var map: [String: (url: URL, size: Int64)] = [:]
        map.reserveCapacity(files.count)
        let resolver = RelativePathResolver(base: base)
        for fileURL in files {
            // Finder metadata stays in the map: `compare` applies the
            // asymmetric rule (destination-only is ignored, source-only is a
            // difference, present-on-both is never content-compared).
            let key = try resolver.resolve(fileURL)
            let size = try fileAccess.getFileSize(for: fileURL)
            map[key] = (fileURL, size)
        }
        return map
    }
}

/// Working reports are ignored only as destination extras. A name alone never
/// establishes ownership of a staging directory.
enum WorkingReportEntry {
    static func isWorkingFile(path: String, root: URL) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        if parts[parts.count - 2] == "Reports", isUnsettledReport(parts[parts.count - 1]) {
            return true
        }
        for index in 1..<(parts.count - 1) where parts[index - 1] == "Reports" {
            let prefix = ".bitmatch-staging-"
            let name = parts[index]
            guard name.hasPrefix(prefix), let id = exactUUID(String(name.dropFirst(prefix.count))) else { continue }
            let directory = parts[...index].reduce(root) { $0.appendingPathComponent($1) }
            if TransferJournal.ownsStagingDirectory(directory, recordID: id) { return true }
        }
        return false
    }

    private static func exactUUID(_ text: String) -> UUID? {
        guard let id = UUID(uuidString: text), id.uuidString.caseInsensitiveCompare(text) == .orderedSame else { return nil }
        return id
    }

    private static func isUnsettledReport(_ name: String) -> Bool {
        let prefix = ".unsettled-"
        guard name.hasPrefix(prefix) else { return false }
        let remainder = String(name.dropFirst(prefix.count))
        guard remainder.count > 37 else { return false }
        let uuidEnd = remainder.index(remainder.startIndex, offsetBy: 36)
        guard exactUUID(String(remainder[..<uuidEnd])) != nil,
              remainder[uuidEnd...].hasPrefix("-BitMatch_Report_") else { return false }
        let tail = String(remainder[uuidEnd...].dropFirst("-BitMatch_Report_".count))
        guard let ext = [".sha-256.txt", ".json", ".pdf", ".csv"].first(where: { tail.hasSuffix($0) }) else { return false }
        let timestamp = String(tail.dropLast(ext.count))
        let bytes = Array(timestamp.utf8)
        guard bytes.count == 20 else { return false }
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 45, 16: 45, 19: 90]
        for (index, byte) in bytes.enumerated() {
            if let expected = separators[index] { if byte != expected { return false } }
            else if !(48...57).contains(byte) { return false }
        }
        let iso = timestamp.replacingOccurrences(of: "-", with: ":", range: timestamp.index(timestamp.startIndex, offsetBy: 13)..<timestamp.index(timestamp.startIndex, offsetBy: 19))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        guard let date = formatter.date(from: iso) else { return false }
        return formatter.string(from: date) == iso
    }
}
