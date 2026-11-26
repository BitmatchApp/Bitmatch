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

    private func registerCard(_ host: RemoteHostState) {
        host.registerCard(
            RemoteCardSummary(id: "card-1", name: "A001", capacityBytes: 64_000_000_000,
                              detectedCamera: nil, hasAccess: true, media: media),
            url: URL(fileURLWithPath: "/Volumes/A001")
        )
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
        while gate == nil { await Task.yield() }
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
        registerCard(h.host)
        let remounted = MediaIncarnation(volumeIdentity: "VOL-A", mountGeneration: 2)

        let outcome = await h.executor.execute(command(.eject(cardID: "card-1", media: remounted, recordID: UUID())))

        #expect(outcome == .rejected(.mediaChanged))
        #expect(!asked)
        #expect(h.surface.calls.isEmpty)
    }

    @Test func ejectWhenNotSafeIsRefusedWithTheWording() async throws {
        var asked: (UUID, MediaIncarnation)?
        let h = try makeHarness(safeToErase: { asked = ($0, $1); return false })
        defer { try? FileManager.default.removeItem(at: h.directory) }
        registerCard(h.host)
        let recordID = UUID()

        let outcome = await h.executor.execute(command(.eject(cardID: "card-1", media: media, recordID: recordID)))

        #expect(outcome == .rejected(.notSafeToErase(wording: RemoteCommandExecutor.notSafeToEraseWording)))
        #expect(asked?.0 == recordID)
        #expect(asked?.1 == media)
        #expect(h.surface.calls.isEmpty)
    }

    @Test func aRevisionThatMovesDuringAnIntentEndsAsUnknown() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        h.surface.startHook = { h.host.revisions.selection += 1 }
        let start = command(.start(selectionRevision: 3))

        let outcome = await h.executor.execute(start)

        #expect(outcome == .unknown(reason: "state changed during execution"))
        #expect(await h.executor.execute(start) == outcome)
        #expect(h.surface.calls == [.start])
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
