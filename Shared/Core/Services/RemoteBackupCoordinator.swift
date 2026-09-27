#if os(macOS)
import Foundation
import BitMatchEngine

/// Stores the opaque reference in Core Data while keeping bookmark bytes out
/// of every Codable remote-backup payload.
protocol RemoteArtifactBookmarkStore {
    func save(_ data: Data, for reference: String) throws
    func data(for reference: String) throws -> Data?
    func remove(reference: String) throws
}

struct KeychainRemoteArtifactBookmarkStore: RemoteArtifactBookmarkStore {
    func save(_ data: Data, for reference: String) throws {
        guard KeychainHelper.save(data, forKey: reference) else {
            throw RemoteBackupError.bookmarkUnavailable
        }
    }

    func data(for reference: String) throws -> Data? {
        KeychainHelper.load(forKey: reference)
    }

    func remove(reference: String) throws {
        // Compensating cleanup is retryable: a prior attempt may already have
        // removed the value before a later manifest deletion failed.
        guard try data(for: reference) != nil else { return }
        guard KeychainHelper.delete(forKey: reference) else {
            throw RemoteBackupError.bookmarkUnavailable
        }
    }
}

/// The bridge between immutable local transfer evidence and the persistent
/// remote queue. It never reads the source card: package roots are derived
/// only from final `ResultRow.destinationPath` values.
@MainActor
final class RemoteBackupCoordinator: ProjectRemoteCoordinator {
    private static let pendingCleanupPrefix = "bitmatch-pending-cleanup:"
    typealias BookmarkMaker = (URL) throws -> Data
    typealias BookmarkResolver = (Data) throws -> URL
    typealias FileSize = (URL) throws -> Int64
    typealias SHA256 = (URL) async throws -> String
    typealias SecurityScopeStarter = @Sendable (URL) -> Bool
    typealias SecurityScopeStopper = @Sendable (URL) -> Void

    private let store: any PhotographerJobStore
    private let bookmarkStore: any RemoteArtifactBookmarkStore
    private let makeBookmark: BookmarkMaker
    private let resolveBookmark: BookmarkResolver
    private let fileSize: FileSize
    private let sha256: SHA256
    private let startSecurityScope: SecurityScopeStarter
    private let stopSecurityScope: SecurityScopeStopper
    private let now: () -> Date

    init(
        store: any PhotographerJobStore,
        bookmarkStore: any RemoteArtifactBookmarkStore = KeychainRemoteArtifactBookmarkStore(),
        makeBookmark: @escaping BookmarkMaker = makeSecurityScopedBookmark,
        resolveBookmark: @escaping BookmarkResolver = resolveSecurityScopedBookmark,
        fileSize: @escaping FileSize = remoteArtifactFileSize,
        sha256: @escaping SHA256 = remoteArtifactSHA256,
        startSecurityScope: @escaping SecurityScopeStarter = { $0.startAccessingSecurityScopedResource() },
        stopSecurityScope: @escaping SecurityScopeStopper = { $0.stopAccessingSecurityScopedResource() },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.bookmarkStore = bookmarkStore
        self.makeBookmark = makeBookmark
        self.resolveBookmark = resolveBookmark
        self.fileSize = fileSize
        self.sha256 = sha256
        self.startSecurityScope = startSecurityScope
        self.stopSecurityScope = stopSecurityScope
        self.now = now
    }

    @discardableResult
    func selectRemoteProfile(_ profileID: UUID?, for jobID: UUID) throws -> PhotographerJob {
        guard var job = try store.jobs().first(where: { $0.id == jobID }) else {
            throw RemoteBackupError.manifestUnavailable
        }
        if let profileID {
            guard try store.profiles().contains(where: { $0.id == profileID }) else {
                throw RemoteBackupError.missingProfile
            }
            job.remoteBackupConfiguration = RemoteBackupConfiguration(
                isEnabled: true,
                destinationProfileID: profileID
            )
        } else {
            job.remoteBackupConfiguration = RemoteBackupConfiguration()
        }
        job.updatedAt = now()
        try store.save(job)
        return job
    }

    /// Persists an immutable remote manifest and one durable queue item per
    /// verified local file. This is intentionally synchronous: a queue worker
    /// can only see an item after its manifest and package bookmark exist.
    func queueRemoteBackup(
        for cardIngestID: UUID,
        in jobID: UUID,
        results: [ResultRow]
    ) throws -> [RemoteQueueItem] {
        // A previous interrupted creation can only leave terminal tombstones.
        // Retry their compensation before making any new package visible.
        try retryPendingCleanup()
        guard let job = try store.jobs().first(where: { $0.id == jobID }),
              let card = job.cardIngests.first(where: { $0.id == cardIngestID }),
              card.localState == .locallySafe,
              card.locallySafeAt != nil,
              card.verifiedDestinationCount >= job.requiredLocalCopyCount,
              !(card.provenance.confirmedFingerprint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteBackupError.localArtifactNotVerified
        }
        guard let configuration = job.remoteBackupConfiguration,
              configuration.isEnabled,
              let profileID = configuration.destinationProfileID,
              try store.profiles().contains(where: { $0.id == profileID }) else {
            throw RemoteBackupError.missingProfile
        }

        let artifacts = try verifiedArtifacts(for: card, requiredDestinationCount: job.requiredLocalCopyCount, results: results)
        guard let selectedArtifact = artifacts.sorted(by: { $0.packageRoot.path < $1.packageRoot.path }).first else {
            throw RemoteBackupError.localArtifactNotVerified
        }

        let cardPackagePath = try remotePath(from: card.renderedRelativePath)
        let packageRelativePath: RemoteRelativePath
        if let destinationPath = configuration.destinationPath {
            packageRelativePath = try destinationPath.appending(path: cardPackagePath)
        } else {
            packageRelativePath = cardPackagePath
        }
        let manifestID = UUID()
        let bookmarkReference = "remote-artifact.\(manifestID.uuidString.lowercased())"
        let manifestEntries = selectedArtifact.entries.map { artifact in
            RemoteManifestEntry(
                id: UUID(),
                relativePath: artifact.relativePath,
                byteCount: artifact.byteCount,
                sha256: artifact.sha256
            )
        }
        var manifest = try RemoteManifest(
            id: manifestID,
            jobID: jobID,
            cardIngestID: cardIngestID,
            destinationProfileID: profileID,
            packageRelativePath: packageRelativePath,
            entries: manifestEntries,
            createdAt: now()
        )

        // The bookmark is deliberately made from the verified destination
        // package root, never from ResultRow.path or the camera-card source.
        try bookmarkStore.save(try makeBookmark(selectedArtifact.packageRoot), for: bookmarkReference)
        var savedItemIDs: [UUID] = []
        do {
            try store.save(manifest)
            let items = try manifest.entries.map { entry in
                let itemID = UUID()
                let final = try manifest.packageRelativePath.appending(path: entry.relativePath)
                let temporary = try temporaryPath(final: final, itemID: itemID)
                let item = RemoteQueueItem(
                    id: itemID,
                    jobID: jobID,
                    cardIngestID: cardIngestID,
                    destinationProfileID: profileID,
                    manifestID: manifest.id,
                    manifestEntryID: entry.id,
                    localArtifactBookmarkReference: bookmarkReference,
                    localArtifactRelativePath: entry.relativePath,
                    remoteRelativePath: final,
                    temporaryRemoteRelativePath: temporary,
                    state: .queued,
                    uploadedByteCount: 0,
                    retryCount: 0,
                    nextAttemptAt: nil,
                    verificationEvidence: .none,
                    errorSummary: nil,
                    createdAt: now(),
                    updatedAt: now()
                )
                try store.save(item)
                savedItemIDs.append(item.id)
                return item
            }
            return items
        } catch {
            // Never leave a runnable partial package. First durably mark every
            // saved item terminal, then attempt dependency-ordered deletion.
            // If any deletion fails the tombstone remains and is retried by a
            // later queue request; restore cannot upload a terminal tombstone.
            try markPendingCleanup(
                manifest: &manifest,
                itemIDs: savedItemIDs,
                bookmarkReference: bookmarkReference
            )
            try retryPendingCleanup()
            throw error
        }
    }

    private func markPendingCleanup(
        manifest: inout RemoteManifest,
        itemIDs: [UUID],
        bookmarkReference: String
    ) throws {
        manifest.pendingCleanupBookmarkReference = bookmarkReference
        try store.save(manifest)
        let marker = "\(Self.pendingCleanupPrefix)\(manifest.id.uuidString)"
        for itemID in itemIDs {
            guard var item = try store.queueItems().first(where: { $0.id == itemID }) else { continue }
            item.state = .cancelled
            item.nextAttemptAt = nil
            item.errorSummary = marker
            item.updatedAt = now()
            try store.save(item)
        }
    }

    /// Retries compensation left by an interrupted package creation. Items are
    /// removed first; only once none remain do we remove manifest and bookmark.
    private func retryPendingCleanup() throws {
        let pendingManifests = try store.manifests().filter { $0.pendingCleanupBookmarkReference != nil }
        let pendingIDs = Set(pendingManifests.map(\.id))
        let pending = try store.queueItems().filter { pendingIDs.contains($0.manifestID) }
        for item in pending {
            try store.deleteQueueItem(id: item.id)
        }
        // Delete the bookmark first. `remove` is idempotent, so if manifest
        // deletion then fails its durable marker makes the next retry safe.
        let remaining = try store.queueItems()
        for manifest in pendingManifests {
            guard !remaining.contains(where: { $0.manifestID == manifest.id }),
                  let bookmarkReference = manifest.pendingCleanupBookmarkReference else { continue }
            try bookmarkStore.remove(reference: bookmarkReference)
            try store.deleteManifest(id: manifest.id)
        }
    }

    /// Called by `RemoteBackupQueue` immediately before it hands a URL to a
    /// provider. It resolves the persisted package bookmark and proves that
    /// the requested file is still contained, equal-sized, and SHA-256-equal.
    func resolveLocalArtifact(for item: RemoteQueueItem) async throws -> RemoteBackupArtifactLease {
        guard let manifest = try store.manifests().first(where: { $0.id == item.manifestID }),
              manifest.jobID == item.jobID,
              manifest.cardIngestID == item.cardIngestID,
              manifest.destinationProfileID == item.destinationProfileID,
              let entry = manifest.entries.first(where: { $0.id == item.manifestEntryID }),
              entry.relativePath == item.localArtifactRelativePath,
              let bookmark = try bookmarkStore.data(for: item.localArtifactBookmarkReference) else {
            throw RemoteBackupError.bookmarkUnavailable
        }

        let root: URL
        do {
            root = try resolveBookmark(bookmark).standardizedFileURL.resolvingSymlinksKeepingCase()
        } catch {
            throw RemoteBackupError.bookmarkUnavailable
        }
        guard startSecurityScope(root) else {
            throw RemoteBackupError.bookmarkUnavailable
        }
        var releaseOnFailure = true
        defer {
            if releaseOnFailure {
                stopSecurityScope(root)
            }
        }
        let file = root.appendingPathComponent(entry.relativePath.description, isDirectory: false)
            .standardizedFileURL.resolvingSymlinksKeepingCase()
        guard contains(file, in: root),
              (try? fileSize(file)) == entry.byteCount,
              let digest = try? await sha256(file),
              digest.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            throw RemoteBackupError.localArtifactNotVerified
        }
        releaseOnFailure = false
        return RemoteBackupArtifactLease(url: file) { [stopSecurityScope] in
            stopSecurityScope(root)
        }
    }

    private struct VerifiedArtifact {
        struct Entry {
            let relativePath: RemoteRelativePath
            let byteCount: Int64
            let sha256: String
        }

        let packageRoot: URL
        let entries: [Entry]
    }

    private func verifiedArtifacts(
        for card: CardIngest,
        requiredDestinationCount: Int,
        results: [ResultRow]
    ) throws -> [VerifiedArtifact] {
        let packageComponents = try remotePath(from: card.renderedRelativePath).components
        let verifiedRows = results.filter { row in
            row.isSuccessStatus && row.size >= 0 && validSHA256(row.checksum)
        }
        guard !verifiedRows.isEmpty, verifiedRows.count == results.count else {
            throw RemoteBackupError.localArtifactNotVerified
        }

        let grouped = Dictionary(grouping: verifiedRows.compactMap { row -> (URL, VerifiedArtifact.Entry)? in
            guard let destinationPath = nonblank(row.destinationPath), destinationPath.hasPrefix("/") else {
                return nil
            }
            let destination = URL(fileURLWithPath: destinationPath).standardizedFileURL
            let components = destination.pathComponents
            guard let start = components.firstSubsequenceIndex(of: packageComponents) else { return nil }
            let end = start + packageComponents.count
            guard end < components.count else { return nil }
            let root = URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<end])))
            let entryComponents = Array(components[end...])
            guard let relativePath = try? RemoteRelativePath(components: entryComponents),
                  let checksum = row.checksum else { return nil }
            return (root, .init(relativePath: relativePath, byteCount: row.size, sha256: checksum))
        }, by: { $0.0.standardizedFileURL.path })

        guard grouped.count >= requiredDestinationCount,
              grouped.values.reduce(0, { $0 + $1.count }) == verifiedRows.count else {
            throw RemoteBackupError.localArtifactNotVerified
        }
        let expectedCount = card.fileCount
        let artifacts = try grouped.map { rootPath, pairs -> VerifiedArtifact in
            let entries = pairs.map(\.1).sorted { $0.relativePath.description < $1.relativePath.description }
            guard entries.count == expectedCount,
                  Set(entries.map { $0.relativePath.portableComparisonKey }).count == entries.count else {
                throw RemoteBackupError.localArtifactNotVerified
            }
            return VerifiedArtifact(packageRoot: URL(fileURLWithPath: rootPath), entries: entries)
        }
        guard checksumEvidenceAgrees(artifacts) else {
            throw RemoteBackupError.localArtifactNotVerified
        }
        return artifacts
    }

    private func checksumEvidenceAgrees(_ artifacts: [VerifiedArtifact]) -> Bool {
        guard let first = artifacts.first else { return false }
        let baseline = Dictionary(uniqueKeysWithValues: first.entries.map { ($0.relativePath, $0.sha256.lowercased()) })
        return artifacts.allSatisfy { artifact in
            artifact.entries.count == baseline.count && artifact.entries.allSatisfy {
                baseline[$0.relativePath] == $0.sha256.lowercased()
            }
        }
    }

    private func remotePath(from path: String) throws -> RemoteRelativePath {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return try RemoteRelativePath(components: components)
    }

    private func temporaryPath(final: RemoteRelativePath, itemID: UUID) throws -> RemoteRelativePath {
        let parent = try RemoteRelativePath(components: Array(final.components.dropLast()))
        return try parent.appending(".bitmatch-upload-\(itemID.uuidString.lowercased())")
    }

    private func validSHA256(_ checksum: String?) -> Bool {
        guard let checksum, checksum.utf8.count == 64 else { return false }
        return checksum.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private func nonblank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func contains(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksKeepingCase().path
        let urlPath = url.standardizedFileURL.resolvingSymlinksKeepingCase().path
        return urlPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

}

private func makeSecurityScopedBookmark(for url: URL) throws -> Data {
    #if os(macOS)
    return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    #else
    return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    #endif
}

private func resolveSecurityScopedBookmark(_ data: Data) throws -> URL {
    var stale = false
    #if os(macOS)
    let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
    )
    #else
    let url = try URL(
        resolvingBookmarkData: data,
        options: [],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
    )
    #endif
    guard !stale else { throw RemoteBackupError.bookmarkUnavailable }
    return url
}

private func remoteArtifactFileSize(_ url: URL) throws -> Int64 {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize else {
        throw RemoteBackupError.localArtifactNotVerified
    }
    return Int64(size)
}

private func remoteArtifactSHA256(_ url: URL) async throws -> String {
    try await ChecksumEngine.shared.generateChecksum(for: url, type: .sha256)
}

private extension RemoteBackupState {
    var isTerminal: Bool {
        switch self {
        case .uploadedUnverified, .verified, .failed, .cancelled, .conflict:
            true
        case .queued, .uploading, .retrying, .paused, .verifying:
            false
        }
    }
}

private extension Array where Element: Equatable {
    func firstSubsequenceIndex(of subsequence: [Element]) -> Int? {
        guard !subsequence.isEmpty, subsequence.count <= count else { return nil }
        for start in 0...(count - subsequence.count) where Array(self[start..<(start + subsequence.count)]) == subsequence {
            return start
        }
        return nil
    }
}
#endif
