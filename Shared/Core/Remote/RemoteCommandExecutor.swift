import Foundation
import BitMatchEngine

/// Runs remote commands against the coordinator's intents. Every command is
/// admitted first, so a duplicate never runs twice. Its revision and identity
/// checks happen in the same main-actor turn as the intent call, and it is
/// revalidated after every `await`. The outcome is recorded in the admission
/// store before it is returned.
@MainActor
final class RemoteCommandExecutor {
    static let changedDuringExecution = "state changed during execution"
    static let notSafeToEraseWording = "This card is not safe to erase yet."

    private let surface: any RemoteSurface
    private let host: RemoteHostState
    private let admission: RemoteAdmissionStore
    private let safeToErase: @MainActor (UUID, MediaIncarnation) -> Bool
    /// The coordinator answers a second eject of a card already unmounting
    /// with nil (success); a remote caller must hear "in progress" instead.
    private var ejectingRecordIDs: Set<UUID> = []

    init(surface: any RemoteSurface, host: RemoteHostState, admission: RemoteAdmissionStore,
         safeToErase: @escaping @MainActor (UUID, MediaIncarnation) -> Bool) {
        self.surface = surface
        self.host = host
        self.admission = admission
        self.safeToErase = safeToErase
    }

    func execute(_ command: RemoteCommand) async -> RemoteCommandOutcome {
        let admitted: RemoteAdmissionStore.Admission
        do {
            admitted = try admission.admit(client: command.client, request: command.request,
                                           contentHash: command.contentHash)
        } catch {
            SharedLogger.error("Remote command \(command.request.rawValue) was not admitted: \(error)")
            let outcome = RemoteCommandOutcome.rejected(.hostRefused(wording: "The Mac could not record this command."))
            // A write that failed after publishing leaves the entry pending;
            // record the refusal so a retry hears the same answer.
            try? admission.complete(client: command.client, request: command.request, outcome: outcome)
            return outcome
        }
        switch admitted {
        case .duplicatePending: return .pending
        case .duplicateDone(let outcome): return outcome
        case .contentMismatch: return .rejected(.contentMismatch)
        case .admitted: break
        }
        let outcome = await run(command.body, request: command.request)
        do {
            try admission.complete(client: command.client, request: command.request, outcome: outcome)
        } catch {
            SharedLogger.error("Remote command \(command.request.rawValue) outcome was not recorded: \(error)")
        }
        return outcome
    }

    // MARK: - Bodies

    private func run(_ body: RemoteCommandBody, request: RequestID) async -> RemoteCommandOutcome {
        switch body {
        case .selectSource(let cardID):
            guard let url = host.url(forCard: cardID) else { return refused("unknown card/backup") }
            guard surface.applyPreparedSource(expectedSource: surface.sourceURL,
                                              expectedDestinations: surface.destinationURLs,
                                              newSource: url) else {
                return refused("selection is locked")
            }
            return done(request)

        case .setDestinations(let backupIDs):
            return setDestinations(backupIDs, request: request)

        case .setVerificationMode(let mode):
            surface.verificationMode = mode
            surface.saveVerificationMode()
            return done(request)

        case .start(let revision):
            guard revision == host.revisions.selection else { return stale() }
            do {
                _ = try await surface.startSetupTransfersPrepared()
            } catch {
                return afterAwait(\.selection, was: revision) ?? refused(error.localizedDescription)
            }
            return afterAwait(\.selection, was: revision) ?? done(request)

        case .enqueue(let revision):
            guard revision == host.revisions.selection else { return stale() }
            do {
                _ = try await surface.enqueueSelectionPrepared()
            } catch {
                return afterAwait(\.selection, was: revision) ?? refused(error.localizedDescription)
            }
            return afterAwait(\.selection, was: revision) ?? done(request)

        case .startQueue(let revision):
            guard revision == host.revisions.queue else { return stale() }
            surface.startQueue()
            return done(request)

        case .pause(let operationID):
            guard surface.stateService.currentOperationId == operationID else { return refused("no such operation") }
            let revision = host.revisions.operation
            await surface.pauseOperation(reason: .userRequested)
            return afterAwait(\.operation, was: revision) ?? done(request)

        case .resume(let operationID):
            guard surface.stateService.currentOperationId == operationID else { return refused("no such operation") }
            let revision = host.revisions.operation
            await surface.resumeOperation()
            return afterAwait(\.operation, was: revision) ?? done(request)

        case .cancel(let operationID):
            guard surface.cancelOperation(ifCurrentTargetID: operationID, origin: .remote) else {
                return refused("no such operation")
            }
            return done(request)

        case .retry(let recordID):
            let revision = host.revisions.queue
            await surface.retryTransferPrepared(recordID, generateASCMHL: nil)
            return afterAwait(\.queue, was: revision) ?? done(request)

        case .removeQueued(let recordID, let revision):
            guard revision == host.revisions.queue else { return stale() }
            do {
                try surface.removeQueuedTransfer(recordID)
            } catch {
                return refused(error.localizedDescription)
            }
            return done(request)

        case .reorderQueue(let recordIDs, let revision):
            guard revision == host.revisions.queue else { return stale() }
            for (index, id) in recordIDs.enumerated() {
                do {
                    try surface.moveQueuedTransfer(id: id, to: index)
                } catch {
                    // Earlier moves already took effect; the order is now neither.
                    return index == 0 ? refused(error.localizedDescription)
                                      : .unknown(reason: "queue partly reordered: \(error.localizedDescription)")
                }
            }
            return done(request)

        case .eject(let cardID, let media, let recordID):
            return await eject(cardID: cardID, media: media, recordID: recordID, request: request)

        case .setSettings, .answerAppleDoubleReview, .requestExport, .pageHistory:
            return .rejected(.unsupported(wording: "later slice"))
        }
    }

    private func setDestinations(_ backupIDs: [String], request: RequestID) -> RemoteCommandOutcome {
        var target: [URL] = []
        for id in backupIDs {
            guard let url = host.url(forBackup: id) else { return refused("unknown card/backup") }
            target.append(url)
        }
        let original = surface.destinationURLs
        var refusal: String?
        for url in original where !target.contains(url) {
            surface.removeDestinationFolder(url)
        }
        for url in target where !original.contains(url) {
            if let message = surface.addDestination(url, origin: .userChoice, facts: BackupTargetPolicy.VolumeFacts.read) {
                refusal = refusal ?? message
            }
        }
        let final = surface.destinationURLs
        if Set(final) == Set(target) { return done(request) }
        if final == original { return refused(refusal ?? "selection is locked") }
        return .unknown(reason: "backups partly changed: \(refusal ?? "selection is locked")")
    }

    private func eject(cardID: String, media: MediaIncarnation, recordID: UUID,
                       request: RequestID) async -> RemoteCommandOutcome {
        #if os(macOS)
        guard host.media(forCard: cardID) == media else { return .rejected(.mediaChanged) }
        guard safeToErase(recordID, media) else {
            return .rejected(.notSafeToErase(wording: Self.notSafeToEraseWording))
        }
        guard ejectingRecordIDs.insert(recordID).inserted else { return refused("eject already in progress") }
        defer { ejectingRecordIDs.remove(recordID) }
        let revision = host.revisions.queue
        let failure = await surface.ejectQueueSource(recordID, using: { await CardEjectService.eject($0) })
        if let moved = afterAwait(\.queue, was: revision) { return moved }
        if let failure { return refused(failure) }
        return done(request)
        #else
        return .rejected(.unsupported(wording: "eject is Mac-only"))
        #endif
    }

    // MARK: - Outcomes

    /// After an `await`, a moved revision means the result can no longer be
    /// attributed to this command alone.
    private func afterAwait(_ resource: KeyPath<ResourceRevisions, Int>, was revision: Int) -> RemoteCommandOutcome? {
        host.revisions[keyPath: resource] == revision ? nil : .unknown(reason: Self.changedDuringExecution)
    }

    private func done(_ request: RequestID) -> RemoteCommandOutcome {
        .done(RemoteCommandResult(request: request, revisions: host.revisions, payload: nil))
    }

    private func stale() -> RemoteCommandOutcome {
        .rejected(.staleRevision(current: host.revisions))
    }

    private func refused(_ wording: String) -> RemoteCommandOutcome {
        .rejected(.hostRefused(wording: wording))
    }
}
