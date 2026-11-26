import Combine
import Foundation
import Synchronization
import Testing
import BitMatchEngine
@testable import BitMatch

/// One end of an in-process connection. `send` hands the envelope, round-tripped
/// through JSON as a transport would, to the other end's `incoming`; `received`
/// keeps everything this end was handed, whether or not anyone consumed it.
final class InMemoryRemoteLink: RemoteLink {
    private final class Inbox: Sendable {
        let stream: AsyncStream<RemoteEnvelope>
        let continuation: AsyncStream<RemoteEnvelope>.Continuation
        let received = Mutex<[RemoteEnvelope]>([])

        init() { (stream, continuation) = AsyncStream.makeStream() }

        func deliver(_ envelope: RemoteEnvelope) {
            received.withLock { $0.append(envelope) }
            continuation.yield(envelope)
        }
    }

    private struct Settings {
        var dropNextReply = false
        var delay: Duration = .zero
    }

    private let inbox: Inbox
    private let outbox: Inbox
    private let settings = Mutex(Settings())

    private init(inbox: Inbox, outbox: Inbox) {
        self.inbox = inbox
        self.outbox = outbox
    }

    static func pair() -> (host: InMemoryRemoteLink, client: InMemoryRemoteLink) {
        let hostInbox = Inbox(), clientInbox = Inbox()
        return (InMemoryRemoteLink(inbox: hostInbox, outbox: clientInbox),
                InMemoryRemoteLink(inbox: clientInbox, outbox: hostInbox))
    }

    var incoming: AsyncStream<RemoteEnvelope> { inbox.stream }
    var received: [RemoteEnvelope] { inbox.received.withLock { $0 } }

    /// The next `.outcome` this end sends is lost.
    var dropNextReply: Bool {
        get { settings.withLock { $0.dropNextReply } }
        set { settings.withLock { $0.dropNextReply = newValue } }
    }

    /// How long each envelope this end sends takes to arrive.
    var delay: Duration {
        get { settings.withLock { $0.delay } }
        set { settings.withLock { $0.delay = newValue } }
    }

    func send(_ envelope: RemoteEnvelope) async throws {
        let isReply: Bool
        if case .outcome = envelope.message { isReply = true } else { isReply = false }
        let (drop, delay) = settings.withLock { settings -> (Bool, Duration) in
            let drop = isReply && settings.dropNextReply
            if drop { settings.dropNextReply = false }
            return (drop, settings.delay)
        }
        if drop { return }
        if delay > .zero { try await Task.sleep(for: delay) }
        let wire = try JSONEncoder().encode(envelope)
        outbox.deliver(try JSONDecoder().decode(RemoteEnvelope.self, from: wire))
    }

    /// Ends the other end's `incoming`, as a dropped connection does.
    func close() { outbox.continuation.finish() }
}

/// Time that moves only when a test says so. Each scheduled action runs when
/// `advance` passes its time, in time order.
@MainActor
final class ManualRemoteScheduler: RemoteScheduler {
    private struct Entry {
        let id: Int
        let due: Date
        let action: @MainActor () -> Void
    }

    private let clock: Mutex<Date>
    private var entries: [Entry] = []
    private var nextID = 0

    init(start: Date) { clock = Mutex(start) }

    nonisolated var now: Date { clock.withLock { $0 } }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> RemoteScheduledAction {
        nextID += 1
        let id = nextID
        entries.append(Entry(id: id, due: now.addingTimeInterval(delay), action: action))
        return RemoteScheduledAction { [weak self] in self?.entries.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = entries.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            entries.removeAll { $0.id == next.id }
            clock.withLock { $0 = next.due }
            next.action()
        }
        clock.withLock { $0 = target }
    }
}

/// Holds a suspended intent until the test opens it.
@MainActor
private final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

/// Yields to the main actor until `condition` holds; false after five seconds.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

/// Lets anything already queued run, so a test can check nothing more arrived.
@MainActor
private func settle() async {
    for _ in 0..<200 { await Task.yield() }
}

@MainActor
@Suite struct RemoteInProcessTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let media = MediaIncarnation(volumeIdentity: "vol-a001", mountGeneration: 1)

    private struct Harness {
        let directory: URL
        let card: URL
        let raid: URL
        let shuttle: URL
        let surface: FakeRemoteSurface
        let host: RemoteHostState
        let admission: RemoteAdmissionStore
        let scheduler: ManualRemoteScheduler
        let hostCore: RemoteHostCore
        let view: RemoteCoordinatorView
        let clientCore: RemoteClientCore
        let hostEnd: InMemoryRemoteLink
        let clientEnd: InMemoryRemoteLink
        let session = SessionID()
        let client: ClientID

        @MainActor
        func connect() async throws {
            hostCore.attach(hostEnd, session: session)
            clientCore.start()
            try #require(await eventually { view.snapshot != nil })
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteInProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func admissionsFile(in directory: URL) -> URL {
        directory.appendingPathComponent("admissions.json")
    }

    /// A Mac with card "card-1" selected and backup "backup-1" of two chosen,
    /// and an iPad ready to connect to it, both on the same hand-driven clock.
    private func makeHarness(
        directory: URL? = nil,
        retention: TimeInterval = 24 * 3600,
        records: (URL) throws -> [LocalTransferRecord] = { _ in [] }
    ) throws -> Harness {
        let directory = try directory ?? makeDirectory()
        let folders = try ["A001", "RAID", "Shuttle"].map { name in
            let url = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let (card, raid, shuttle) = (folders[0], folders[1], folders[2])
        let journalFile = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode(try records(card)).write(to: journalFile)

        let surface = FakeRemoteSurface(journal: LocalTransferJournal(fileURL: journalFile))
        surface.sourceURL = card
        surface.destinationURLs = [raid]
        let host = RemoteHostState()
        host.registerCard(RemoteCardSummary(id: "card-1", name: "A001", capacityBytes: nil, detectedCamera: nil,
                                            hasAccess: true, media: media), url: card)
        host.registerBackup(RemoteBackupSummary(id: "backup-1", name: "RAID", freeBytes: nil, policyVerdict: "ok"),
                            url: raid)
        host.registerBackup(RemoteBackupSummary(id: "backup-2", name: "Shuttle", freeBytes: nil, policyVerdict: "ok"),
                            url: shuttle)

        let scheduler = ManualRemoteScheduler(start: start)
        let now: @Sendable () -> Date = { [scheduler] in scheduler.now }
        let admission = try RemoteAdmissionStore(fileURL: admissionsFile(in: directory), now: now, retention: retention)
        let hostCore = RemoteHostCore(surface: surface, host: host, admission: admission, hostName: "Studio Mac",
                                      scheduler: scheduler, now: now)
        let (hostEnd, clientEnd) = InMemoryRemoteLink.pair()
        let view = RemoteCoordinatorView()
        let client = ClientID()
        let clientCore = RemoteClientCore(view: view, link: clientEnd, client: client, scheduler: scheduler, now: now)
        return Harness(directory: directory, card: card, raid: raid, shuttle: shuttle, surface: surface, host: host,
                       admission: admission, scheduler: scheduler, hostCore: hostCore, view: view,
                       clientCore: clientCore, hostEnd: hostEnd, clientEnd: clientEnd, client: client)
    }

    /// A finished record of `card` saved under this card's volume identity.
    private func savedRecord(from card: URL, endedAt: Date) throws -> LocalTransferRecord {
        let real = try LocalTransferResource(url: card)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(real)) as? [String: Any])
        object["volumeID"] = media.volumeIdentity
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

    private func kinds(_ link: InMemoryRemoteLink) -> [String] {
        link.received.map {
            switch $0.message {
            case .snapshot: "snapshot"
            case .update: "update"
            case .progress: "progress"
            case .heartbeat: "heartbeat"
            case .command: "command"
            case .outcome: "outcome"
            }
        }
    }

    private func outcomes(_ link: InMemoryRemoteLink) -> [RequestID: RemoteCommandOutcome] {
        var found: [RequestID: RemoteCommandOutcome] = [:]
        for envelope in link.received {
            if case .outcome(let request, let outcome) = envelope.message { found[request] = outcome }
        }
        return found
    }

    // MARK: - State

    @Test func attachingSendsASnapshotAndTheViewMirrorsTheSurface() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }

        try await h.connect()

        #expect(kinds(h.clientEnd) == ["snapshot"])
        let snapshot = try #require(h.view.snapshot)
        #expect(snapshot.host == h.host.id)
        #expect(snapshot.session == h.session)
        #expect(snapshot.hostName == "Studio Mac")
        #expect(snapshot.revisions == h.host.revisions)
        #expect(snapshot.selectedCardID == "card-1")
        #expect(snapshot.selectedBackupIDs == ["backup-1"])
        #expect(snapshot.backups.map(\.id) == ["backup-1", "backup-2"])
        #expect(h.view.verificationMode == h.surface.verificationMode)
        #expect(h.view.connection == .live)

        h.hostEnd.close()

        #expect(await eventually { h.view.connection == .disconnected })
    }

    @Test func aSurfaceChangeArrivesAsAnUpdateNotASnapshot() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try await h.connect()
        let before = try #require(h.view.snapshot).revisions

        // Two changes in one main-actor turn, announced as `@Published`
        // announces them: before the value changes.
        h.surface.objectWillChange.send()
        h.surface.destinationURLs = [h.shuttle]
        h.surface.objectWillChange.send()
        h.surface.verificationMode = .paranoid

        #expect(await eventually { h.view.snapshot?.revisions.state == before.state + 1 })
        await settle()
        #expect(kinds(h.clientEnd) == ["snapshot", "update"])
        #expect(h.view.snapshot?.selectedBackupIDs == ["backup-2"])
        #expect(h.view.verificationMode == .paranoid)
        #expect(h.view.snapshot?.revisions == h.host.revisions)
    }

    // MARK: - Commands

    @Test func aLostReplyThenRetryReturnsTheOriginalOutcomeAndRunsOnce() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try await h.connect()
        let settingsRevision = try #require(h.view.snapshot).revisions.settings
        h.hostEnd.dropNextReply = true

        let first = Task { await h.view.saveVerificationMode(.paranoid) }
        #expect(await eventually { h.surface.calls.contains(.saveVerificationMode) && !h.hostEnd.dropNextReply })
        h.scheduler.advance(by: 10)

        #expect(await first.value == .unknown(reason: RemoteClientCore.noReplyReason))
        let request = try #require(h.clientCore.unansweredRequests.first)

        let retried = await h.clientCore.retry(request)

        guard case .done(let result) = retried else {
            Issue.record("expected done, got \(retried)")
            return
        }
        #expect(result.request == request)
        // The retry carried the original content: the Mac answers it with the outcome it recorded.
        let hash = RemoteCommand.contentHash(of: .setVerificationMode(.paranoid, settingsRevision: settingsRevision))
        #expect(try h.admission.admit(client: h.client, request: request, contentHash: hash) == .duplicateDone(retried))
        #expect(h.surface.calls.filter { $0 == .saveVerificationMode }.count == 1)
        #expect(h.clientCore.unansweredRequests.isEmpty)
    }

    @Test func aDuplicateInFlightCommandOverTheLinkSeesPending() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try await h.connect()
        let gate = Gate()
        h.surface.startHook = { await gate.wait() }

        let first = Task { await h.view.startSetupTransfersPrepared() }
        #expect(await eventually { h.surface.calls.contains(.start) })
        h.scheduler.advance(by: 10)
        #expect(await first.value == .unknown(reason: RemoteClientCore.noReplyReason))
        let request = try #require(h.clientCore.unansweredRequests.first)

        // The same request again while the Mac is still starting it.
        #expect(await h.clientCore.retry(request) == .pending)
        #expect(h.clientCore.unansweredRequests == [request])

        gate.open()

        // The first run's own reply arrives and closes the request.
        #expect(await eventually { h.clientCore.unansweredRequests.isEmpty })
        #expect(h.surface.calls.filter { $0 == .start }.count == 1)
    }

    @Test func pendingAdmissionsAtLaunchBecomeUnknownUnlessProved() async throws {
        let directory = try makeDirectory()
        let client = ClientID(), proved = RequestID(), unproved = RequestID()
        let provedBody = RemoteCommandBody.startQueue(queueRevision: 0)
        let unprovedBody = RemoteCommandBody.enqueue(selectionRevision: 0)
        do {
            // The Mac admitted both, then quit before either finished.
            let before = try RemoteAdmissionStore(fileURL: admissionsFile(in: directory))
            _ = try before.admit(client: client, request: proved, contentHash: RemoteCommand.contentHash(of: provedBody))
            _ = try before.admit(client: client, request: unproved,
                                 contentHash: RemoteCommand.contentHash(of: unprovedBody))
        }
        let h = try makeHarness(directory: directory)
        defer { try? FileManager.default.removeItem(at: h.directory) }
        #expect(Set(h.admission.pendingAtLoad().map { $0.1 }) == [proved, unproved])
        let provedOutcome = RemoteCommandOutcome.done(RemoteCommandResult(request: proved, revisions: h.host.revisions))

        h.hostCore.reconcilePendingAtLaunch { _, request in request == proved ? provedOutcome : nil }

        // The iPad asks again about both over the link.
        h.hostCore.attach(h.hostEnd, session: h.session)
        for (request, body) in [(proved, provedBody), (unproved, unprovedBody)] {
            let command = RemoteCommand(client: client, request: request, session: h.session, body: body)
            try await h.clientEnd.send(RemoteEnvelope(message: .command(command)))
        }
        #expect(await eventually { outcomes(h.clientEnd).count == 2 })
        #expect(outcomes(h.clientEnd)[proved] == provedOutcome)
        #expect(outcomes(h.clientEnd)[unproved] == .unknown(reason: RemoteHostCore.restartedReason))
        #expect(h.surface.calls.isEmpty)
    }

    @Test func aStaleSelectionRevisionIsRejectedWithTheCurrentOne() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        try await h.connect()
        let seen = try #require(h.view.snapshot).revisions.selection

        // The Mac's selection changes; its update is still on the way when the iPad acts.
        h.hostEnd.delay = .milliseconds(200)
        h.surface.objectWillChange.send()
        h.surface.destinationURLs = [h.raid, h.shuttle]
        #expect(await eventually { h.host.revisions.selection == seen + 1 })
        #expect(h.view.snapshot?.revisions.selection == seen)

        let outcome = await h.view.applyPreparedSource(cardID: "card-1")

        #expect(outcome == .rejected(.staleRevision(current: h.host.revisions)))
        #expect(h.surface.calls.isEmpty)
        #expect(h.view.snapshot?.revisions.selection == seen + 1)
    }

    /// The host also purges finished admissions on each heartbeat, keeping
    /// those of clients still attached.
    @Test func heartbeatsKeepTheClaimAndSilenceDropsIt() async throws {
        let h = try makeHarness(retention: 5) { card in [try savedRecord(from: card, endedAt: start)] }
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let other = ClientID(), otherRequest = RequestID(), ownRequest = RequestID()
        for (client, request) in [(other, otherRequest), (h.client, ownRequest)] {
            _ = try h.admission.admit(client: client, request: request, contentHash: "hash")
            try h.admission.complete(client: client, request: request, outcome: .rejected(.unauthorized))
        }
        try await h.connect()
        _ = await h.view.saveVerificationMode(.thorough) // the Mac learns this client's ID
        let claim = try #require(h.view.currentSafetyClaim(at: h.scheduler.now))

        // Twenty seconds, twice the lease, on heartbeats alone.
        for tick in 1...10 {
            h.scheduler.advance(by: 2)
            #expect(await eventually { kinds(h.clientEnd).filter { $0 == "heartbeat" }.count == tick })
            #expect(h.view.currentSafetyClaim(at: h.scheduler.now) == claim)
        }
        #expect(try h.admission.admit(client: other, request: otherRequest, contentHash: "hash") == .admitted)
        #expect(try h.admission.admit(client: h.client, request: ownRequest, contentHash: "hash")
                == .duplicateDone(.rejected(.unauthorized)))

        // The Mac goes quiet.
        h.hostCore.detach(session: h.session)
        h.scheduler.advance(by: 11)

        #expect(h.view.currentSafetyClaim(at: h.scheduler.now) == nil)
        h.clientCore.stop()
        #expect(h.view.connection == .disconnected)
    }

    @Test func anUndecodableCommandIsRejectedWhenItsRequestCanBeRead() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        h.hostCore.attach(h.hostEnd, session: h.session)
        let request = RequestID()
        let command = RemoteCommand(client: h.client, request: request, session: h.session,
                                    body: .startQueue(queueRevision: 0))
        let encoded = try JSONEncoder().encode(RemoteEnvelope(message: .command(command)))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["version"] = RemoteProtocolVersion.current + 1

        h.hostCore.receive(encoded: try JSONSerialization.data(withJSONObject: object), session: h.session)
        h.hostCore.receive(encoded: Data("not a message".utf8), session: h.session)

        #expect(await eventually { outcomes(h.clientEnd).count == 1 })
        await settle()
        #expect(kinds(h.clientEnd) == ["snapshot", "outcome"])
        #expect(outcomes(h.clientEnd)[request] == .rejected(.contentMismatch))
        #expect(h.surface.calls.isEmpty)
    }
}
