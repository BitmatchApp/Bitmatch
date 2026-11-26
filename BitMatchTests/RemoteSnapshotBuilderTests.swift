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

    private func arranged() -> (FakeRemoteSurface, RemoteHostState, RemoteSnapshotBuilder) {
        let surface = FakeRemoteSurface()
        let host = RemoteHostState(revisions: ResourceRevisions(selection: 3, queue: 2, operation: 1, settings: 4, state: 9))
        host.registerCard(RemoteCardSummary(id: "card-1", name: "A001", capacityBytes: 64_000, detectedCamera: nil,
                                            hasAccess: true, media: media), url: cardURL)
        host.registerBackup(RemoteBackupSummary(id: "backup-1", name: "RAID", freeBytes: nil, policyVerdict: "ok"), url: raidURL)
        host.registerBackup(RemoteBackupSummary(id: "backup-2", name: "Shuttle", freeBytes: nil, policyVerdict: "ok"), url: shuttleURL)
        surface.sourceURL = cardURL
        surface.destinationURLs = [raidURL]
        let builder = RemoteSnapshotBuilder(surface: surface, host: host, hostName: "Studio Mac", session: session)
        return (surface, host, builder)
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
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!json.contains("Volumes"))
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
}
