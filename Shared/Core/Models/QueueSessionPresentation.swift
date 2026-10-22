import Foundation
import BitMatchEngine

enum QueueRowAction: Equatable, Sendable {
    case eject
    case review
    case ejected
    case ejecting
    case removed
}

struct QueueSessionRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let cardName: String
    let evidence: String?
    let destinations: String
    let safetyState: CardSafetyState
    let progressFraction: Double?
    private(set) var action: QueueRowAction?
    let cause: String?
    let copySummary: String
    let outcome: TransferOutcomePresentation?
    let destinationNames: [String]
    let verificationModeName: String
    /// Progress estimate only; nil for old or unmeasured queue records.
    var estimatedWorkBytes: Double? = nil
    /// When the transfer settled; nil while it is waiting or running.
    var endedAt: Date? = nil
    /// Earlier attempts of the same card, oldest first. Their journal records stay.
    private(set) var earlierAttemptIDs: [UUID] = []
    /// Which stage a failed transfer stopped in; nil unless `safetyState == .failed`.
    var failureStage: FailureStage? = nil

    enum FailureStage: Equatable, Sendable { case copy, verify }

    /// Queue wording: says what to do with the card. History keeps `safetyState.title`.
    var queueLabel: String {
        if selectedFilesVerified { return "Selected files verified" }
        switch safetyState {
        case .waiting: return "Queued"
        case .preparing, .copying, .finishing: return "Copying"
        case .verifying: return "Verifying"
        case .safeToErase: return "Safe to erase"
        case .copiedNotVerified: return "Copied, not verified"
        case .needsAttention, .interrupted: return "Keep the card"
        case .failed: return failureStage == .verify ? "Didn't verify" : "Didn't copy"
        }
    }

    var queueSymbol: String {
        if selectedFilesVerified { return "checkmark.circle" }
        return switch safetyState {
        case .waiting: "clock"
        case .preparing, .copying, .verifying, .finishing: "arrow.triangle.2.circlepath"
        case .safeToErase: "checkmark.circle.fill"
        case .copiedNotVerified: "circle.lefthalf.filled"
        case .needsAttention, .interrupted: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    /// `<state word> <time> · <reason or backups> · <size>`; empty segments are dropped.
    /// Running states keep the one-line status until the running row is reworked.
    func metaLine(now: Date = Date(), calendar: Calendar = .current) -> String {
        if isRunning { return oneLineStatus(timeRemaining: nil) }
        let word: String
        var needsReason = false
        switch safetyState {
        case .safeToErase: word = "Verified"
        case .copiedNotVerified: word = "Copied"
        case .needsAttention, .interrupted: word = "Paused"; needsReason = true
        case .failed: word = "Stopped"; needsReason = true
        default: word = "Queued"
        }
        var lead = word
        if safetyState != .waiting, let endedAt {
            let formatter = DateFormatter()
            formatter.locale = calendar.locale ?? .current
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "h:mm a"
            lead += " " + formatter.string(from: endedAt)
        }
        let middle = needsReason
            ? cause.map(QueueSessionPresentation.plainCause) ?? ""
            : destinationNames.joined(separator: ", ")
        let size = evidence.flatMap { text -> String? in
            guard let range = text.range(of: " · ") else { return nil }
            return String(text[range.upperBound...])
        } ?? ""
        return [lead, middle, size].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var isEditable: Bool { safetyState == .waiting }
    var isRunning: Bool { safetyState.isActiveQueueState }
    var isFinished: Bool { !isEditable && !isRunning }
    var showsSafeHero: Bool { outcome?.safetyState == .safeToErase }
    var selectedFilesVerified: Bool { outcome?.selectedFilesVerified == true }
    var statusTint: CardSafetyTint { outcome?.tint ?? safetyState.tint }
    var statusSymbol: String { selectedFilesVerified ? "checkmark.circle" : safetyState.symbol }
    var waitingDestinationText: String {
        destinationNames.isEmpty ? destinations : destinationNames.joined(separator: " + ")
    }
    var compactWaitingText: String { "\(cardName) → \(waitingDestinationText)" }
    var waitingText: String {
        "\(compactWaitingText) · \(verificationModeName)"
    }

    var statusText: String {
        if selectedFilesVerified { return "Selected files verified" }
        return safetyState == .copiedNotVerified
            ? "Copied, not verified: size check only"
            : safetyState.title
    }

    var accessibilityStatus: String {
        let warning = safetyState.isSafe || selectedFilesVerified ? "" : ", not safe to erase"
        return "\(cardName), \(statusText)\(warning)" + (cause.map { ", \($0)" } ?? "")
    }

    func oneLineStatus(timeRemaining: String? = nil) -> String {
        let prefix = compactWaitingText
        if isRunning {
            let progress = progressFraction.map { " \(Int((min(max($0, 0), 0.99) * 100).rounded(.down)))%" } ?? ""
            let measuredTime = timeRemaining == TransferProgressPresentation.estimatingTimeLeft
                ? nil
                : timeRemaining
            let remaining = measuredTime.map { " · \($0) left" } ?? ""
            let phase: String
            switch safetyState {
            case .copying: phase = "Copying"
            case .verifying: phase = "Verifying"
            case .finishing: phase = "Finishing"
            case .preparing: phase = "Preparing"
            default: phase = safetyState.title
            }
            return "\(prefix) · \(phase)\(progress)\(remaining)"
        }
        if let outcome { return outcome.finishTitle }
        return "\(waitingText) · Waiting"
    }

    fileprivate func withEarlierAttempts(_ ids: [UUID]) -> Self {
        var row = self
        row.earlierAttemptIDs = ids
        return row
    }

    /// A cached finish describes evidence, never whether the card is still
    /// connected. Reapply that live capability on every presentation.
    fileprivate func showingSource(
        isMounted: Bool, isEjected: Bool, isEjecting: Bool = false, isRemoved: Bool = false
    ) -> Self {
        var row = self
        if selectedFilesVerified { row.action = nil; return row }
        if isRemoved && isEjected && safetyState.canEject { row.action = .removed }
        else if isEjecting && safetyState.canEject { row.action = .ejecting }
        else if isEjected && safetyState.canEject { row.action = .ejected }
        else if safetyState.canEject && isMounted { row.action = .eject }
        else if safetyState == .copiedNotVerified || safetyState == .needsAttention
            || safetyState == .failed || safetyState == .interrupted { row.action = .review }
        else { row.action = nil }
        return row
    }
}

/// Row transitions used by completion heroes and automatic eject.
/// Progress and phase text still render, without rechecking those actions.
struct QueueRowTransitionState: Equatable, Sendable {
    let id: UUID
    let isRunning: Bool
    let showsSafeHero: Bool

    init(_ row: QueueSessionRow) {
        id = row.id
        isRunning = row.isRunning
        showsSafeHero = row.showsSafeHero
    }
}

struct QueueTally: Equatable, Sendable {
    var safeToErase = 0
    var selectedFilesVerified = 0
    var copiedNotVerified = 0
    var needsAttention = 0
    var failed = 0
    var interrupted = 0
    var notStarted = 0

    /// Header words match the row labels; zero counts are omitted.
    var queueHeaderText: String {
        var parts: [String] = []
        append(safeToErase, singular: "safe to erase", plural: "safe to erase", to: &parts)
        append(selectedFilesVerified, singular: "selected files verified", plural: "selected files verified", to: &parts)
        append(needsAttention + interrupted, singular: "keep the card", plural: "keep the card", to: &parts)
        append(failed, singular: "didn't verify", plural: "didn't verify", to: &parts)
        append(copiedNotVerified, singular: "copied, not verified", plural: "copied, not verified", to: &parts)
        append(notStarted, singular: "queued", plural: "queued", to: &parts)
        return parts.joined(separator: " · ")
    }

    var text: String {
        var parts: [String] = []
        append(safeToErase, singular: "safe to erase", plural: "safe to erase", to: &parts)
        append(selectedFilesVerified, singular: "selected transfer verified", plural: "selected transfers verified", to: &parts)
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
    var showsClearFinished: Bool { rows.contains(where: \.isFinished) }

    static func make(
        records: [LocalTransferRecord],
        sessionIDs: Set<UUID>,
        sessionRecordIDsInOrder: [UUID]? = nil,
        progress: OperationProgress?,
        mountedSourceIDs: Set<UUID>,
        ejectedSourceIDs: Set<UUID> = [],
        ejectingSourceIDs: Set<UUID> = [],
        removedSourceIDs: Set<UUID> = [],
        pausedRecordID: UUID? = nil,
        now: Date = Date(),
        /// Terminal rows derived from this exact journal snapshot. The journal
        /// owns invalidation; ordinary callers keep the pure uncached path.
        completedRows: [UUID: QueueSessionRow] = [:],
        onCompletedRowBuilt: (() -> Void)? = nil
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
        // One row per card: a later attempt replaces an earlier one that ended
        // without a clean finish, in the earlier attempt's place. Queued and
        // running records are never collapsed. Journal records are untouched.
        var attempts: [(record: LocalTransferRecord, earlier: [UUID])] = []
        var lastAttempt: [String: Int] = [:]
        for record in session {
            let key = attemptKey(for: record)
            if let index = lastAttempt[key], collapsesIntoLaterAttempt(attempts[index].record) {
                attempts[index] = (record, attempts[index].earlier + [attempts[index].record.id])
            } else {
                attempts.append((record, []))
                lastAttempt[key] = attempts.count - 1
            }
        }
        let rows = attempts.map { attempt -> QueueSessionRow in
            let record = attempt.record
            if record.state != .queued, record.state != .running,
               let completed = completedRows[record.id] {
                return completed.withEarlierAttempts(attempt.earlier).showingSource(
                    isMounted: mountedSourceIDs.contains(record.id),
                    isEjected: ejectedSourceIDs.contains(record.id),
                    isEjecting: ejectingSourceIDs.contains(record.id),
                    isRemoved: removedSourceIDs.contains(record.id)
                )
            }
            if record.state != .queued, record.state != .running {
                onCompletedRowBuilt?()
            }
            return makeRow(
                record: record,
                progress: record.id == runningID ? progress : nil,
                isMounted: mountedSourceIDs.contains(record.id),
                isEjected: ejectedSourceIDs.contains(record.id),
                isEjecting: ejectingSourceIDs.contains(record.id),
                isRemoved: removedSourceIDs.contains(record.id),
                earlierAttemptIDs: attempt.earlier
            )
        }
        var tally = QueueTally()
        for row in rows {
            if row.selectedFilesVerified {
                tally.selectedFilesVerified += 1
                continue
            }
            switch row.safetyState {
            case .safeToErase: tally.safeToErase += 1
            case .copiedNotVerified: tally.copiedNotVerified += 1
            case .needsAttention: tally.needsAttention += 1
            case .failed: tally.failed += 1
            case .interrupted: tally.interrupted += 1
            case .waiting: tally.notStarted += 1
            case .preparing, .copying, .verifying, .finishing: break
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
            ejectableCardIDs: rows.filter { $0.safetyState.canEject && mountedSourceIDs.contains($0.id) && !ejectedSourceIDs.contains($0.id) && !ejectingSourceIDs.contains($0.id) }.map(\.id),
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

    /// The card a record belongs to: its volume and folder identity when known,
    /// else its source path. A volume ID alone would merge two folders of one disk.
    static func attemptKey(for record: LocalTransferRecord) -> String {
        guard let volumeID = record.source.volumeID, let resourceID = record.source.resourceID else {
            return record.source.url.path
        }
        return "\(volumeID)/\(resourceID)"
    }

    /// Judged by what the user sees, not the journal state: a completed run
    /// that still needs attention is as unsettled as a failed one.
    private static func collapsesIntoLaterAttempt(_ record: LocalTransferRecord) -> Bool {
        guard record.state != .queued, record.state != .running else { return false }
        switch TransferLibraryPresentation.safetyState(for: record) {
        case .needsAttention, .failed, .interrupted, .copiedNotVerified: return true
        default: return false
        }
    }

    /// The cached value contains only presentation fields, not the source
    /// record or its potentially large result array.
    static func completedRow(for record: LocalTransferRecord) -> QueueSessionRow? {
        guard record.state != .queued, record.state != .running else { return nil }
        return makeRow(record: record, progress: nil, isMounted: false, isEjected: false)
    }

    private static func makeRow(
        record: LocalTransferRecord,
        progress: OperationProgress?,
        isMounted: Bool,
        isEjected: Bool,
        isEjecting: Bool = false,
        isRemoved: Bool = false,
        earlierAttemptIDs: [UUID] = []
    ) -> QueueSessionRow {
        let state: CardSafetyState
        if record.state == .running {
            // A completed file-work stage is not a finished transfer. MHL,
            // report writing and journal settlement can still fail or stop.
            let activeFraction = progress.map {
                min(max($0.overallProgress, 0), 0.99)
            }
            let percent = activeFraction.map { Int(($0 * 100).rounded(.down)) }
            switch progress?.currentStage {
            case .copying: state = .copying(progress: percent)
            case .verifying: state = .verifying(progress: percent)
            case .generating, .completed: state = .finishing(progress: percent)
            default: state = .preparing
            }
        } else {
            state = TransferLibraryPresentation.safetyState(for: record)
        }
        let qualifiedSelection = TransferOutcomePresentation.hasVerifiedSelectedFiles(record)
        let countedRows = qualifiedSelection ? record.results.filter {
            ResultOutcome(statusText: $0.status) != .excludedAppleDouble
        } : record.results
        let paths = Dictionary(grouping: countedRows, by: \.path)
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
        let cause = qualifiedSelection ? nil : cause(for: record, state: state)
        let outcome = finishedOutcome(for: record, state: state)
        let allFilesReused = state == .safeToErase
            && !record.results.isEmpty
            && record.results.allSatisfy { $0.isVerifiedStatus && $0.wasReused }
        return QueueSessionRow(
            id: record.id,
            cardName: record.title,
            evidence: evidence,
            destinations: destinationSummary(destinationNames),
            safetyState: state,
            progressFraction: record.state == .running ? progress.map {
                min(max($0.overallProgress, 0), 0.99)
            } : nil,
            action: nil,
            cause: cause,
            copySummary: TransferOutcomePresentation.makeCopySummary(
                safetyState: state,
                cardName: record.title,
                sourceBytes: bytes,
                destinations: destinationNames,
                algorithm: TransferOutcomePresentation.algorithmLabel(record.verificationMode),
                reason: cause,
                allFilesReused: allFilesReused,
                selectedFilesVerified: outcome?.selectedFilesVerified == true
            ),
            outcome: outcome,
            destinationNames: destinationNames,
            verificationModeName: record.verificationMode.rawValue,
            estimatedWorkBytes: estimatedWorkBytes(for: record),
            endedAt: record.endedAt,
            earlierAttemptIDs: earlierAttemptIDs,
            failureStage: state == .failed
                ? (record.results.contains { ResultOutcome(statusText: $0.status) == .checksumMismatch } ? .verify : .copy)
                : nil
        ).showingSource(
            isMounted: isMounted, isEjected: isEjected, isEjecting: isEjecting, isRemoved: isRemoved
        )
    }

    static func estimatedWorkBytes(for record: LocalTransferRecord) -> Double? {
        guard let bytes = record.estimatedSourceBytes, bytes >= 0 else { return nil }
        let destinations = Double(record.destinations.count)
        let destinationPasses = record.verificationMode == .quick ? 0.0 : (record.verificationMode == .paranoid ? 2.0 : 1.0)
        let sourcePasses = record.verificationMode == .thorough ? 2.0 : (record.verificationMode == .paranoid ? 1 + destinations : 1.0)
        let handoffPasses = record.generateASCMHL && record.verificationMode != .quick ? destinations : 0
        return max(1, Double(bytes)) * (sourcePasses + destinations * (1 + destinationPasses) + handoffPasses)
    }

    private static func finishedOutcome(
        for record: LocalTransferRecord,
        state: CardSafetyState
    ) -> TransferOutcomePresentation? {
        guard record.state != .queued, record.state != .running else { return nil }
        let displayedReason = TransferOutcomePresentation.recordedCompletionReason(for: record)
        let operationState: OperationState
        switch state {
        case .safeToErase:
            operationState = .completed(.init(success: true, message: displayedReason))
        case .copiedNotVerified:
            operationState = .completed(.init(success: false, message: displayedReason, copiedNotVerified: true))
        case .needsAttention:
            operationState = .completed(.init(success: false, message: displayedReason))
        case .failed:
            operationState = .failed
        case .interrupted:
            operationState = .cancelled
        case .waiting, .preparing, .copying, .verifying, .finishing:
            return nil
        }
        let uniqueFiles = Dictionary(grouping: record.results, by: \.path).values.compactMap(\.first)
        let sourceBytes = uniqueFiles.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
        let issueCount = record.results.filter { !$0.isSuccessStatus && ResultOutcome(statusText: $0.status) != .excludedAppleDouble }.count
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
            completionReason: displayedReason,
            independentDestinationCount: record.independentDestinationCount,
            selectedFileVerificationQualified: TransferOutcomePresentation.hasVerifiedSelectedFiles(record)
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
        let summary = TransferOutcomePresentation.recordedCompletionReason(for: record)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Engine wording to plain language for the queue meta line; first clause only.
    static func plainCause(_ cause: String) -> String {
        var text = deduplicatedCause(cause)
        let replacements = [
            ("Original selected-file plan was not saved", "can't confirm every file was copied"),
            ("selected-file plan was not saved", "can't confirm every file was copied"),
            ("whole-card coverage cannot be confirmed", "can't confirm every file was copied"),
            ("Keep the source.", ""),
            ("destination", "backup"),
            ("source", "card"),
        ]
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        let first = text.split(separator: ";", omittingEmptySubsequences: true).first.map(String.init) ?? text
        var result = first.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
        case .preparing, .copying, .verifying, .finishing: true
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

/// Eject is a safety capability, not merely a row action. Keep this check at
/// every UI and automatic-action boundary so an inconsistent presentation
/// fails closed instead of making a non-safe card look removable.
enum QueueEjectPolicy {
    static func canOfferEject(row: QueueSessionRow, platformSupportsEject: Bool) -> Bool {
        platformSupportsEject
            && row.action == .eject
            && row.safetyState == .safeToErase
    }

    static func shouldAutoEject(
        row: QueueSessionRow,
        platformSupportsEject: Bool,
        preferenceEnabled: Bool
    ) -> Bool {
        preferenceEnabled && canOfferEject(
            row: row,
            platformSupportsEject: platformSupportsEject
        )
    }
}

enum QueueRunningNoticePolicy {
    static func sectionNote(
        isRunning: Bool,
        isMobile: Bool,
        progress: TransferProgressPresentation,
        showsExpandedRunningProgress: Bool = false
    ) -> ProgressDeviceNote? {
        guard isRunning, isMobile, !showsExpandedRunningProgress else { return nil }
        return progress.deviceNotes.first { $0.text == TransferProgressPresentation.iOSBackgroundLimit }
    }
}

enum QueueHeroPolicy {
    static func shouldExpand(
        row: QueueSessionRow,
        previousRows: [QueueSessionRow],
        currentRows: [QueueSessionRow]
    ) -> Bool {
        shouldExpand(
            row: row,
            wasSafe: previousRows.first(where: { $0.id == row.id })?.showsSafeHero == true,
            otherCardIsRunning: currentRows.contains { $0.id != row.id && $0.isRunning }
        )
    }

    static func shouldExpand(row: QueueSessionRow, wasSafe: Bool, otherCardIsRunning: Bool) -> Bool {
        row.showsSafeHero && !wasSafe && !otherCardIsRunning
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
            guard !row.selectedFilesVerified else { return nil }
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

    /// The Dock badge shows the unresolved count, or nothing when clean.
    static func badgeLabel(forCount count: Int) -> String? {
        count == 0 ? nil : String(count)
    }
}
