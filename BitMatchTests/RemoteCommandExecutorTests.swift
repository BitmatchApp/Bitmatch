import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

@MainActor
struct RemoteCommandExecutorTests {
    private struct Harness {
        let directory: URL
        let surface: FakeRemoteSurface
        let host: RemoteHostState
        let admission: RemoteAdmissionStore
        let executor: RemoteCommandExecutor
    }

    private func makeHarness(
        revisions: ResourceRevisions = ResourceRevisions(selection: 3, queue: 2, operation: 1, settings: 1, state: 7),
        safeToErase: @escaping @MainActor (UUID, MediaIncarnation) -> Bool = { _, _ in true }
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteCommandExecutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let surface = FakeRemoteSurface()
        let host = RemoteHostState(revisions: revisions)
        let admission = try RemoteAdmissionStore(fileURL: directory.appendingPathComponent("admissions.json"))
        let executor = RemoteCommandExecutor(surface: surface, host: host, admission: admission, safeToErase: safeToErase)
        return Harness(directory: directory, surface: surface, host: host, admission: admission, executor: executor)
    }

    private func command(_ body: RemoteCommandBody, client: ClientID = ClientID()) -> RemoteCommand {
        RemoteCommand(client: client, request: RequestID(), session: SessionID(), body: body)
    }

    private func done(_ command: RemoteCommand, _ host: RemoteHostState) -> RemoteCommandOutcome {
        .done(RemoteCommandResult(request: command.request, revisions: host.revisions, payload: nil))
    }

    private let media = MediaIncarnation(volumeIdentity: "VOL-A", mountGeneration: 1)

    /// A folder standing in for a mounted card, offered to remote clients as "card-1".
    private func registerCard(_ h: Harness, named name: String = "A001") throws -> URL {
        let url = try makeFolder(name, in: h)
        h.host.registerCard(
            RemoteCardSummary(id: "card-1", name: name, capacityBytes: 64_000_000_000,
                              detectedCamera: nil, hasAccess: true, media: media),
            url: url, registeredAt: Date()
        )
        return url
    }

    @Test func selectSourceGoesThroughThePreparedIntent() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let card = try registerCard(h)
        let select = command(.selectSource(cardID: "card-1", selectionRevision: 3))

        let outcome = await h.executor.execute(select)

        #expect(outcome == done(select, h.host))
        #expect(h.surface.calls == [.chooseSourcePrepared(card)])
        #expect(h.surface.sourceURL == card)

        // A refusal from the Mac's own selection rules is the outcome.
        h.surface.sourceURL = nil
        h.surface.selectionRefusals = ["This card is already staged."]
        let refused = await h.executor.execute(command(.selectSource(cardID: "card-1", selectionRevision: 3)))
        #expect(refused == .rejected(.hostRefused(wording: "This card is already staged.")))
        #expect(h.surface.sourceURL == nil)

        // A lock the intent skips silently is refused, not reported done.
        h.surface.selectionRefusals = []
        h.surface.selectionLocked = true
        let locked = await h.executor.execute(command(.selectSource(cardID: "card-1", selectionRevision: 3)))
        #expect(locked == .rejected(.hostRefused(wording: RemoteCommandExecutor.selectionLockedWording)))
    }

    @Test func setDestinationsGoesThroughThePreparedIntent() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let raid = URL(fileURLWithPath: "/Volumes/RAID/Shoot", isDirectory: true)
        let shuttle = URL(fileURLWithPath: "/Volumes/Shuttle/Shoot", isDirectory: true)
        h.host.registerBackup(RemoteBackupSummary(id: "backup-1", name: "RAID", freeBytes: nil, policyVerdict: "ok"), url: raid)
        h.host.registerBackup(RemoteBackupSummary(id: "backup-2", name: "Shuttle", freeBytes: nil, policyVerdict: "ok"), url: shuttle)
        h.surface.destinationURLs = [raid]
        let set = command(.setDestinations(backupIDs: ["backup-2"], selectionRevision: 3))

        let outcome = await h.executor.execute(set)

        #expect(outcome == done(set, h.host))
        #expect(h.surface.calls == [.removeDestination(raid), .addBackupsPrepared([shuttle])])
        #expect(h.surface.destinationURLs == [shuttle])

        h.surface.selectionRefusals = ["Choose a backup that is not on the card."]
        let refused = await h.executor.execute(command(.setDestinations(backupIDs: ["backup-1", "backup-2"],
                                                                        selectionRevision: 3)))
        #expect(refused == .rejected(.hostRefused(wording: "Choose a backup that is not on the card.")))
        #expect(h.surface.destinationURLs == [shuttle])
    }

    private func makeFolder(_ name: String, in h: Harness) throws -> URL {
        let url = h.directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A journal record whose source is `source`.
    private func record(from source: URL, in h: Harness) throws -> UUID {
        try h.surface.transferJournal.enqueue(
            sourceURL: source, destinationURLs: [try makeFolder("Backup-\(UUID().uuidString)", in: h)],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(), generateASCMHL: false
        )
    }

    @Test func aReorderCountsPositionsAmongWaitingCardsOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteReorder-\(UUID().uuidString)", isDirectory: true)
        let folder = directory.appendingPathComponent("A001", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resource = try LocalTransferResource(url: folder)
        let records: [LocalTransferRecord] = [LocalTransferState.completed, .running, .queued, .queued].map { state in
            var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: resource, destinations: [resource],
                                             verificationMode: .standard, cameraSettings: CameraLabelSettings(),
                                             reportSettings: ReportPrefs())
            record.state = state
            return record
        }
        let file = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode(records).write(to: file)
        let surface = FakeRemoteSurface(journal: LocalTransferJournal(fileURL: file))
        let host = RemoteHostState(revisions: ResourceRevisions(selection: 3, queue: 2, operation: 1, settings: 1, state: 7))
        let admission = try RemoteAdmissionStore(fileURL: directory.appendingPathComponent("admissions.json"))
        let executor = RemoteCommandExecutor(surface: surface, host: host, admission: admission, safeToErase: { _, _ in true })
        // The journal reopens a running record as interrupted; either way it is not waiting.
        let (finished, wasRunning, firstWaiting, secondWaiting) = (records[0].id, records[1].id, records[2].id, records[3].id)

        let reorder = command(.reorderQueue(recordIDs: [finished, wasRunning, secondWaiting, firstWaiting], queueRevision: 2))
        let outcome = await executor.execute(reorder)

        #expect(outcome == done(reorder, host))
        #expect(surface.calls == [.move(secondWaiting, 0), .move(firstWaiting, 1)])
    }

    @Test func setDestinationsKeepsABackupWithNoRegisteredID() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let unmanaged = URL(fileURLWithPath: "/Volumes/Unregistered/Shoot", isDirectory: true)
        let raid = URL(fileURLWithPath: "/Volumes/RAID/Shoot", isDirectory: true)
        h.host.registerBackup(RemoteBackupSummary(id: "backup-1", name: "RAID", freeBytes: nil, policyVerdict: "ok"), url: raid)
        h.surface.destinationURLs = [unmanaged]
        let set = command(.setDestinations(backupIDs: ["backup-1"], selectionRevision: 3))

        let outcome = await h.executor.execute(set)

        #expect(outcome == done(set, h.host))
        #expect(h.surface.calls == [.addBackupsPrepared([raid])])
        #expect(h.surface.destinationURLs == [unmanaged, raid])
    }

    @Test func startAtTheCurrentSelectionRevisionCallsTheSurfaceOnce() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let start = command(.start(selectionRevision: 3))

        let first = await h.executor.execute(start)
        let retry = await h.executor.execute(start)

        #expect(first == done(start, h.host))
        #expect(retry == first)
        #expect(h.surface.calls == [.start])
    }

    @Test func startAtAStaleRevisionIsRejectedWithTheCurrentRevisions() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let start = command(.start(selectionRevision: 2))

        let outcome = await h.executor.execute(start)

        #expect(outcome == .rejected(.staleRevision(current: h.host.revisions)))
        #expect(h.surface.calls.isEmpty)
        #expect(await h.executor.execute(start) == outcome)
    }

    @Test func aDuplicateInFlightStartReportsPendingAndRunsOnce() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        var gate: CheckedContinuation<Void, Never>?
        h.surface.startHook = { await withCheckedContinuation { gate = $0 } }
        let start = command(.start(selectionRevision: 3))

        let first = Task { await h.executor.execute(start) }
        var yields = 0
        while gate == nil && yields < 1000 {
            await Task.yield()
            yields += 1
        }
        #expect(gate != nil, "the start intent never suspended")
        let duplicate = await h.executor.execute(start)
        gate?.resume()
        let firstOutcome = await first.value

        #expect(duplicate == .pending)
        #expect(firstOutcome == done(start, h.host))
        #expect(await h.executor.execute(start) == firstOutcome)
        #expect(h.surface.calls == [.start])
    }

    @Test func ejectWithAChangedMediaIncarnationIsRefusedEvenWhenSafe() async throws {
        var asked = false
        let h = try makeHarness(safeToErase: { _, _ in asked = true; return true })
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let recordID = try record(from: try registerCard(h), in: h)
        let remounted = MediaIncarnation(volumeIdentity: "VOL-A", mountGeneration: 2)

        let outcome = await h.executor.execute(command(.eject(cardID: "card-1", media: remounted, recordID: recordID)))

        #expect(outcome == .rejected(.mediaChanged))
        #expect(!asked)
        #expect(h.surface.calls.isEmpty)
    }

    @Test func ejectWhenNotSafeIsRefusedWithTheWording() async throws {
        var asked: (UUID, MediaIncarnation)?
        let h = try makeHarness(safeToErase: { asked = ($0, $1); return false })
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let recordID = try record(from: try registerCard(h), in: h)

        let outcome = await h.executor.execute(command(.eject(cardID: "card-1", media: media, recordID: recordID)))

        #expect(outcome == .rejected(.notSafeToErase(wording: RemoteCommandExecutor.notSafeToEraseWording)))
        #expect(asked?.0 == recordID)
        #expect(asked?.1 == media)
        #expect(h.surface.calls.isEmpty)
    }

    @Test func ejectRefusesARecordThatDoesNotBelongToTheCard() async throws {
        var asked = false
        let h = try makeHarness(safeToErase: { _, _ in asked = true; return true })
        defer { try? FileManager.default.removeItem(at: h.directory) }
        _ = try registerCard(h)
        let otherCardRecord = try record(from: try makeFolder("B001", in: h), in: h)

        let outcome = await h.executor.execute(command(.eject(cardID: "card-1", media: media, recordID: otherCardRecord)))
        let missing = await h.executor.execute(command(.eject(cardID: "card-1", media: media, recordID: UUID())))

        #expect(outcome == .rejected(.hostRefused(wording: "record does not belong to that card")))
        #expect(missing == outcome)
        #expect(!asked)
        #expect(h.surface.calls.isEmpty)
    }

    @Test func ejectOfASafeCardEjectsItsRecord() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let recordID = try record(from: try registerCard(h), in: h)
        let eject = command(.eject(cardID: "card-1", media: media, recordID: recordID))

        let outcome = await h.executor.execute(eject)

        #expect(outcome == done(eject, h.host))
        #expect(h.surface.calls == [.eject(recordID)])
    }

    @Test func aSecondEjectWhileTheCardIsUnmountingIsRefused() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let recordID = try record(from: try registerCard(h), in: h)
        h.surface.ejectingQueueSourceIDs = [recordID]

        let outcome = await h.executor.execute(command(.eject(cardID: "card-1", media: media, recordID: recordID)))

        #expect(outcome == .rejected(.hostRefused(wording: "eject already in progress")))
        #expect(h.surface.calls.isEmpty)
    }

    @Test func aStartWhoseOwnEffectBumpsTheSelectionRevisionStillEndsDone() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        h.surface.startHook = { h.host.revisions.selection += 1 }
        let start = command(.start(selectionRevision: 3))

        let outcome = await h.executor.execute(start)

        #expect(h.host.revisions.selection == 4)
        #expect(outcome == done(start, h.host))
        #expect(await h.executor.execute(start) == outcome)
        #expect(h.surface.calls == [.start])
    }

    @Test func aPauseThatTheCoordinatorRefusesIsReportedAsRefused() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let operationID = UUID()
        h.surface.stateService.startOperation(id: operationID, sourceURL: h.directory, destinationURLs: [],
                                              totalFiles: 1, totalBytes: 1)

        let outcome = await h.executor.execute(command(.pause(operationID: operationID)))

        #expect(outcome == .rejected(.hostRefused(wording: "the operation did not pause")))
        #expect(h.surface.calls == [.pause])
    }

    @Test func aProjectRecordRetryIsRefusedBeforeAnyEffect() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let recordID = try h.surface.transferJournal.enqueue(
            sourceURL: try makeFolder("A001", in: h), destinationURLs: [try makeFolder("Backup", in: h)],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(), generateASCMHL: false, projectID: UUID()
        )

        let outcome = await h.executor.execute(command(.retry(recordID: recordID, queueRevision: 2)))

        #expect(outcome == .rejected(.unsupported(wording: "project retry is a later slice")))
        #expect(h.surface.calls.isEmpty)
    }

    @Test func aStartWhoseQueueDidNotRunIsReportedAsPartial() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        h.surface.startRunsQueue = false
        h.surface.queueMessage = "Resolve the paused card first."

        let outcome = await h.executor.execute(command(.start(selectionRevision: 3)))

        #expect(outcome == .unknown(reason: "enqueued; the queue did not start: Resolve the paused card first."))
        #expect(h.surface.calls == [.start])
    }

    @Test func aResumeOfAnUnpausedOperationIsRefused() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let operationID = UUID()
        h.surface.stateService.startOperation(id: operationID, sourceURL: h.directory, destinationURLs: [],
                                              totalFiles: 1, totalBytes: 1)

        let outcome = await h.executor.execute(command(.resume(operationID: operationID)))

        #expect(outcome == .rejected(.hostRefused(wording: "operation is not paused")))
        #expect(h.surface.calls.isEmpty)
    }

    @Test func ejectAcceptsARecordSourcedFromASubfolderOfTheCard() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let card = try registerCard(h)
        let dcim = card.appendingPathComponent("DCIM", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        let recordID = try record(from: dcim, in: h)
        _ = try makeFolder("A0010", in: h)
        let lookalikeID = try record(from: h.directory.appendingPathComponent("A0010", isDirectory: true), in: h)
        let eject = command(.eject(cardID: "card-1", media: media, recordID: recordID))

        let outcome = await h.executor.execute(eject)
        let lookalike = await h.executor.execute(command(.eject(cardID: "card-1", media: media, recordID: lookalikeID)))

        #expect(outcome == done(eject, h.host))
        #expect(lookalike == .rejected(.hostRefused(wording: "record does not belong to that card")))
        #expect(h.surface.calls == [.eject(recordID)])
    }

    @Test func cancelGoesThroughTheTargetCheckedIntent() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let operationID = UUID()
        h.surface.cancellationTargetID = operationID
        let cancel = command(.cancel(operationID: operationID))
        let cancelOther = command(.cancel(operationID: UUID()))

        let outcome = await h.executor.execute(cancel)
        let otherOutcome = await h.executor.execute(cancelOther)

        #expect(outcome == done(cancel, h.host))
        #expect(otherOutcome == .rejected(.hostRefused(wording: "no such operation")))
        #expect(h.surface.calls == [.cancel(operationID, .remote)])
    }
}
