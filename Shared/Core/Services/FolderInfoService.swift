// FolderInfoService.swift - Centralized folder info scanning and caching
import Foundation
import Combine
import BitMatchEngine

/// Service that handles folder info scanning with caching and loading state tracking
@MainActor
final class FolderInfoService: ObservableObject {

    // MARK: - Published State
    @Published private(set) var sourceFolderInfo: EnhancedFolderInfo?
    @Published private(set) var sourceFingerprint: String?
    @Published private(set) var sourceScanError: String?
    @Published private(set) var leftFolderInfo: EnhancedFolderInfo?
    @Published private(set) var rightFolderInfo: EnhancedFolderInfo?
    @Published private(set) var destinationFolderInfos: [URL: EnhancedFolderInfo] = [:]
    @Published private(set) var folderInfoLoadingState: [URL: Bool] = [:]

    // Track which URLs are currently assigned to which role
    private var sourceURL: URL?
    private var leftURL: URL?
    private var rightURL: URL?
    private var destinationURLs: [URL] = []

    // One owned background task per role, plus a generation counter.
    // Cancelling on supersede stops the enumeration itself; the generation
    // guard stops stale fast/full results from ever publishing.
    private var sourceWork: Task<Void, Never>?
    private var leftWork: Task<Void, Never>?
    private var rightWork: Task<Void, Never>?
    private var sourceGeneration = 0
    private var leftGeneration = 0
    private var rightGeneration = 0
    private var destinationGeneration = 0
    private let destinationMetadataWorker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 8, useBlockingThreads: true)
    private let destinationMetadataNamespace = UUID().uuidString
    private let scanWorker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 8, useBlockingThreads: true)
    private let scanNamespace = UUID().uuidString
    private let destinationModificationDate: @Sendable (URL) -> Date?

    init(destinationModificationDate: @escaping @Sendable (URL) -> Date? = {
        try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }) {
        self.destinationModificationDate = destinationModificationDate
    }

    // MARK: - Public API

    /// Update source folder info when source URL changes
    /// Publishes only the authoritative manifest scan. A metadata-prefetch
    /// pass could hydrate cloud placeholders before the dataless guard runs.
    func updateSource(_ url: URL?) async {
        sourceWork?.cancel()
        sourceGeneration &+= 1
        let generation = sourceGeneration
        if sourceURL != url, let previous = sourceURL {
            folderInfoLoadingState[previous] = false
        }
        sourceURL = url
        guard let url else {
            sourceFolderInfo = nil
            sourceFingerprint = nil
            sourceScanError = nil
            return
        }
        sourceFolderInfo = nil
        sourceFingerprint = nil
        sourceScanError = nil
        folderInfoLoadingState[url] = true
        // Owned task: cancellation stops enumeration; the generation guard
        // stops stale results from publishing.
        sourceWork = Task { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            let fullResult: Result<(EnhancedFolderInfo, String), Error>
            do {
                let result = try await self.scanWorker.performCancellable(
                    mountKeys: [DriveAccessWorker.mountKey(for: url)], jobKey: self.scanNamespace + ".source"
                ) { check in
                    try Self.scanEnhancedFolderInfo(for: url, checkCancellation: check)
                }
                fullResult = .success(result)
            } catch {
                fullResult = .failure(error)
            }
            guard generation == self.sourceGeneration, self.sourceURL == url else { return }
            switch fullResult {
            case .success(let (fullInfo, fingerprint)):
                self.sourceFolderInfo = fullInfo
                self.sourceFingerprint = fingerprint
                self.sourceScanError = nil
            case .failure(let error):
                self.sourceFolderInfo = nil
                self.sourceFingerprint = nil
                self.sourceScanError = error.localizedDescription
            }
            self.folderInfoLoadingState[url] = false
        }
    }

    /// Update left folder info (for comparison mode)
    func updateLeft(_ url: URL?) async {
        leftWork?.cancel()
        leftGeneration &+= 1
        let generation = leftGeneration
        if leftURL != url, let previous = leftURL {
            folderInfoLoadingState[previous] = false
        }
        leftURL = url
        guard let url else {
            leftFolderInfo = nil
            return
        }
        folderInfoLoadingState[url] = true
        leftWork = Task { [weak self] in
            guard let self else { return }
            do {
                let fastInfo = try await self.scanWorker.performCancellable(
                    mountKeys: [DriveAccessWorker.mountKey(for: url)], jobKey: self.scanNamespace + ".left"
                ) { check in try Self.scanFastFolderInfo(for: url, checkCancellation: check) }
                guard generation == self.leftGeneration, self.leftURL == url, !Task.isCancelled else { return }
                self.leftFolderInfo = fastInfo
                let fullInfo = try await self.scanWorker.performCancellable(
                    mountKeys: [DriveAccessWorker.mountKey(for: url)], jobKey: self.scanNamespace + ".left"
                ) { check in try Self.scanEnhancedFolderInfo(for: url, checkCancellation: check).0 }
                guard generation == self.leftGeneration, self.leftURL == url, !Task.isCancelled else { return }
                self.leftFolderInfo = fullInfo
            } catch {
                guard generation == self.leftGeneration, self.leftURL == url, !Task.isCancelled else { return }
                self.leftFolderInfo = nil
            }
            self.folderInfoLoadingState[url] = false
        }
    }

    /// Update right folder info (for comparison mode)
    func updateRight(_ url: URL?) async {
        rightWork?.cancel()
        rightGeneration &+= 1
        let generation = rightGeneration
        if rightURL != url, let previous = rightURL {
            folderInfoLoadingState[previous] = false
        }
        rightURL = url
        guard let url else {
            rightFolderInfo = nil
            return
        }
        folderInfoLoadingState[url] = true
        rightWork = Task { [weak self] in
            guard let self else { return }
            do {
                let fastInfo = try await self.scanWorker.performCancellable(
                    mountKeys: [DriveAccessWorker.mountKey(for: url)], jobKey: self.scanNamespace + ".right"
                ) { check in try Self.scanFastFolderInfo(for: url, checkCancellation: check) }
                guard generation == self.rightGeneration, self.rightURL == url, !Task.isCancelled else { return }
                self.rightFolderInfo = fastInfo
                let fullInfo = try await self.scanWorker.performCancellable(
                    mountKeys: [DriveAccessWorker.mountKey(for: url)], jobKey: self.scanNamespace + ".right"
                ) { check in try Self.scanEnhancedFolderInfo(for: url, checkCancellation: check).0 }
                guard generation == self.rightGeneration, self.rightURL == url, !Task.isCancelled else { return }
                self.rightFolderInfo = fullInfo
            } catch {
                guard generation == self.rightGeneration, self.rightURL == url, !Task.isCancelled else { return }
                self.rightFolderInfo = nil
            }
            self.folderInfoLoadingState[url] = false
        }
    }

    /// Update destination folder infos when destination list changes
    func updateDestinations(_ urls: [URL]) async {
        destinationGeneration &+= 1
        let generation = destinationGeneration
        let removedURLs = Set(destinationURLs).subtracting(urls)
        for url in removedURLs {
            destinationMetadataWorker.cancel(jobKey: destinationMetadataJobKey(for: url))
        }
        destinationURLs = urls
        let urlSet = Set(urls)
        destinationFolderInfos = destinationFolderInfos.filter { urlSet.contains($0.key) }
        folderInfoLoadingState = folderInfoLoadingState.filter {
            urlSet.contains($0.key) || $0.key == sourceURL || $0.key == leftURL || $0.key == rightURL
        }

        // Find new URLs that need scanning
        let newURLs = urls.filter { destinationFolderInfos[$0] == nil }

        if !newURLs.isEmpty {
            for url in newURLs {
                folderInfoLoadingState[url] = true
            }

            // Refill as each check finishes, so one blocked mount does not
            // hold later selected backups behind an entire batch.
            await withTaskGroup(of: (URL, EnhancedFolderInfo?).self) { group in
                var nextIndex = 0
                for _ in 0..<min(6, newURLs.count) {
                    let url = newURLs[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        guard !Task.isCancelled else { return (url, nil) }
                        return (url, await self.getLightweightFolderInfo(for: url))
                    }
                }
                while let (url, info) = await group.next() {
                    guard !Task.isCancelled, destinationGeneration == generation, destinationURLs == urls else {
                        group.cancelAll()
                        continue
                    }
                    destinationFolderInfos[url] = info
                    folderInfoLoadingState[url] = false
                    if nextIndex < newURLs.count {
                        let nextURL = newURLs[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            guard !Task.isCancelled else { return (nextURL, nil) }
                            return (nextURL, await self.getLightweightFolderInfo(for: nextURL))
                        }
                    }
                }
            }
        }
    }

    /// Get folder info for any URL (checks all caches)
    func getFolderInfo(for url: URL) -> EnhancedFolderInfo? {
        if url == sourceURL { return sourceFolderInfo }
        if url == leftURL { return leftFolderInfo }
        if url == rightURL { return rightFolderInfo }
        return destinationFolderInfos[url]
    }

    /// Check if folder info is currently loading for a URL
    func isFolderInfoLoading(for url: URL) -> Bool {
        return folderInfoLoadingState[url] ?? false
    }

    /// True until the source scan for `url` has finished: while it runs, and
    /// also before its task has picked the URL up, so the moment right after
    /// a choice never reads as "analysed".
    func isAwaitingSourceInfo(for url: URL) -> Bool {
        sourceURL != url || isFolderInfoLoading(for: url)
    }

    /// The same for the left compare folder.
    func isAwaitingLeftInfo(for url: URL) -> Bool {
        leftURL != url || isFolderInfoLoading(for: url)
    }

    /// The same for the right compare folder.
    func isAwaitingRightInfo(for url: URL) -> Bool {
        rightURL != url || isFolderInfoLoading(for: url)
    }

    // MARK: - Private Scanning Methods

    /// Perf 8: Fast pass - count + size only, returns quickly.
    /// Synchronous: the bounded worker supplies cancellation checks between
    /// filesystem calls, including when a stale scan is released from a stall.
    ///
    /// Counts with the engine's enumeration (`CardSource`), not a Foundation
    /// enumerator: Foundation hides `._` AppleDouble sidecars on Apple
    /// filesystems, so setup's count must come from the same manifest the
    /// transfer copies and verifies.
    nonisolated private static func scanFastFolderInfo(for url: URL, checkCancellation: @Sendable () throws -> Void) throws -> EnhancedFolderInfo? {
            try checkCancellation()
            let entries: [FileEntry]
            do {
                entries = try CardSource.enumerateRegularFiles(base: url, checkCancellation: checkCancellation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return nil
            }
            try checkCancellation()
            var totalSize: Int64 = 0
            for entry in entries {
                try checkCancellation()
                totalSize += entry.size
            }

            let folderModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            try checkCancellation()
            return EnhancedFolderInfo(
                url: url,
                fileCount: entries.count,
                totalSize: totalSize,
                lastModified: folderModified,
                isInternalDrive: !url.path.starts(with: "/Volumes/"),
                fileTypeBreakdown: [:],
                largestFile: nil,
                oldestFileDate: nil,
                newestFileDate: nil
            )
    }

    /// Full scan for source folders - includes file type breakdown.
    /// Synchronous: the bounded worker supplies cancellation checks between
    /// filesystem calls, including when a stale scan is released from a stall.
    ///
    /// Built on the engine's enumeration (`CardSource`) for the same reason
    /// as the fast pass: the count, sizes, and dates must match the manifest
    /// the transfer copies and verifies, including `._` sidecars.
    nonisolated private static func scanEnhancedFolderInfo(for url: URL, checkCancellation: @Sendable () throws -> Void) throws -> (EnhancedFolderInfo, String) {
            var fileCount = 0
            var totalSize: Int64 = 0
            var fileTypeBreakdown: [String: Int] = [:]
            var largestFile: (name: String, size: Int64)? = nil
            var oldestFile: Date? = nil
            var newestFile: Date? = nil

            let entries = try CardSource.enumerateRegularFiles(base: url, checkCancellation: checkCancellation)
            for entry in entries {
                try checkCancellation()
                fileCount += 1
                totalSize += max(0, entry.size)
                let fileExtension = entry.url.pathExtension.uppercased()
                let displayExtension = fileExtension.isEmpty ? "No Extension" : fileExtension
                fileTypeBreakdown[displayExtension, default: 0] += 1
                if largestFile == nil || entry.size > largestFile!.size {
                    largestFile = (name: entry.url.lastPathComponent, size: entry.size)
                }
                if let date = entry.modificationDate {
                    oldestFile = oldestFile.map { min($0, date) } ?? date
                    newestFile = newestFile.map { max($0, date) } ?? date
                }

                if fileCount % 5000 == 0 && fileCount > 0 {
                    let formatted = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
                    SharedLogger.debug("FolderInfo: analyzed \(fileCount) files, size=\(formatted) at \(url.path)", category: .transfer)
                }
            }

            let folderModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            try checkCancellation()

            let info = EnhancedFolderInfo(
                url: url,
                fileCount: fileCount,
                totalSize: totalSize,
                lastModified: folderModified,
                isInternalDrive: !url.path.starts(with: "/Volumes/"),
                fileTypeBreakdown: fileTypeBreakdown,
                largestFile: largestFile,
                oldestFileDate: oldestFile,
                newestFileDate: newestFile
            )
            let fingerprint = SourceFingerprint.make(entries)
            try checkCancellation()
            return (info, fingerprint)
    }

    private func destinationMetadataJobKey(for url: URL) -> String {
        destinationMetadataNamespace + ".destination." + url.path
    }

    /// Lightweight scan for destination folders - just basic metadata.
    private func getLightweightFolderInfo(for url: URL) async -> EnhancedFolderInfo? {
        let readModificationDate = destinationModificationDate
        return try? await destinationMetadataWorker.perform(
            mountKey: DriveAccessWorker.mountKey(for: url), jobKey: destinationMetadataJobKey(for: url)
        ) {
            let lastMod = readModificationDate(url) ?? Date()
            return EnhancedFolderInfo(
                url: url,
                fileCount: 0,
                totalSize: 0,
                lastModified: lastMod,
                isInternalDrive: !url.path.starts(with: "/Volumes/"),
                fileTypeBreakdown: [:],
                largestFile: nil,
                oldestFileDate: nil,
                newestFileDate: nil
            )
        }
    }
}
