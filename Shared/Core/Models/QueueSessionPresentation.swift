import Foundation
import BitMatchEngine

enum QueueRowAction: Equatable, Sendable {
    case eject
    case review
    case ejected
}

struct QueueSessionRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let cardName: String
    let evidence: String?
    let destinations: String
    let safetyState: CardSafetyState
    let progressFraction: Double?
    let action: QueueRowAction?
    let cause: String?
    let copySummary: String
    let outcome: TransferOutcomePresentation?
    let destinationNames: [String]
    let verificationModeName: String

    var isEditable: Bool { safetyState == .waiting }
    var isRunning: Bool { safetyState.isActiveQueueState }
    var isFinished: Bool { !isEditable && !isRunning }
    var showsSafeHero: Bool { outcome?.safetyState == .safeToErase }
    var waitingText: String {
        let route = destinationNames.isEmpty ? destinations : destinationNames.joined(separator: " + ")
        return "\(cardName) → \(route) · \(verificationModeName)"
    }

    var statusText: String {
        safetyState == .copiedNotVerified
            ? "Copied, not verified: size check only"
            : safetyState.title
    }

    var accessibilityStatus: String {
        let warning = safetyState.isSafe ? "" : ", not safe to erase"
        return "\(cardName), \(statusText)\(warning)" + (cause.map { ", \($0)" } ?? "")
    }

    func oneLineStatus(timeRemaining: String? = nil) -> String {
        let route = destinationNames.isEmpty ? destinations : destinationNames.joined(separator: " + ")
        let prefix = "\(cardName) → \(route)"
        if isRunning {
            let progress = progressFraction.map { " \(Int((min(max($0, 0), 1) * 100).rounded(.down)))%" } ?? ""
            let remaining = timeRemaining.map { " · \($0) left" } ?? ""
            let phase: String
            switch safetyState {
            case .copying: phase = "Copying"
            case .verifying: phase = "Verifying"
            case .preparing: phase = "Preparing"
            default: phase = safetyState.title
            }
            return "\(prefix) · \(phase)\(progress)\(remaining)"
        }
        if let outcome { return outcome.finishTitle }
        return "\(waitingText) · Waiting"
    }
}

struct QueueTally: Equatable, Sendable {
    var safeToErase = 0
    var copiedNotVerified = 0
    var needsAttention = 0
    var failed = 0
    var interrupted = 0
    var notStarted = 0

    var text: String {
        var parts: [String] = []
        append(safeToErase, singular: "safe to erase", plural: "safe to erase", to: &parts)
        append(copiedNotVerified, singular: "copied, not verified", plural: "copied, not verified", to: &parts)
        append(needsAttention, singular: "needs attention", plural: "need attention", to: &parts)
        append(failed, singular: "failed", plural: "failed", to: &parts)
        append(interrupted, singular: "interrupted", plural: "interrupted", to: &parts)
        append(notStarted, singular: "not started", plural: "not started", to: &parts)
        return parts.joined(separator: " · ")
    }

    private func append(_ count: Int, singular: String, plural: String, to parts: inout [String]) {
        guard count > 0 else { return }
        parts.append("\(count) \(count == 1 ? singular : plural)")
    }
}

struct QueueSessionPresentation: Equatable, Sendable {
    let rows: [QueueSessionRow]
    let tally: QueueTally
    let headerTitle: String?
    let headerDetail: String?
    let summaryTitle: String?
    let copySummary: String
    let ejectableCardIDs: [UUID]
    let showsExportReport: Bool
    let pausedCardID: UUID?
    let pausedTitle: String?
    let pausedCause: String?

    var isMultiCard: Bool { rows.count >= 2 }
    var hasStarted: Bool { rows.contains { $0.safetyState != .waiting } }
    var hasWaitingCards: Bool { rows.contains { $0.isEditable } }
    var showsQueueSummary: Bool { summaryTitle != nil }
    var showsEjectAllButton: Bool { ejectableCardIDs.count >= 2 }

    static func make(
        records: [LocalTransferRecord],
        sessionIDs: Set<UUID>,
        sessionRecordIDsInOrder: [UUID]? = nil,
        progress: OperationProgress?,
        mountedSourceIDs: Set<UUID>,
        ejectedSourceIDs: Set<UUID> = [],
        pausedRecordID: UUID? = nil,
        now: Date = Date()
    ) -> Self {
        // A restored queue uses its persisted order. Legacy callers and old
        // sessions fall back to the journal's inverse order because the
        // journal prepends new records and moves the next card to its end.
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let session: [LocalTransferRecord]
        if let sessionRecordIDsInOrder {
            session = sessionRecordIDsInOrder.compactMap { recordsByID[$0] }
        } else {
            session = records.reversed().filter { sessionIDs.contains($0.id) }
        }
        let runningID = session.first(where: { $0.state == .running })?.id
        let rows = session.map { record in
            makeRow(
                record: record,
                progress: record.id == runningID ? progress : nil,
                isMounted: mountedSourceIDs.contains(record.id),
                isEjected: ejectedSourceIDs.contains(record.id)
            )
        }
        var tally = QueueTally()
        for row in rows {
            switch row.safetyState {
            case .safeToErase: tally.safeToErase += 1
            case .copiedNotVerified: tally.copiedNotVerified += 1
            case .needsAttention: tally.needsAttention += 1
            case .failed: tally.failed += 1
            case .interrupted: tally.interrupted += 1
            case .waiting: tally.notStarted += 1
            case .preparing, .copying, .verifying: break
            }
        }
        let running = rows.first { $0.safetyState.isActiveQueueState }
        let finishedCount = rows.filter { $0.safetyState != .waiting && $0.id != running?.id }.count
        let waitingCount = rows.filter { $0.safetyState == .waiting }.count
        // "Copying 2 of 4" reads at a glance; "0 finished · 0 waiting" did not.
        let detail = running.map { _ -> String in
            let total = finishedCount + waitingCount + 1
            return total == 1 ? "Copying 1 card" : "Card \(finishedCount + 1) of \(total)"
        }
        let title = running.map { "\($0.safetyState.title.components(separatedBy: " ").first ?? "Copying") \($0.cardName)" }
        let paused = pausedRecordID.flatMap { id in rows.first { $0.id == id } }
        let hasWaiting = rows.contains { $0.safetyState == .waiting }
        let hasRunCard = rows.contains { $0.safetyState != .waiting }
        let summaryTitle: String?
        if running == nil && rows.count >= 2 && hasRunCard {
            if !hasWaiting && tally.safeToErase == rows.count {
                let noun = rows.count == 1 ? "card" : "cards"
                summaryTitle = "\(rows.count) \(noun) safe to erase"
            } else {
                summaryTitle = tally.text
            }
        } else {
            summaryTitle = nil
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let time = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
        let summaryPrefix = summaryTitle == nil ? "Queue" : (hasWaiting ? "Queue stopped" : "Queue finished")
        let firstLine = "\(summaryPrefix) \(time) · \(tally.text)"
        return Self(
            rows: rows,
            tally: tally,
            headerTitle: title,
            headerDetail: detail,
            summaryTitle: summaryTitle,
            copySummary: ([firstLine] + rows.map(\.copySummary)).joined(separator: "\n"),
            ejectableCardIDs: rows.filter { $0.safetyState.canEject && mountedSourceIDs.contains($0.id) && !ejectedSourceIDs.contains($0.id) }.map(\.id),
            showsExportReport: session.contains {
                $0.reportSettings.makeReport && $0.state != .queued && $0.state != .running
                    && !$0.summary.localizedCaseInsensitiveContains("report could not be saved")
            },
            pausedCardID: paused?.id,
            pausedTitle: paused.map { row in
                let state: String
                switch row.safetyState {
                case .failed: state = "failed"
                case .interrupted: state = "was interrupted"
                default: state = "needs attention"
                }
                return "Queue paused — \(row.cardName) \(state)"
            },
            pausedCause: paused?.cause.map(deduplicatedCause)
        )
    }

    private static func makeRow(
        record: LocalTransferRecord,
        progress: OperationProgress?,
        isMounted: Bool,
        isEjected: Bool
    ) -> QueueSessionRow {
        let state: CardSafetyState
        if record.state == .running {
            let percent = progress.map { Int((min(max($0.stageProgress ?? $0.overallProgress, 0), 1) * 100).rounded(.down)) }
            switch progress?.currentStage {
            case .copying: state = .copying(progress: percent)
            case .verifying, .generating, .completed: state = .verifying(progress: percent)
            default: state = .preparing
            }
        } else {
            state = TransferLibraryPresentation.safetyState(for: record)
        }
        let paths = Dictionary(grouping: record.results, by: \.path)
        let recordedBytes = paths.values.compactMap { $0.first }.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
        let count = paths.isEmpty ? max(0, progress?.totalFiles ?? 0) : paths.count
        // Recorded results are authoritative: a zero-byte total names genuinely
        // empty content ("Empty"), it never falls back to live progress.
        let bytes: Int64? = paths.isEmpty ? progress?.totalBytes : recordedBytes
        let evidence: String?
        if count > 0, let bytes {
            evidence = "\(count) \(count == 1 ? "file" : "files") · \(ByteCountPresentation.fileSize(bytes))"
        } else if count > 0 {
            evidence = "\(count) \(count == 1 ? "file" : "files")"
        } else {
            evidence = nil
        }
        let destinationNames = record.destinations.map { TransferOutcomePresentation.destinationDriveName($0.url) }
        let cause = cause(for: record, state: state)
        let outcome = finishedOutcome(for: record, state: state)
        let action: QueueRowAction?
        if isEjected && state.canEject { action = .ejected }
        else if state.canEject && isMounted { action = .eject }
        else if state == .copiedNotVerified || state == .needsAttention || state == .failed || state == .interrupted { action = .review }
        else { action = nil }
        return QueueSessionRow(
            id: record.id,
            cardName: record.title,
            evidence: evidence,
            destinations: destinationSummary(destinationNames),
            safetyState: state,
            progressFraction: record.state == .running ? progress?.stageProgress ?? progress?.overallProgress : nil,
            action: action,
            cause: cause,
            copySummary: TransferOutcomePresentation.makeCopySummary(
                safetyState: state,
                cardName: record.title,
                sourceBytes: bytes,
                destinations: destinationNames,
                algorithm: TransferOutcomePresentation.algorithmLabel(record.verificationMode),
                reason: cause
            ),
            outcome: outcome,
            destinationNames: destinationNames,
            verificationModeName: record.verificationMode.rawValue
        )
    }

    private static func finishedOutcome(
        for record: LocalTransferRecord,
        state: CardSafetyState
    ) -> TransferOutcomePresentation? {
        guard record.state != .queued, record.state != .running else { return nil }
        let operationState: OperationState
        switch state {
        case .safeToErase:
            operationState = .completed(.init(success: true, message: record.summary))
        case .copiedNotVerified:
            operationState = .completed(.init(success: false, message: record.summary, copiedNotVerified: true))
        case .needsAttention:
            operationState = .completed(.init(success: false, message: record.summary))
        case .failed:
            operationState = .failed
        case .interrupted:
            operationState = .cancelled
        case .waiting, .preparing, .copying, .verifying:
            return nil
        }
        let uniqueFiles = Dictionary(grouping: record.results, by: \.path).values.compactMap(\.first)
        let sourceBytes = uniqueFiles.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
        let issueCount = record.results.filter { !$0.isSuccessStatus }.count
        let duration = record.startedAt.flatMap { started in record.endedAt.map { $0.timeIntervalSince(started) } }
        return TransferOutcomePresentation.make(
            state: operationState,
            rows: record.results,
            destinations: record.destinations.map(\.url),
            hasErrors: issueCount > 0,
            hasCriticalErrors: state == .failed,
            errorCount: issueCount,
            warningCount: 0,
            duration: duration,
            copyDurationSeconds: record.copyDurationSeconds,
            verifyDurationSeconds: record.verifyDurationSeconds,
            sourceFileCount: uniqueFiles.count,
            sourceBytes: sourceBytes,
            verificationMode: record.verificationMode,
            canRetry: record.canRetry || (
                record.projectID != nil && record.projectCardID != nil && record.state.canRetry
            ),
            canExport: true,
            sourceName: record.title,
            completionReason: record.summary
        )
    }

    private static func cause(for record: LocalTransferRecord, state: CardSafetyState) -> String? {
        guard state == .needsAttention || state == .failed || state == .interrupted else { return nil }
        if state == .needsAttention {
            let issues = DestinationResultSummary.make(
                rows: record.results,
                destinations: record.destinations.map(\.url)
            ).filter { $0.issueCount > 0 }
            if issues.count == 1, let issue = issues.first {
                let count = issue.issueCount
                let files = count == 1 ? "1 file failed" : "\(count) files failed"
                let drive = TransferOutcomePresentation.destinationDriveName(
                    URL(fileURLWithPath: issue.id, isDirectory: true)
                )
                return "\(files) on \(drive)"
            }
        }
        let summary = record.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    static func destinationSummary(_ names: [String]) -> String {
        guard let first = names.first else { return "No destinations" }
        let allOnOneDrive = names.allSatisfy {
            $0.compare(first, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if allOnOneDrive {
            return names.count == 1 ? "1 destination on \(first)" : "\(names.count) destinations on \(first)"
        }
        return "\(names.count) destinations: \(names.joined(separator: ", "))"
    }

    static func deduplicatedCause(_ cause: String) -> String {
        var seen: Set<String> = []
        let clauses = cause.split(separator: ";", omittingEmptySubsequences: true).compactMap { clause -> String? in
            let value = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return value
        }
        return clauses.joined(separator: "; ")
    }
}

extension CardSafetyState {
    var isActiveQueueState: Bool {
        switch self {
        case .preparing, .copying, .verifying: true
        default: false
        }
    }
}

enum QueueCommandPolicy {
    static func canRunQueue(isPausedOnProblem: Bool, waitingCount: Int) -> Bool {
        !isPausedOnProblem && waitingCount > 0
    }

    static func showsResume(hasSessionStarted: Bool, waitingCount: Int) -> Bool {
        hasSessionStarted && waitingCount > 0
    }
}

enum QueueHeroPolicy {
    static func shouldExpand(
        row: QueueSessionRow,
        previousRows: [QueueSessionRow],
        currentRows: [QueueSessionRow]
    ) -> Bool {
        guard row.showsSafeHero,
              previousRows.first(where: { $0.id == row.id })?.showsSafeHero != true else { return false }
        return !currentRows.contains { $0.id != row.id && $0.isRunning }
    }
}

enum ActiveQueuePresentation {
    static func canAddCard(isOperationInProgress: Bool, queueIsRunning: Bool, destinationCount: Int) -> Bool {
        (isOperationInProgress || queueIsRunning) && destinationCount > 0
    }

    static func showsReconnect(for state: LocalTransferState) -> Bool {
        state == .queued
    }
}

enum AutoQueuePolicy {
    static func candidates(
        eligibleRows: [ConnectedDrivesPresentation.Row],
        seenVolumeIDs: Set<String>,
        activeDestinationVolumeIDs: Set<String>
    ) -> [ConnectedDrivesPresentation.Row] {
        var claimedVolumeIDs = seenVolumeIDs
        return eligibleRows.filter {
            guard $0.role == .card, let volumeID = $0.volumeID,
                  !activeDestinationVolumeIDs.contains(volumeID),
                  claimedVolumeIDs.insert(volumeID).inserted else { return false }
            return true
        }
    }
}

enum QueueDockBadgePolicy {
    static func unresolvedCount(rows: [QueueSessionRow], reviewedIDs: Set<UUID>) -> Int {
        unresolvedIDs(rows: rows, reviewedIDs: reviewedIDs).count
    }

    private static func unresolvedIDs(rows: [QueueSessionRow], reviewedIDs: Set<UUID>) -> Set<UUID> {
        Set(rows.enumerated().compactMap { index, row in
            let laterSafeRetry = rows.dropFirst(index + 1).contains {
                $0.cardName == row.cardName && $0.safetyState == .safeToErase
            }
            let unresolved = (row.safetyState == .needsAttention || row.safetyState == .failed
                || row.safetyState == .interrupted) && !reviewedIDs.contains(row.id) && !laterSafeRetry
            return unresolved ? row.id : nil
        })
    }

    static func totalUnresolvedCount(
        rows: [QueueSessionRow], reviewedIDs: Set<UUID>, standaloneAttentionIDs: Set<UUID>
    ) -> Int {
        unresolvedIDs(rows: rows, reviewedIDs: reviewedIDs).union(standaloneAttentionIDs).count
    }
}
