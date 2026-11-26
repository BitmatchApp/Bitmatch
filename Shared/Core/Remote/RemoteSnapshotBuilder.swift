import Foundation
import BitMatchEngine

/// Turns what the surface shows into the snapshot remote clients mirror, and
/// a later surface into an update against an earlier snapshot. Paths never
/// leave the Mac: cards and backups appear only under the opaque IDs that
/// `RemoteHostState` registered. Verdicts are never decided here: the safety
/// claim repeats the saved record's verdict exactly as the Mac shows it.
@MainActor
struct RemoteSnapshotBuilder {
    private let surface: any RemoteSurface
    private let host: RemoteHostState
    private let hostName: String
    private let session: SessionID

    init(surface: any RemoteSurface, host: RemoteHostState, hostName: String, session: SessionID) {
        self.surface = surface
        self.host = host
        self.hostName = hostName
        self.session = session
    }

    func snapshot(now: Date) -> RemoteSnapshot {
        make(revisions: host.revisions, now: now)
    }

    /// Nil when nothing a client sees has changed. Otherwise each changed
    /// field is set, the revision of each resource that changed is bumped
    /// (selection: cards, backups, selection and readiness; queue: rows and
    /// operation IDs; settings: settings and verification mode), `state`
    /// is bumped, and the new revisions are stored in `RemoteHostState`.
    func patch(from previous: RemoteSnapshot, now: Date) -> RemoteStateUpdate? {
        // Built at the previous revisions so an unchanged claim compares equal.
        let current = make(revisions: previous.revisions, now: now)
        var patch = RemoteSnapshotPatch(host: current.host, session: current.session,
                                        takenAt: now, revisions: previous.revisions)
        var selection = false, queue = false, settings = false, other = false

        if current.cards != previous.cards { patch.cards = current.cards; selection = true }
        if current.backups != previous.backups { patch.backups = current.backups; selection = true }
        if current.selectedCardID != previous.selectedCardID {
            patch.selectedCardID = .set(current.selectedCardID); selection = true
        }
        if current.selectedBackupIDs != previous.selectedBackupIDs {
            patch.selectedBackupIDs = current.selectedBackupIDs; selection = true
        }
        if current.readinessWording != previous.readinessWording {
            patch.readinessWording = current.readinessWording; selection = true
        }
        if current.readinessStatus != previous.readinessStatus {
            patch.readinessStatus = current.readinessStatus; selection = true
        }

        if current.queue != previous.queue { patch.queue = current.queue; queue = true }
        if current.operationID != previous.operationID {
            patch.operationID = .set(current.operationID); queue = true
        }
        if current.cancellationTargetID != previous.cancellationTargetID {
            patch.cancellationTargetID = .set(current.cancellationTargetID); queue = true
        }

        if current.settings != previous.settings { patch.settings = current.settings; settings = true }
        if current.verificationMode != previous.verificationMode {
            patch.verificationMode = current.verificationMode; settings = true
        }

        if current.hostName != previous.hostName { patch.hostName = current.hostName; other = true }
        if current.mode != previous.mode { patch.mode = current.mode; other = true }
        if current.outcome != previous.outcome { patch.outcome = .set(current.outcome); other = true }
        if current.appleDoubleReview != previous.appleDoubleReview {
            patch.appleDoubleReview = .set(current.appleDoubleReview); other = true
        }
        let claimChanged = current.safetyClaim != previous.safetyClaim

        guard selection || queue || settings || other || claimChanged else { return nil }

        var revisions = previous.revisions
        if selection { revisions.selection += 1 }
        if queue { revisions.queue += 1 }
        if settings { revisions.settings += 1 }
        revisions.state += 1
        patch.revisions = revisions
        // A claim is current only at the latest state revision, so a claim
        // the host still stands behind is restamped with every update.
        if let claim = current.safetyClaim {
            patch.safetyClaim = .set(Self.claim(claim, at: revisions.state))
        } else if previous.safetyClaim != nil {
            patch.safetyClaim = .set(nil)
        }
        host.revisions = revisions
        return RemoteStateUpdate(baseRevision: previous.revisions.state, newRevision: revisions.state,
                                 snapshotPatch: patch)
    }

    // MARK: - Fields

    private func make(revisions: ResourceRevisions, now: Date) -> RemoteSnapshot {
        let cards = host.cards.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        let backups = host.backups.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        let selectedCardID = surface.sourceURL.flatMap { source in
            cards.first { host.url(forCard: $0.id).map { Self.same($0, source) } ?? false }?.id
        }
        let selectedBackupIDs = surface.destinationURLs.compactMap { destination in
            backups.first { host.url(forBackup: $0.id).map { Self.same($0, destination) } ?? false }?.id
        }
        let readiness = surface.transferReadiness
        let assessment = OperationReadinessAssessment(readiness, hasDestinations: !surface.destinationURLs.isEmpty)
        return RemoteSnapshot(
            host: host.id, hostName: hostName, session: session, takenAt: now,
            revisions: revisions, mode: surface.currentMode.rawValue,
            verificationMode: surface.verificationMode,
            cards: cards, backups: backups,
            selectedCardID: selectedCardID, selectedBackupIDs: selectedBackupIDs,
            readinessWording: assessment.statusMessage,
            readinessStatus: String(describing: readiness.status),
            queue: queueRows(), outcome: outcome(),
            safetyClaim: safetyClaim(cardID: selectedCardID, revision: revisions.state),
            appleDoubleReview: nil, // later slice
            settings: settings(),
            operationID: surface.stateService.currentOperationId,
            cancellationTargetID: surface.cancellationTargetID)
    }

    /// The queue session's records in journal order, labelled as the Mac's
    /// History labels them.
    private func queueRows() -> [RemoteQueueRow] {
        let records = surface.transferJournal.records
        return records.filter { surface.queueSessionRecordIDs.contains($0.id) }.map {
            RemoteQueueRow(recordID: $0.id, title: $0.title,
                           stateLabel: TransferLibraryPresentation.stateLabel(for: $0, in: records).title,
                           summary: $0.summary)
        }
    }

    /// The queue session's most recently ended record, as its saved summary.
    private func outcome() -> RemoteOutcome? {
        let ended = surface.transferJournal.records.filter {
            surface.queueSessionRecordIDs.contains($0.id) && $0.endedAt != nil
        }
        guard let record = ended.max(by: { $0.endedAt! < $1.endedAt! }) else { return nil }
        return RemoteOutcome(recordID: record.id, title: record.title, message: record.summary,
                             isSuccess: record.state == .completed)
    }

    /// The selected card's latest saved record and the verdict the Mac shows
    /// for it (the same check its eject uses), bound to the card's media.
    private func safetyClaim(cardID: String?, revision: Int) -> RemoteSafetyClaim? {
        guard let cardID, let cardURL = host.url(forCard: cardID),
              let media = host.media(forCard: cardID) else { return nil }
        let records = surface.transferJournal.records
        let saved = records.filter {
            $0.endedAt != nil && RemoteCommandExecutor.isInside($0.source.url, cardURL)
        }
        guard let record = saved.max(by: { $0.endedAt! < $1.endedAt! }) else { return nil }
        let verdict = TransferLibraryPresentation.safetyState(for: record, in: records)
        return RemoteSafetyClaim(recordID: record.id, media: media, isSafeToErase: verdict == .safeToErase,
                                 wording: verdict.title, revision: revision)
    }

    /// Notification, sound, update and crash settings stay on the Mac.
    private func settings() -> RemoteSettings {
        let general = surface.generalSettings
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return RemoteSettings(
            generateASCMHL: surface.generateASCMHL,
            copyWorkers: general.copyWorkers,
            verifyWorkers: general.verifyWorkers,
            verifyWhileCopying: general.verifyWhileCopying,
            queueNewCardsAutomatically: general.queueNewCardsAutomatically,
            autoEjectWhenSafe: general.autoEjectWhenSafe,
            reportSettingsJSON: (try? encoder.encode(surface.reportSettings)) ?? Data())
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    private static func claim(_ claim: RemoteSafetyClaim, at revision: Int) -> RemoteSafetyClaim {
        RemoteSafetyClaim(recordID: claim.recordID, media: claim.media, isSafeToErase: claim.isSafeToErase,
                          wording: claim.wording, revision: revision)
    }
}
