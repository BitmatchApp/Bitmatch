import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

@MainActor
struct RemoteBackupCoordinatorTests {
    @Test func copyingCardCannotCreateRemoteManifest() throws {
        let fixture = try CoordinatorFixture(localState: .copying)

        #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            try fixture.coordinator.queueRemoteBackup(
                for: fixture.card.id,
                in: fixture.job.id,
                results: fixture.rows
            )
        }
        #expect(fixture.store.storedManifests.isEmpty)
        #expect(fixture.store.storedQueueItems.isEmpty)
    }

    @Test func failedCardCannotCreateRemoteManifest() throws {
        let fixture = try CoordinatorFixture(localState: .issues)

        #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            try fixture.coordinator.queueRemoteBackup(
                for: fixture.card.id,
                in: fixture.job.id,
                results: fixture.rows
            )
        }
    }

    @Test func queueBookmarkIsCreatedFromVerifiedDestinationPackageNeverSourceCard() throws {
        let fixture = try CoordinatorFixture()

        let items = try fixture.coordinator.queueRemoteBackup(
            for: fixture.card.id,
            in: fixture.job.id,
            results: fixture.rows
        )

        let item = try #require(items.first)
        let savedBookmarkData = try fixture.bookmarks.data(for: item.localArtifactBookmarkReference)
        let bookmarkData = try #require(savedBookmarkData)
        #expect(String(decoding: bookmarkData, as: UTF8.self) == fixture.destinationPackage.path)
        #expect(String(decoding: bookmarkData, as: UTF8.self) != fixture.sourceCard.path)
        #expect(item.localArtifactRelativePath.components == ["DCIM", "A.ARW"])
    }

    @Test func resolverRejectsArtifactWhoseChecksumNoLongerMatchesManifest() async throws {
        let fixture = try CoordinatorFixture(checksum: String(repeating: "a", count: 64))
        let item = try #require(try fixture.coordinator.queueRemoteBackup(
            for: fixture.card.id,
            in: fixture.job.id,
            results: fixture.rows
        ).first)

        fixture.checksum = String(repeating: "b", count: 64)

        await #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            _ = try await fixture.coordinator.resolveLocalArtifact(for: item)
        }
    }

    @Test func sameSizeLocalFileChangeInvalidatesSavedRemoteManifest() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("remote-stale-\(UUID())")
        let file = package.appendingPathComponent("DCIM/A.ARW")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        try Data("ONE".utf8).write(to: file)
        let originalDigest = try await ChecksumEngine.shared.generateChecksum(for: file, type: .sha256)
        let fixture = try CoordinatorFixture(
            checksum: originalDigest,
            fileSize: { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize else {
                    throw RemoteBackupError.localArtifactNotVerified
                }
                return Int64(size)
            },
            sha256: { url in try await ChecksumEngine.shared.generateChecksum(for: url, type: .sha256) }
        )
        let item = try #require(try fixture.coordinator.queueRemoteBackup(
            for: fixture.card.id, in: fixture.job.id, results: fixture.rows
        ).first)
        try fixture.bookmarks.save(Data(package.path.utf8), for: item.localArtifactBookmarkReference)

        let validLease = try await fixture.coordinator.resolveLocalArtifact(for: item)
        validLease.release()
        try Data("TWO".utf8).write(to: file)
        #expect(try Data(contentsOf: file).count == 3)
        await #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            _ = try await fixture.coordinator.resolveLocalArtifact(for: item)
        }
    }

    @Test func resolverScopesAccessUntilItsLeaseIsReleased() async throws {
        let fixture = try CoordinatorFixture()
        let item = try #require(try fixture.coordinator.queueRemoteBackup(for: fixture.card.id, in: fixture.job.id, results: fixture.rows).first)

        let lease = try await fixture.coordinator.resolveLocalArtifact(for: item)
        #expect(fixture.scopeStarts == 1)
        #expect(fixture.scopeStops == 0)
        lease.release()
        lease.release()
        #expect(fixture.scopeStops == 1)
    }

    @Test func resolverStopsScopeWhenArtifactValidationFails() async throws {
        let fixture = try CoordinatorFixture(checksum: String(repeating: "a", count: 64))
        let item = try #require(try fixture.coordinator.queueRemoteBackup(for: fixture.card.id, in: fixture.job.id, results: fixture.rows).first)
        fixture.checksum = String(repeating: "b", count: 64)

        await #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            _ = try await fixture.coordinator.resolveLocalArtifact(for: item)
        }
        #expect(fixture.scopeStarts == 1)
        #expect(fixture.scopeStops == 1)
    }

    @Test func resolverRejectsSymlinkThatEscapesTheBookmarkedPackage() async throws {
        let fixture = try CoordinatorFixture()
        let item = try #require(try fixture.coordinator.queueRemoteBackup(for: fixture.card.id, in: fixture.job.id, results: fixture.rows).first)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outside.appendingPathComponent("A.ARW").path, contents: Data([0]))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("DCIM"), withDestinationURL: outside)
        try fixture.bookmarks.save(Data(root.path.utf8), for: item.localArtifactBookmarkReference)

        await #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            _ = try await fixture.coordinator.resolveLocalArtifact(for: item)
        }
        #expect(fixture.scopeStarts == 1)
        #expect(fixture.scopeStops == 1)
    }

    @Test func partialItemSaveRollsBackAllItemsManifestAndBookmark() throws {
        let fixture = try CoordinatorFixture(fileCount: 2)
        fixture.store.failSavingItemAtAttempt = 2

        #expect(throws: CoordinatorStoreError.forcedSaveFailure) {
            try fixture.coordinator.queueRemoteBackup(for: fixture.card.id, in: fixture.job.id, results: fixture.rows)
        }
        #expect(fixture.store.storedQueueItems.isEmpty)
        #expect(fixture.store.storedManifests.isEmpty)
        #expect(fixture.bookmarks.isEmpty)
    }

    @Test func failedRollbackPersistsTerminalTombstoneUntilLaterRetry() throws {
        let fixture = try CoordinatorFixture(fileCount: 2)
        fixture.store.failSavingItemAtAttempt = 2
        fixture.store.failDeletingQueueItemAtAttempt = 1

        #expect(throws: CoordinatorStoreError.forcedDeleteFailure) {
            try fixture.coordinator.queueRemoteBackup(for: fixture.card.id, in: fixture.job.id, results: fixture.rows)
        }
        #expect(fixture.store.storedQueueItems.allSatisfy { $0.state == .cancelled })
        #expect(fixture.store.storedManifests.count == 1)
        #expect(!fixture.bookmarks.isEmpty)

        fixture.store.failDeletingQueueItemAtAttempt = nil
        _ = try fixture.coordinator.queueRemoteBackup(for: fixture.card.id, in: fixture.job.id, results: fixture.rows)
        #expect(fixture.store.storedManifests.count == 1)
    }

    @Test func failedManifestDeletionRetainsCleanupMarkerForRetry() throws {
        let fixture = try CoordinatorFixture(fileCount: 2)
        fixture.store.failSavingItemAtAttempt = 2
        fixture.store.failDeletingManifestAtAttempt = 1

        #expect(throws: CoordinatorStoreError.forcedManifestDeleteFailure) {
            try fixture.coordinator.queueRemoteBackup(for: fixture.card.id, in: fixture.job.id, results: fixture.rows)
        }
        #expect(fixture.store.storedQueueItems.isEmpty)
        #expect(fixture.store.storedManifests.first?.pendingCleanupBookmarkReference != nil)

        fixture.store.failDeletingManifestAtAttempt = nil
        _ = try fixture.coordinator.queueRemoteBackup(for: fixture.card.id, in: fixture.job.id, results: fixture.rows)
        #expect(fixture.store.storedManifests.count == 1)
    }
}

@MainActor
private final class CoordinatorFixture {
    let sourceCard: URL
    let destinationPackage: URL
    let store: CoordinatorStore
    let bookmarks = CoordinatorBookmarkStore()
    private let checksumBox: ChecksumBox
    var checksum: String {
        get { checksumBox.value }
        set { checksumBox.value = newValue }
    }
    private let scopeCounter: ScopeCounter
    var scopeStarts: Int { scopeCounter.starts }
    var scopeStops: Int { scopeCounter.stops }
    let job: PhotographerJob
    let card: CardIngest
    let rows: [ResultRow]
    let coordinator: RemoteBackupCoordinator

    init(
        localState: PhotographerLocalState = .locallySafe,
        checksum: String = String(repeating: "a", count: 64),
        fileCount: Int = 1,
        fileSize: RemoteBackupCoordinator.FileSize? = nil,
        sha256: RemoteBackupCoordinator.SHA256? = nil
    ) throws {
        let sourceCard = URL(fileURLWithPath: "/Volumes/CARD")
        let destinationPackage = URL(fileURLWithPath: "/Volumes/Archive/Job/Card-001")
        let checksumBox = ChecksumBox(checksum)
        let scopeCounter = ScopeCounter()
        self.sourceCard = sourceCard
        self.destinationPackage = destinationPackage
        self.checksumBox = checksumBox
        self.scopeCounter = scopeCounter
        let card = CardIngest(
            id: UUID(),
            provenance: CardProvenance(
                photographerID: UUID(), photographerName: "Mike", cameraName: "Sony", cardNumber: 1,
                preliminaryFingerprint: "preliminary", confirmedFingerprint: "confirmed"
            ),
            sourceDisplayName: "CARD",
            renderedRelativePath: "Job/Card-001",
            localState: localState,
            startedAt: Date(timeIntervalSince1970: 1),
            locallySafeAt: localState == .locallySafe ? Date(timeIntervalSince1970: 2) : nil,
            fileCount: fileCount,
            totalBytes: 3,
            verifiedDestinationCount: localState == .locallySafe ? 1 : 0
        )
        self.card = card
        let profile = RemoteDestinationProfile(
            id: UUID(), name: "Archive", host: "archive.example.test", port: 22, username: "mike",
            root: try RemoteRelativePath(components: ["Backups"]), verificationMode: .sha256
        )
        self.job = PhotographerJob(
            id: UUID(), eventDate: .now, clientName: "Smith", jobName: "Wedding", eventType: .wedding,
            photographers: [], recipe: .wedding, requiredLocalCopyCount: 1, cardIngests: [card],
            remoteBackupConfiguration: .init(isEnabled: true, destinationProfileID: profile.id),
            createdAt: .now, updatedAt: .now
        )
        self.rows = (0..<fileCount).map { index in
            let name = index == 0 ? "A.ARW" : "B.ARW"
            return ResultRow(
                path: sourceCard.appendingPathComponent("DCIM/\(name)").path,
                status: "✅ Verified", size: 3, checksum: checksum, destination: "Archive",
                destinationPath: destinationPackage.appendingPathComponent("DCIM/\(name)").path
            )
        }
        self.store = CoordinatorStore(jobs: [job], profiles: [profile])
        self.coordinator = RemoteBackupCoordinator(
            store: store,
            bookmarkStore: bookmarks,
            makeBookmark: { Data($0.path.utf8) },
            resolveBookmark: { URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)) },
            fileSize: fileSize ?? { _ in 3 },
            sha256: sha256 ?? { _ in checksumBox.value },
            startSecurityScope: { [scopeCounter] _ in scopeCounter.recordStart() },
            stopSecurityScope: { [scopeCounter] _ in scopeCounter.recordStop() },
            now: { Date(timeIntervalSince1970: 3) }
        )
    }
}

private final class ChecksumBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String

    init(_ value: String) {
        storedValue = value
    }

    var value: String {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class ScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0

    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }

    func recordStart() -> Bool {
        lock.withLock { startCount += 1 }
        return true
    }

    func recordStop() {
        lock.withLock { stopCount += 1 }
    }
}

@MainActor
private final class CoordinatorStore: PhotographerJobStore {
    var storedJobs: [PhotographerJob]
    var storedProfiles: [RemoteDestinationProfile]
    var storedManifests: [RemoteManifest] = []
    var storedQueueItems: [RemoteQueueItem] = []
    var failSavingItemAtAttempt: Int?
    var failDeletingQueueItemAtAttempt: Int?
    var failDeletingManifestAtAttempt: Int?
    private var itemSaveAttempts = 0
    private var itemDeleteAttempts = 0
    private var manifestDeleteAttempts = 0

    init(jobs: [PhotographerJob], profiles: [RemoteDestinationProfile]) {
        storedJobs = jobs
        storedProfiles = profiles
    }

    func jobs() throws -> [PhotographerJob] { storedJobs }
    func save(_ job: PhotographerJob) throws { storedJobs = [job] }
    func deleteJob(id: UUID) throws { storedJobs.removeAll { $0.id == id } }
    func presets() throws -> [PhotographerPreset] { [] }
    func save(_: PhotographerPreset) throws {}
    func profiles() throws -> [RemoteDestinationProfile] { storedProfiles }
    func save(_: RemoteDestinationProfile) throws {}
    func deleteProfile(id _: UUID) throws {}
    func manifests() throws -> [RemoteManifest] { storedManifests }
    func save(_ manifest: RemoteManifest) throws {
        storedManifests.removeAll { $0.id == manifest.id }
        storedManifests.append(manifest)
    }
    func deleteManifest(id: UUID) throws {
        manifestDeleteAttempts += 1
        if manifestDeleteAttempts == failDeletingManifestAtAttempt { throw CoordinatorStoreError.forcedManifestDeleteFailure }
        storedManifests.removeAll { $0.id == id }
    }
    func queueItems() throws -> [RemoteQueueItem] { storedQueueItems }
    func save(_ item: RemoteQueueItem) throws {
        itemSaveAttempts += 1
        if itemSaveAttempts == failSavingItemAtAttempt { throw CoordinatorStoreError.forcedSaveFailure }
        storedQueueItems.removeAll { $0.id == item.id }
        storedQueueItems.append(item)
    }
    func deleteQueueItem(id: UUID) throws {
        itemDeleteAttempts += 1
        if itemDeleteAttempts == failDeletingQueueItemAtAttempt { throw CoordinatorStoreError.forcedDeleteFailure }
        storedQueueItems.removeAll { $0.id == id }
    }
}

private final class CoordinatorBookmarkStore: RemoteArtifactBookmarkStore {
    private var values: [String: Data] = [:]
    var isEmpty: Bool { values.isEmpty }

    func save(_ data: Data, for reference: String) throws { values[reference] = data }
    func data(for reference: String) throws -> Data? { values[reference] }
    func remove(reference: String) throws { values.removeValue(forKey: reference) }
}

private enum CoordinatorStoreError: Error { case forcedSaveFailure, forcedDeleteFailure, forcedManifestDeleteFailure }
