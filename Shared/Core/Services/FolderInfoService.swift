// FolderInfoService.swift - Centralized folder info scanning and caching
import Foundation
import Combine
import BitMatchEngine

/// Service that handles folder info scanning with caching and loading state tracking
@MainActor
final class FolderInfoService: ObservableObject {

    // MARK: - Published State
    @Published private(set) var sourceFolderInfo: EnhancedFolderInfo?
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

    // MARK: - Public API

    /// Update source folder info when source URL changes
    /// Perf 8: returns fast count+size immediately, then updates with full details asynchronously
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
            return
        }
        folderInfoLoadingState[url] = true
        // Owned task: fast pass, then full details. Cancellation stops the
        // enumeration; the generation guard stops stale publishes.
        sourceWork = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            let fastInfo = self.scanFastFolderInfo(for: url)
            await MainActor.run {
                guard generation == self.sourceGeneration, self.sourceURL == url else { return }
                self.sourceFolderInfo = fastInfo
            }
            if Task.isCancelled { return }
            let fullInfo = self.scanEnhancedFolderInfo(for: url)
            await MainActor.run {
                guard generation == self.sourceGeneration, self.sourceURL == url else { return }
                self.sourceFolderInfo = fullInfo
                self.folderInfoLoadingState[url] = false
            }
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
        leftWork = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            let fastInfo = self.scanFastFolderInfo(for: url)
            await MainActor.run {
                guard generation == self.leftGeneration, self.leftURL == url else { return }
                self.leftFolderInfo = fastInfo
            }
            if Task.isCancelled { return }
            let fullInfo = self.scanEnhancedFolderInfo(for: url)
            await MainActor.run {
                guard generation == self.leftGeneration, self.leftURL == url else { return }
                self.leftFolderInfo = fullInfo
                self.folderInfoLoadingState[url] = false
            }
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
        rightWork = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            let fastInfo = self.scanFastFolderInfo(for: url)
            await MainActor.run {
                guard generation == self.rightGeneration, self.rightURL == url else { return }
                self.rightFolderInfo = fastInfo
            }
            if Task.isCancelled { return }
            let fullInfo = self.scanEnhancedFolderInfo(for: url)
            await MainActor.run {
                guard generation == self.rightGeneration, self.rightURL == url else { return }
                self.rightFolderInfo = fullInfo
                self.folderInfoLoadingState[url] = false
            }
        }
    }

    /// Update destination folder infos when destination list changes
    func updateDestinations(_ urls: [URL]) async {
        destinationURLs = urls

        // Find new URLs that need scanning
        let newURLs = urls.filter { destinationFolderInfos[$0] == nil }

        if !newURLs.isEmpty {
            for url in newURLs {
                folderInfoLoadingState[url] = true
            }

            // Scan in batches to avoid I/O saturation
            var results: [(URL, EnhancedFolderInfo?)] = []
            let chunkSize = 6
            var index = 0

            while index < newURLs.count {
                // Structured group: parent cancellation propagates, so a
                // superseded selection stops the remaining chunks.
                guard !Task.isCancelled else { return }
                let end = min(index + chunkSize, newURLs.count)
                let slice = Array(newURLs[index..<end])

                await withTaskGroup(of: (URL, EnhancedFolderInfo?).self) { group in
                    for url in slice {
                        group.addTask {
                            guard !Task.isCancelled else { return (url, nil) }
                            // Lightweight info to avoid scanning large destination volumes
                            let info = await self.getLightweightFolderInfo(for: url)
                            return (url, info)
                        }
                    }
                    for await pair in group {
                        results.append(pair)
                    }
                }
                index = end
            }

            // A newer selection may have arrived while scanning; never let
            // stale results (or the cleanup below) clobber it.
            guard destinationURLs == urls else { return }

            for (url, info) in results {
                destinationFolderInfos[url] = info
                folderInfoLoadingState[url] = false
            }
        }

        // Clean up removed URLs
        let urlSet = Set(urls)
        destinationFolderInfos = destinationFolderInfos.filter { urlSet.contains($0.key) }

        // Keep loading state for source/left/right URLs
        folderInfoLoadingState = folderInfoLoadingState.filter {
            urlSet.contains($0.key) || $0.key == sourceURL || $0.key == leftURL || $0.key == rightURL
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

    /// Clear all cached folder info
    func clearAll() {
        sourceWork?.cancel()
        leftWork?.cancel()
        rightWork?.cancel()
        sourceWork = nil
        leftWork = nil
        rightWork = nil
        sourceGeneration &+= 1
        leftGeneration &+= 1
        rightGeneration &+= 1
        sourceFolderInfo = nil
        leftFolderInfo = nil
        rightFolderInfo = nil
        destinationFolderInfos.removeAll()
        folderInfoLoadingState.removeAll()
        sourceURL = nil
        leftURL = nil
        rightURL = nil
        destinationURLs.removeAll()
    }

    // MARK: - Private Scanning Methods

    /// Perf 8: Fast pass - count + size only, returns quickly.
    /// Synchronous: callers run it on an owned background task so
    /// cancellation actually stops the enumeration.
    ///
    /// Counts with the engine's enumeration (`CardSource`), not a Foundation
    /// enumerator: Foundation hides `._` AppleDouble sidecars on Apple
    /// filesystems, so setup's count must come from the same manifest the
    /// transfer copies and verifies.
    nonisolated private func scanFastFolderInfo(for url: URL) -> EnhancedFolderInfo? {
            if Task.isCancelled { return nil }
            guard let entries = try? CardSource.enumerateRegularFiles(base: url) else { return nil }
            if Task.isCancelled { return nil }
            var totalSize: Int64 = 0
            for entry in entries {
                totalSize += entry.size
            }

            let folderModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
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
    /// Synchronous: callers run it on an owned background task so
    /// cancellation actually stops the enumeration.
    ///
    /// Built on the engine's enumeration (`CardSource`) for the same reason
    /// as the fast pass: the count, sizes, and dates must match the manifest
    /// the transfer copies and verifies, including `._` sidecars.
    nonisolated private func scanEnhancedFolderInfo(for url: URL) -> EnhancedFolderInfo? {
            if Task.isCancelled { return nil }
            guard let entries = try? CardSource.enumerateRegularFiles(base: url) else {
                return nil
            }
            var fileCount = 0
            var totalSize: Int64 = 0
            var fileTypeBreakdown: [String: Int] = [:]
            var largestFile: (name: String, size: Int64)? = nil
            var oldestFile: Date? = nil
            var newestFile: Date? = nil

            for entry in entries {
                if Task.isCancelled { return nil }
                fileCount += 1
                let fileSize = entry.size
                totalSize += fileSize

                let fileExtension = entry.url.pathExtension.uppercased()
                let displayExtension = fileExtension.isEmpty ? "No Extension" : fileExtension
                fileTypeBreakdown[displayExtension, default: 0] += 1

                if let lf = largestFile {
                    if fileSize > lf.size {
                        largestFile = (name: entry.url.lastPathComponent, size: fileSize)
                    }
                } else {
                    largestFile = (name: entry.url.lastPathComponent, size: fileSize)
                }

                if let modDate = entry.modificationDate {
                    if let oldest = oldestFile {
                        if modDate < oldest { oldestFile = modDate }
                    } else {
                        oldestFile = modDate
                    }
                    if let newest = newestFile {
                        if modDate > newest { newestFile = modDate }
                    } else {
                        newestFile = modDate
                    }
                }

                if fileCount % 5000 == 0 && fileCount > 0 {
                    let formatted = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
                    SharedLogger.debug("FolderInfo: analyzed \(fileCount) files, size=\(formatted) at \(url.path)", category: .transfer)
                }
            }

            let folderModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

            return EnhancedFolderInfo(
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
    }

    /// Lightweight scan for destination folders - just basic metadata
    nonisolated private func getLightweightFolderInfo(for url: URL) async -> EnhancedFolderInfo? {
        return await Task.detached(priority: .utility) {
            let lastMod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
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
        }.value
    }
}
