import Foundation
import BitMatchEngine

/// Runs remote commands against the coordinator's intents. Every command is
/// admitted first, so a duplicate never runs twice. Its revision and identity
/// checks happen in the same main-actor turn as the intent call. The outcome
/// is what the intent itself reports (its return value, its error, or, for
/// intents that return nothing, a postcondition read right after it), and it
/// is recorded in the admission store before it is returned. `.done` carries
/// the revisions read after the intent, so a client reconciles any concurrent
/// change from the next snapshot.
@MainActor
final class RemoteCommandExecutor {
    static let notSafeToEraseWording = "This card is not safe to erase yet."
    static let unrecordedOutcome = "the outcome could not be recorded; check the Mac"

    private let surface: any RemoteSurface
    private let host: RemoteHostState
    private let admission: RemoteAdmissionStore
    private let safeToErase: @MainActor (UUID, MediaIncarnation) -> Bool

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
        } catch is FlushAfterPublishFailure {
            // The outcome reached the file; only the folder flush is unconfirmed.
            SharedLogger.error("Remote command \(command.request.rawValue) outcome was written but not confirmed flushed")
        } catch {
            SharedLogger.error("Remote command \(command.request.rawValue) outcome was not recorded: \(error)")
            return .unknown(reason: Self.unrecordedOutcome)
        }
        return outcome
    }

    // MARK: - Bodies

    private func run(_ body: RemoteCommandBody, request: RequestID) async -> RemoteCommandOutcome {
        switch body {
        case .selectSource(let cardID, let revision):
            guard revision == host.revisions.selection else { return stale() }
            guard let url = host.url(forCard: cardID) else { return refused("unknown card/backup") }
            guard surface.applyPreparedSource(expectedSource: surface.sourceURL,
                                              expectedDestinations: surface.destinationURLs,
                                              newSource: url) else {
                return refused("selection is locked")
            }
            return done(request)

        case .setDestinations(let backupIDs, let revision):
            guard revision == host.revisions.selection else { return stale() }
            return setDestinations(backupIDs, request: request)

        case .setVerificationMode(let mode, let revision):
            guard revision == host.revisions.settings else { return stale() }
            surface.verificationMode = mode
            surface.saveVerificationMode()
            return done(request)

        case .start(let revision):
            guard revision == host.revisions.selection else { return stale() }
            let enqueued: UUID?
            do {
                enqueued = try await surface.startSetupTransfersPrepared()
            } catch {
                return refused(error.localizedDescription)
            }
            // The intent returns normally even when `startQueue()` refused to run.
            guard surface.queueIsRunning else {
                let reason = surface.queueMessage ?? "no reason given"
                return enqueued == nil ? refused("the queue did not start: \(reason)")
                                       : .unknown(reason: "enqueued; the queue did not start: \(reason)")
            }
            return done(request)

        case .enqueue(let revision):
            guard revision == host.revisions.selection else { return stale() }
            do {
                _ = try await surface.enqueueSelectionPrepared()
            } catch {
                return refused(error.localizedDescription)
            }
            return done(request)

        case .startQueue(let revision):
            guard revision == host.revisions.queue else { return stale() }
            surface.startQueue()
            guard surface.queueIsRunning else { return refused(surface.queueMessage ?? "the queue did not start") }
            return done(request)

        case .pause(let operationID):
            guard surface.stateService.currentOperationId == operationID else { return refused("no such operation") }
            await surface.pauseOperation(reason: .userRequested)
            guard surface.stateService.currentOperationId == operationID,
                  surface.stateService.currentState.isPaused else { return refused("the operation did not pause") }
            return done(request)

        case .resume(let operationID):
            guard surface.stateService.currentOperationId == operationID else { return refused("no such operation") }
            guard surface.stateService.currentState.isPaused else { return refused("operation is not paused") }
            await surface.resumeOperation()
            guard surface.stateService.currentOperationId == operationID,
                  !surface.stateService.currentState.isPaused else { return refused("the operation did not resume") }
            return done(request)

        case .cancel(let operationID):
            guard surface.cancelOperation(ifCurrentTargetID: operationID, origin: .remote) else {
                return refused("no such operation")
            }
            return done(request)

        case .retry(let recordID, let revision):
            guard revision == host.revisions.queue else { return stale() }
            guard let record = surface.transferJournal.records.first(where: { $0.id == recordID }) else {
                return refused("no such record")
            }
            // A project retry rewrites the selection without queuing an
            // attempt, so its effect could not be reported as done or refused.
            guard record.projectID == nil else { return .rejected(.unsupported(wording: "project retry is a later slice")) }
            let attemptsBefore = retryAttempts(of: recordID)
            await surface.retryTransferPrepared(recordID, generateASCMHL: nil)
            guard retryAttempts(of: recordID) > attemptsBefore else {
                return refused(surface.queueMessage ?? "no retry attempt was queued")
            }
            return done(request)

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
            // The coordinator moves only waiting cards, by their index among
            // waiting cards, so positions count waiting records only.
            let waiting = recordIDs.filter { id in
                surface.transferJournal.records.contains { $0.id == id && $0.state == .queued }
            }
            for (index, id) in waiting.enumerated() {
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

    /// Backup order is not part of the contract: the result is compared as a
    /// set. A current backup with no registered ID is one the client never
    /// saw, so it is kept rather than removed.
    private func setDestinations(_ backupIDs: [String], request: RequestID) -> RemoteCommandOutcome {
        var target: [URL] = []
        for id in backupIDs {
            guard let url = host.url(forBackup: id) else { return refused("unknown card/backup") }
            target.append(url)
        }
        let original = surface.destinationURLs
        let registered = Set(host.backups.keys.compactMap { host.url(forBackup: $0)?.standardizedFileURL.path })
        target += original.filter { !registered.contains($0.standardizedFileURL.path) && !target.contains($0) }
        var refusal: String?
        for url in original where !target.contains(url) {
            surface.removeDestinationFolder(url)
        }
        for url in target where !original.contains(url) {
            if let message = surface.addDestination(url, origin: .userChoice, facts: BackupTargetPolicy.VolumeFacts.read) {
                refusal = refusal ?? message
            }
        }
        let final = Set(surface.destinationURLs)
        if final == Set(target) { return done(request) }
        if final == Set(original) { return refused(refusal ?? "selection is locked") }
        return .unknown(reason: "backups partly changed: \(refusal ?? "selection is locked")")
    }

    private func retryAttempts(of recordID: UUID) -> Int {
        surface.transferJournal.records.filter { $0.retryOf == recordID }.count
    }

    private func eject(cardID: String, media: MediaIncarnation, recordID: UUID,
                       request: RequestID) async -> RemoteCommandOutcome {
        #if os(macOS)
        guard let cardURL = host.url(forCard: cardID), host.media(forCard: cardID) == media else {
            return .rejected(.mediaChanged)
        }
        guard let record = surface.transferJournal.records.first(where: { $0.id == recordID }),
              Self.isInside(record.source.url, cardURL) else {
            return refused("record does not belong to that card")
        }
        guard safeToErase(recordID, media) else {
            return .rejected(.notSafeToErase(wording: Self.notSafeToEraseWording))
        }
        // `ejectQueueSource` answers nil for a card already unmounting, the
        // same as success. Checked in the same turn as the call, so nil below
        // means this call did the eject.
        guard !surface.ejectingQueueSourceIDs.contains(recordID) else { return refused("eject already in progress") }
        if let failure = await surface.ejectQueueSource(recordID, using: { await CardEjectService.eject($0) }) {
            return refused(failure)
        }
        return done(request)
        #else
        return .rejected(.unsupported(wording: "eject is Mac-only"))
        #endif
    }

    /// True when `source` is `card` or a folder inside it, compared by whole
    /// path components so "/Volumes/A0010" is not inside "/Volumes/A001".
    static func isInside(_ source: URL, _ card: URL) -> Bool {
        let sourceParts = source.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let cardParts = card.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return sourceParts.starts(with: cardParts)
    }

    // MARK: - Outcomes

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
