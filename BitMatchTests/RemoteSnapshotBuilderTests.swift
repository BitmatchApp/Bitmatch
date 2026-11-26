import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

@MainActor
@Suite struct RemoteSnapshotBuilderTests {
    private let session = SessionID()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let cardURL = URL(fileURLWithPath: "/Volumes/A001", isDirectory: true)
    private let raidURL = URL(fileURLWithPath: "/Volumes/RAID/Shoot", isDirectory: true)
    private let shuttleURL = URL(fileURLWithPath: "/Volumes/Shuttle/Shoot", isDirectory: true)
    private let media = MediaIncarnation(volumeIdentity: "vol-a001", mountGeneration: 1)
    /// When the card's current mount was registered, before any test record.
    private var mountedAt: Date { now.addingTimeInterval(-3600) }

    private func card(media: MediaIncarnation) -> RemoteCardSummary {
        RemoteCardSummary(id: "card-1", name: "A001", capacityBytes: 64_000, detectedCamera: nil,
                          hasAccess: true, media: media)
    }

    private func arranged(journal: LocalTransferJournal? = nil, cardURL: URL? = nil)
        -> (FakeRemoteSurface, RemoteHostState, RemoteSnapshotBuilder) {
        let surface = FakeRemoteSurface(journal: journal)
        let host = RemoteHostState(revisions: ResourceRevisions(selection: 3, queue: 2, operation: 1, settings: 4, state: 9))
        let cardURL = cardURL ?? self.cardURL
        host.registerCard(card(media: media), url: cardURL, registeredAt: mountedAt)
        host.registerBackup(RemoteBackupSummary(id: "backup-1", name: "RAID", freeBytes: nil, policyVerdict: "ok"), url: raidURL)
        host.registerBackup(RemoteBackupSummary(id: "backup-2", name: "Shuttle", freeBytes: nil, policyVerdict: "ok"), url: shuttleURL)
        surface.sourceURL = cardURL
        surface.destinationURLs = [raidURL]
        let builder = RemoteSnapshotBuilder(surface: surface, host: host, hostName: "Studio Mac", session: session)
        return (surface, host, builder)
    }

    /// A finished record whose source is `folder` but whose recorded volume
    /// identity is `volumeID`, as if a different card had been mounted there.
    private func savedRecord(from folder: URL, volumeID: String, endedAt: Date) throws -> LocalTransferRecord {
        let real = try LocalTransferResource(url: folder)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(real)) as? [String: Any])
        object["volumeID"] = volumeID
        let source = try JSONDecoder().decode(LocalTransferResource.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        var record = LocalTransferRecord(id: UUID(), createdAt: endedAt, source: source, destinations: [real],
                                         verificationMode: .standard, cameraSettings: CameraLabelSettings(),
                                         reportSettings: ReportPrefs())
        record.state = .completed
        record.endedAt = endedAt
        record.summary = "Done"
        return record
    }

    /// A temporary card folder and a journal holding `records(folder)`.
    private func journal(_ records: (URL) throws -> [LocalTransferRecord]) throws -> (URL, LocalTransferJournal) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteSnapshotBuilderTests-\(UUID().uuidString)", isDirectory: true)
        let folder = directory.appendingPathComponent("A001", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode(try records(folder)).write(to: file)
        return (directory, LocalTransferJournal(fileURL: file))
    }

    @Test func aSnapshotCarriesTheSurfaceSelectionAsOpaqueIDs() throws {
        let (_, host, builder) = arranged()

        let snapshot = builder.snapshot(now: now)

        #expect(snapshot.host == host.id)
        #expect(snapshot.session == session)
        #expect(snapshot.hostName == "Studio Mac")
        #expect(snapshot.revisions == host.revisions)
        #expect(snapshot.cards.map(\.id) == ["card-1"])
        #expect(snapshot.backups.map(\.id) == ["backup-1", "backup-2"])
        #expect(snapshot.selectedCardID == "card-1")
        #expect(snapshot.selectedBackupIDs == ["backup-1"])
        #expect(snapshot.unmanagedDestinationCount == 0)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("Volumes"))
    }

    @Test func aBackupWithNoIDIsCountedButNotNamed() throws {
        let (surface, _, builder) = arranged()
        surface.destinationURLs = [raidURL, URL(fileURLWithPath: "/Volumes/Unregistered/Shoot", isDirectory: true)]

        let snapshot = builder.snapshot(now: now)

        #expect(snapshot.selectedBackupIDs == ["backup-1"])
        #expect(snapshot.unmanagedDestinationCount == 1)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("Unregistered"))
    }

    @Test func aSourceFolderOnTheCardSelectsTheCard() {
        let (surface, _, builder) = arranged()
        surface.sourceURL = cardURL.appendingPathComponent("DCIM", isDirectory: true)

        #expect(builder.snapshot(now: now).selectedCardID == "card-1")
    }

    @Test func anUnchangedSurfaceProducesNoPatch() {
        let (_, host, builder) = arranged()
        let first = builder.snapshot(now: now)

        let patch = builder.patch(from: first, now: now.addingTimeInterval(5))

        #expect(patch == nil)
        #expect(host.revisions == first.revisions)
    }

    @Test func changingOnlySettingsBumpsSettingsAndStateRevisions() throws {
        let (surface, host, builder) = arranged()
        let first = builder.snapshot(now: now)
        surface.generalSettings.autoEjectWhenSafe.toggle()

        let update = try #require(builder.patch(from: first, now: now.addingTimeInterval(5)))

        let expected = ResourceRevisions(selection: 3, queue: 2, operation: 1, settings: 5, state: 10)
        #expect(update.baseRevision == 9)
        #expect(update.newRevision == 10)
        #expect(update.snapshotPatch.revisions == expected)
        #expect(host.revisions == expected)
        #expect(update.snapshotPatch.settings?.autoEjectWhenSafe == surface.generalSettings.autoEjectWhenSafe)
        #expect(update.snapshotPatch.cards == nil)
        #expect(update.snapshotPatch.selectedBackupIDs == nil)
        #expect(update.snapshotPatch.queue == nil)
        #expect(update.snapshotPatch.selectedCardID == .unchanged)
        #expect(update.snapshotPatch.operationID == .unchanged)
    }

    @Test func anOperationChangeBumpsTheOperationRevisionNotTheQueue() throws {
        let (surface, _, builder) = arranged()
        let first = builder.snapshot(now: now)
        let target = UUID()
        surface.cancellationTargetID = target

        let update = try #require(builder.patch(from: first, now: now.addingTimeInterval(5)))

        #expect(update.snapshotPatch.revisions == ResourceRevisions(selection: 3, queue: 2, operation: 2, settings: 4, state: 10))
        #expect(update.snapshotPatch.cancellationTargetID == .set(target))
    }

    @Test func finishingSourcePreparationBumpsTheSelectionRevision() throws {
        let (surface, host, builder) = arranged()
        surface.transferReadiness = TransferReadiness(status: .analysing, blockers: [], warnings: [])
        let first = builder.snapshot(now: now)
        surface.transferReadiness = TransferReadiness(status: .ready, blockers: [], warnings: [])

        let update = try #require(builder.patch(from: first, now: now.addingTimeInterval(5)))

        #expect(update.snapshotPatch.revisions.selection == 4)
        #expect(update.snapshotPatch.revisions.settings == 4)
        #expect(update.snapshotPatch.readinessStatus != nil)
        #expect(host.revisions.selection == 4)
    }

    @Test func aRecordFromADifferentCardAtTheSamePathProducesNoClaim() throws {
        var older: LocalTransferRecord?
        let (directory, journal) = try journal { folder in
            let first = try savedRecord(from: folder, volumeID: media.volumeIdentity, endedAt: now)
            let replacement = try savedRecord(from: folder, volumeID: "vol-other-card",
                                              endedAt: now.addingTimeInterval(60))
            older = first
            return [replacement, first]
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("A001", isDirectory: true)
        let (surface, host, builder) = arranged(journal: journal, cardURL: folder)
        surface.queueSessionRecordIDs = Set(journal.records.map(\.id))

        // The newer record at this path belongs to another card; only the
        // record with this card's identity may speak for it.
        let claim = try #require(builder.snapshot(now: now).safetyClaim)
        #expect(claim.recordID == older?.id)
        #expect(claim.media == media)

        host.registerCard(card(media: MediaIncarnation(volumeIdentity: "vol-third-card", mountGeneration: 1)),
                          url: folder, registeredAt: mountedAt)
        #expect(builder.snapshot(now: now).safetyClaim == nil)
    }

    @Test func aRecordFromBeforeTheCurrentMountProducesNoClaim() throws {
        let (directory, journal) = try journal { folder in
            [try savedRecord(from: folder, volumeID: media.volumeIdentity, endedAt: now)]
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("A001", isDirectory: true)
        let (surface, host, builder) = arranged(journal: journal, cardURL: folder)
        surface.queueSessionRecordIDs = Set(journal.records.map(\.id))
        #expect(builder.snapshot(now: now).safetyClaim != nil)

        // Registering the same mount again keeps its registration time.
        host.registerCard(card(media: media), url: folder, registeredAt: now.addingTimeInterval(600))
        #expect(builder.snapshot(now: now).safetyClaim != nil)

        // Ejected and re-inserted, perhaps after more shooting: the volume
        // identity is the same, but yesterday's record says nothing about it.
        let remounted = MediaIncarnation(volumeIdentity: media.volumeIdentity, mountGeneration: 2)
        host.registerCard(card(media: remounted), url: folder, registeredAt: now.addingTimeInterval(600))

        #expect(builder.snapshot(now: now).safetyClaim == nil)
    }

    @Test func aRunningNewerAttemptSuppressesTheOlderClaim() throws {
        // The card's identity is the test folder's real one, so the journal
        // can run a new attempt from it.
        var volumeID: String?
        let (directory, journal) = try journal { folder in
            volumeID = try LocalTransferResource(url: folder).volumeID
            return [try savedRecord(from: folder, volumeID: try #require(volumeID), endedAt: now)]
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("A001", isDirectory: true)
        let backup = directory.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let (surface, host, builder) = arranged(journal: journal, cardURL: folder)
        host.registerCard(card(media: MediaIncarnation(volumeIdentity: try #require(volumeID), mountGeneration: 1)),
                          url: folder, registeredAt: mountedAt)
        surface.queueSessionRecordIDs = Set(journal.records.map(\.id))
        #expect(builder.snapshot(now: now).safetyClaim != nil)

        // The card is queued again (more was shot onto it), then runs.
        let newer = try journal.enqueue(sourceURL: folder, destinationURLs: [backup], verificationMode: .standard,
                                        cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(),
                                        generateASCMHL: false)
        surface.queueSessionRecordIDs.insert(newer)
        #expect(builder.snapshot(now: now).safetyClaim == nil)
        try journal.markRunning(id: newer)

        #expect(journal.records.first { $0.id == newer }?.state == .running)
        #expect(builder.snapshot(now: now).safetyClaim == nil)
    }

    @Test func aClaimRequiresAQueueSessionRecord() throws {
        let (directory, journal) = try journal { folder in
            [try savedRecord(from: folder, volumeID: media.volumeIdentity, endedAt: now)]
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let (surface, _, builder) = arranged(journal: journal, cardURL: directory.appendingPathComponent("A001", isDirectory: true))

        // In History only: the Mac shows it as a past result, not as this card's verdict.
        #expect(builder.snapshot(now: now).safetyClaim == nil)

        surface.queueSessionRecordIDs = Set(journal.records.map(\.id))
        #expect(builder.snapshot(now: now).safetyClaim != nil)
    }

    @Test func queueRowsFollowTheMacsRunOrderAndAReorderBumpsTheQueue() throws {
        var ids: [UUID] = []
        let (directory, journal) = try journal { folder in
            let records = try (0..<3).map { _ in try savedRecord(from: folder, volumeID: "v", endedAt: now) }
            ids = records.map(\.id)
            return records
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let (surface, _, builder) = arranged(journal: journal)
        surface.queueSessionRecordIDs = Set(ids)
        // The third record is in the session but not in the run order.
        surface.queueSessionRecordOrder = [ids[1], ids[0]]
        let first = builder.snapshot(now: now)
        #expect(first.queue.map(\.recordID) == [ids[1], ids[0], ids[2]])

        surface.queueSessionRecordOrder = [ids[0], ids[1]]
        let update = try #require(builder.patch(from: first, now: now.addingTimeInterval(5)))

        #expect(update.snapshotPatch.queue?.map(\.recordID) == [ids[0], ids[1], ids[2]])
        #expect(update.snapshotPatch.revisions.queue == first.revisions.queue + 1)
    }

    @Test func aClaimThatDisappearsIsClearedInThePatch() throws {
        let (directory, journal) = try journal { folder in
            [try savedRecord(from: folder, volumeID: media.volumeIdentity, endedAt: now)]
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let (surface, _, builder) = arranged(journal: journal, cardURL: directory.appendingPathComponent("A001", isDirectory: true))
        surface.queueSessionRecordIDs = Set(journal.records.map(\.id))
        let first = builder.snapshot(now: now)
        #expect(first.safetyClaim != nil)
        surface.sourceURL = nil

        let update = try #require(builder.patch(from: first, now: now.addingTimeInterval(5)))

        #expect(update.snapshotPatch.safetyClaim == .set(nil))
        #expect(update.snapshotPatch.selectedCardID == .set(nil))
    }
}
