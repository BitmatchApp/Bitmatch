import Foundation
import BitMatchEngine

/// The action the outcome screen draws as its prominent button: the step
/// the user most likely takes next.
enum OutcomePrimaryAction: Equatable, Sendable {
    case newTransfer
    case retry
}

/// File results by how they ended. A row is one file on one backup.
struct OutcomeFileCounts: Equatable, Sendable {
    let verified: Int
    let copiedNotVerified: Int
    let needsAttention: Int

    var total: Int { verified + copiedNotVerified + needsAttention }

    static func make(rows: [ResultRow]) -> Self {
        var verified = 0
        var copied = 0
        var attention = 0
        for row in rows {
            if !row.isSuccessStatus {
                attention += 1
            } else if TransferOutcomePresentation.isVerified(row) {
                verified += 1
            } else {
                copied += 1
            }
        }
        return Self(verified: verified, copiedNotVerified: copied, needsAttention: attention)
    }
}

/// One backup's line on the outcome screen.
struct OutcomeDestinationLine: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let needsAttention: Bool
}

/// Everything the shared `OutcomeScreen` shows for a finished, failed or
/// interrupted transfer, on Mac, iPad and iPhone (UI plan step 4.7).
///
/// It only *presents* the verdict: `CompletionVerdict` and the state-aware
/// `CompletionVerdictPresentation.make(state:…)` decide it. Guidance, state,
/// issue lines, counts and duration wording all live here so no view has its
/// own copy of them.
struct TransferOutcomePresentation: Equatable, Sendable {
    /// The file list shows at most this many rows; the export has them all.
    static let fileListLimit = 1_000

    let verdict: CompletionVerdictPresentation
    let safetyState: CardSafetyState
    /// The one sentence about the source card. Exactly one source of truth.
    let guidance: String
    /// The card's display name ("The card" when unknown), for the eject
    /// button's label.
    let cardName: String
    /// "N files failed", errors, warnings. Empty when interrupted or verified.
    let issueLines: [String]
    /// Failed media files with their sibling sidecars. Presentation only.
    let clipFailureLines: [String]
    /// Amber advisory wording that never participates in the safety verdict.
    let advisoryLines: [String]
    /// "Completed in …", or "Stopped after …" for an interrupted transfer.
    let durationLabel: String?
    let phaseDurationLabel: String?
    let counts: OutcomeFileCounts
    /// Bytes of verified files, summed over every backup. Nil when
    /// nothing was verified; never the source folder size.
    let bytesVerified: Int64?
    let verificationModeLabel: String?
    let destinations: [OutcomeDestinationLine]
    let rowCount: Int
    let rowsTruncated: Bool
    let canRetry: Bool
    let canExport: Bool
    let primaryAction: OutcomePrimaryAction
    let showsNewTransfer: Bool
    let newTransferHelp: String?
    let copySummary: String

    var isInterrupted: Bool { safetyState == .interrupted }

    /// Spoken when the screen appears (audit C3).
    var announcement: String { "\(finishTitle). \(verdict.detail)" }

    var canEject: Bool { safetyState.canEject }
    var showsBackupRowsInline: Bool { safetyState == .needsAttention && !destinations.isEmpty }

    /// Guidance that is not already stated in the detail line. This is part
    /// of the visible banner, so every unsafe finish explicitly tells the
    /// user to keep the card without repeating the same sentence twice.
    var bannerGuidance: String? {
        // Quick, failed, and interrupted details already carry the warning.
        // Safe and needs-attention states still benefit from one next-step
        // sentence, but never repeat the source name.
        switch safetyState {
        case .safeToErase, .needsAttention: guidance
        default: nil
        }
    }

    /// Exactly the words visible in the verdict banner, kept testable apart
    /// from SwiftUI rendering.
    var visibleVerdictText: String {
        [finishTitle, verdict.detail, bannerGuidance]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// The single-line Finish title. The view lays the card and verdict out as
    /// separate title-sized runs so only the card name can middle-truncate.
    var finishTitle: String {
        finishTitlePlacesCardFirst
            ? "\(cardName) \(finishVerdictWords)"
            : "\(finishVerdictWords) — \(cardName)"
    }

    var finishTitlePlacesCardFirst: Bool {
        switch safetyState {
        case .failed, .interrupted: false
        default: true
        }
    }

    var finishVerdictWords: String {
        switch safetyState {
        case .safeToErase: "is safe to erase"
        case .copiedNotVerified: "copied, not verified"
        case .needsAttention: "needs attention"
        case .failed: "Transfer failed"
        case .interrupted: "Transfer interrupted"
        case .waiting: "is waiting"
        case .preparing: "is preparing"
        case .copying: "is copying"
        case .verifying: "is verifying"
        }
    }

    static func shouldAutoEject(safetyState: CardSafetyState) -> Bool {
        safetyState.canEject
    }

    static func make(
        state: OperationState,
        rows: [ResultRow],
        destinations: [URL],
        hasErrors: Bool,
        hasCriticalErrors: Bool,
        errorCount: Int,
        warningCount: Int,
        duration: TimeInterval?,
        copyDurationSeconds: TimeInterval? = nil,
        verifyDurationSeconds: TimeInterval? = nil,
        sourceFileCount: Int? = nil,
        sourceBytes: Int64? = nil,
        verificationMode: VerificationMode?,
        canRetry: Bool,
        canExport: Bool,
        sourceName: String = "",
        completionReason: String? = nil,
        independentDestinationCount: Int? = nil
    ) -> Self {
        // `sourceName` passes through raw: `CompletionVerdictPresentation`
        // owns the empty-name fallback and its "The card" / "the card"
        // casing, so it must see "" here, not an already-capitalized default.
        let card = sourceName.isEmpty ? "The card" : sourceName
        let resolved = CompletionVerdict.resolve(
            state: state,
            rows: rows,
            hasErrors: hasErrors,
            hasCriticalErrors: hasCriticalErrors
        )
        let claimedDestinationCount = min(
            destinations.count,
            max(0, independentDestinationCount ?? destinations.count)
        )
        let baseVerdict = CompletionVerdictPresentation.make(
            state: state,
            rows: rows,
            hasErrors: hasErrors,
            hasCriticalErrors: hasCriticalErrors,
            cardName: sourceName,
            backupCount: claimedDestinationCount
        )
        let safetyState = CardSafetyState.make(state: state, verdict: resolved)
        let counts = OutcomeFileCounts.make(rows: rows)

        let verifiedBytes = rows.filter(Self.isVerified).reduce(into: Int64(0)) { total, row in
            let (sum, overflow) = total.addingReportingOverflow(max(0, row.size))
            total = overflow ? .max : sum
        }

        let needsRetry = safetyState == .failed
            || safetyState == .interrupted
            || safetyState == .needsAttention
        let sourceEvidence = sourceEvidence(rows)
        let algorithm = algorithmLabel(verificationMode)
        let destinationNames = destinations.map(destinationDriveName)
        let reason = issueReason(
            safetyState: safetyState,
            completionDetail: baseVerdict.detail,
            counts: counts,
            errorCount: errorCount,
            warningCount: warningCount,
            completionReason: completionReason,
            rows: rows,
            destinations: destinations
        )
        let allowsRetry = canRetry && (
            safetyState == .needsAttention || safetyState == .failed || safetyState == .interrupted
        )
        // Never leave the finish screen without a way forward. Interrupted
        // transfers offer both actions; otherwise New Transfer is required
        // whenever Retry cannot be offered.
        let showsNewTransfer = !allowsRetry || safetyState == .interrupted

        let verdict = CompletionVerdictPresentation(
            title: baseVerdict.title,
            detail: bannerDetail(
                safetyState: safetyState,
                sourceFileCount: sourceFileCount ?? sourceEvidence.fileCount,
                sourceBytes: sourceBytes ?? sourceEvidence.bytes,
                destinations: destinationNames.map { shortenedDestinationName($0) },
                algorithm: algorithm,
                duration: duration,
                reason: reason,
                fallback: baseVerdict.detail
            ),
            symbol: safetyState.symbol,
            // The banner names the card once. All guidance comes from the
            // nameless form, including Quick and needs-attention outcomes.
            sourceGuidance: CompletionVerdictPresentation.make(
                state: state,
                rows: rows,
                hasErrors: hasErrors,
                hasCriticalErrors: hasCriticalErrors,
                backupCount: claimedDestinationCount
            ).sourceGuidance
        )

        return Self(
            verdict: verdict,
            safetyState: safetyState,
            guidance: verdict.sourceGuidance,
            cardName: card,
            issueLines: makeIssueLines(
                safetyState: safetyState, counts: counts, errorCount: errorCount,
                warningCount: warningCount
            ),
            clipFailureLines: ResultPresentation.clipFailureDescriptions(rows),
            advisoryLines: [ResultPresentation.incompleteClipAdvisory(rows)].compactMap { $0 },
            durationLabel: duration.map { makeDurationLabel(safetyState: safetyState, state: state, seconds: $0) },
            phaseDurationLabel: phaseDurationText(
                copySeconds: copyDurationSeconds,
                verifySeconds: verifyDurationSeconds,
                verificationMode: verificationMode
            ),
            counts: counts,
            bytesVerified: counts.verified > 0 ? verifiedBytes : nil,
            verificationModeLabel: algorithm,
            destinations: makeDestinationLines(rows: rows, destinations: destinations, interrupted: safetyState == .interrupted),
            rowCount: rows.count,
            rowsTruncated: rows.count > fileListLimit,
            canRetry: allowsRetry,
            canExport: canExport,
            primaryAction: allowsRetry && needsRetry ? .retry : .newTransfer,
            showsNewTransfer: showsNewTransfer,
            newTransferHelp: destinations.isEmpty ? nil : "Start again with the same destinations",
            copySummary: makeCopySummary(
                safetyState: safetyState,
                cardName: card,
                sourceBytes: sourceBytes,
                destinations: destinationNames,
                algorithm: algorithm,
                reason: reason
            )
        )
    }

    // MARK: - Pieces

    /// Green only for a row that positively says it was verified; the same
    /// rule as the per-row symbol (`ResultStatusPresentation`).
    static func isVerified(_ row: ResultRow) -> Bool {
        row.isVerifiedStatus
    }

    /// Plain words for a row's status (audit L7: no emoji read aloud).
    static func statusLabel(for status: String) -> String {
        guard let outcome = ResultOutcome(statusText: status) else { return status }
        switch outcome {
        case .verified: return "Verified"
        case .copiedUnverified: return "Copied, not verified"
        case .checksumMismatch: return "Checksum mismatch"
        case .failed: return "Failed"
        }
    }

    /// Audit H12: one spoken stop per file result ("name, status, size,
    /// destination") instead of four or five separate VoiceOver stops per
    /// row, with no column names to say what "80 KB" means.
    static func accessibilityLabel(for row: ResultRow, destinationName: String? = nil) -> String {
        let name = URL(fileURLWithPath: row.path).lastPathComponent
        let status = statusLabel(for: row.status)
        let size = ByteCountPresentation.fileSize(row.size)
        let destination = destinationName ?? row.destination
        guard let destination, !destination.isEmpty else {
            return "\(name), \(status), \(size)"
        }
        return "\(name), \(status), \(size), \(destination)"
    }

    func emptyFileListText(issuesOnly: Bool) -> String {
        if rowCount == 0 {
            return isInterrupted
                ? "No files were recorded before the transfer was interrupted."
                : "No files were recorded."
        }
        return issuesOnly ? "No issues found." : "No files to show."
    }

    var truncationNote: String? {
        rowsTruncated
            ? "Showing \(Self.fileListLimit.formatted()) of \(rowCount.formatted()) files. Export a report for the full record."
            : nil
    }

    private static func makeIssueLines(
        safetyState: CardSafetyState,
        counts: OutcomeFileCounts,
        errorCount: Int,
        warningCount: Int
    ) -> [String] {
        // An interrupted run's unfinished files are not failures, and stopping
        // itself is logged as a warning: say neither.
        guard safetyState != .interrupted else { return [] }
        var lines: [String] = []
        if counts.needsAttention > 0 {
            lines.append(counts.needsAttention == 1
                ? "1 file failed"
                : "\(counts.needsAttention) files failed")
        }
        // Quick mode's headline already says "copied, not verified"; an
        // identical issue line under it would only repeat the verdict.
        if counts.copiedNotVerified > 0, safetyState != .copiedNotVerified {
            lines.append(counts.copiedNotVerified == 1
                ? "1 file copied, not verified"
                : "\(counts.copiedNotVerified) files copied, not verified")
        }
        if errorCount > 0 {
            lines.append(errorCount == 1 ? "1 reported error" : "\(errorCount) reported errors")
        }
        if warningCount > 0 {
            lines.append(warningCount == 1 ? "1 warning" : "\(warningCount) warnings")
        }
        return lines
    }

    private static func makeDurationLabel(safetyState: CardSafetyState, state: OperationState, seconds: TimeInterval) -> String {
        let text = durationText(seconds)
        switch safetyState {
        case .interrupted: return "Stopped after \(text)"
        case .failed: return "Ended after \(text)"
        case .safeToErase, .copiedNotVerified, .needsAttention:
            if case .completed = state { return "Completed in \(text)" }
            return "Ended after \(text)"
        case .waiting, .preparing, .copying, .verifying:
            return "Elapsed \(text)"
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(secs)s" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    static func phaseDurationText(
        copySeconds: TimeInterval?,
        verifySeconds: TimeInterval?,
        verificationMode: VerificationMode?
    ) -> String? {
        guard copySeconds != nil || verifySeconds != nil else { return nil }
        let copy = copySeconds.map(durationText) ?? "unavailable"
        let verify: String
        if verificationMode == .quick {
            verify = "not performed"
        } else {
            verify = verifySeconds.map(durationText) ?? "unavailable"
        }
        return "Copy \(copy), verify \(verify)"
    }

    private static func makeDestinationLines(rows: [ResultRow], destinations: [URL], interrupted: Bool) -> [OutcomeDestinationLine] {
        DestinationResultSummary.make(rows: rows, destinations: destinations).map { summary in
            guard interrupted else {
                return OutcomeDestinationLine(
                    id: summary.id,
                    title: destinationLabel(URL(fileURLWithPath: summary.id, isDirectory: true)),
                    detail: summary.detail,
                    needsAttention: summary.needsAttention
                )
            }
            let verified = summary.rows.filter(Self.isVerified).count
            let detail = summary.rows.isEmpty
                ? "Interrupted before any files were recorded"
                : "Interrupted: \(verified) of \(summary.rows.count) files verified before the stop"
            return OutcomeDestinationLine(
                id: summary.id,
                title: destinationLabel(URL(fileURLWithPath: summary.id, isDirectory: true)),
                detail: detail,
                needsAttention: true
            )
        }
    }

    private static func sourceEvidence(_ rows: [ResultRow]) -> (fileCount: Int, bytes: Int64) {
        var sizes: [String: Int64] = [:]
        for row in rows where sizes[row.path] == nil { sizes[row.path] = max(0, row.size) }
        return (sizes.count, sizes.values.reduce(0, +))
    }

    static func destinationDriveName(_ destination: URL) -> String {
        DestinationIdentityPresentation.title(for: destination)
    }

    static func shortenedDestinationName(_ name: String, limit: Int = 28) -> String {
        let characters = Array(name)
        guard limit >= 5, characters.count > limit else { return name }
        let visible = limit - 1
        let leading = (visible + 1) / 2
        let trailing = visible / 2
        return String(characters.prefix(leading)) + "…" + String(characters.suffix(trailing))
    }

    static func destinationLabel(_ destination: URL) -> String {
        let components = destination.standardizedFileURL.pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes" else {
            let drive = destinationDriveName(destination)
            let folder = destination.lastPathComponent
            return folder.isEmpty || folder == drive ? drive : "\(drive) › \(folder)"
        }
        let drive = components[2]
        let folderComponents = components.dropFirst(3)
        return folderComponents.isEmpty ? drive : "\(drive) › \(folderComponents.joined(separator: "/"))"
    }

    static func algorithmLabel(_ mode: VerificationMode?) -> String? {
        guard let mode else { return nil }
        switch mode {
        case .quick: return "Size check only"
        case .standard: return "SHA-256"
        case .thorough: return "SHA-256 + MD5"
        case .paranoid: return "Byte-by-byte + SHA-256"
        }
    }

    private static func issueReason(
        safetyState: CardSafetyState,
        completionDetail: String,
        counts: OutcomeFileCounts,
        errorCount: Int,
        warningCount: Int,
        completionReason: String?,
        rows: [ResultRow],
        destinations: [URL]
    ) -> String? {
        let recordedReason = completionReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch safetyState {
        case .needsAttention:
            if counts.needsAttention > 0 {
                let summaries = DestinationResultSummary.make(rows: rows, destinations: destinations)
                    .filter { $0.issueCount > 0 }
                if summaries.count == 1, let summary = summaries.first {
                    let name = shortenedDestinationName(
                        destinationDriveName(URL(fileURLWithPath: summary.id, isDirectory: true))
                    )
                    let files = summary.issueCount == 1 ? "1 file failed" : "\(summary.issueCount) files failed"
                    return "\(files) on \(name)"
                }
                return counts.needsAttention == 1 ? "1 file failed" : "\(counts.needsAttention) files failed"
            }
            if recordedReason?.isEmpty == false { return recordedReason }
            if errorCount > 0 { return errorCount == 1 ? "1 reported error" : "\(errorCount) reported errors" }
            if warningCount > 0 { return warningCount == 1 ? "1 warning" : "\(warningCount) warnings" }
            return completionDetail
        case .failed: return recordedReason?.isEmpty == false ? recordedReason : completionDetail
        default: return nil
        }
    }

    static func makeCopySummary(
        safetyState: CardSafetyState,
        cardName: String,
        sourceBytes: Int64?,
        destinations: [String],
        algorithm: String?,
        reason: String?
    ) -> String {
        if safetyState == .waiting { return "\(cardName) · not started" }
        let verdict: String
        switch safetyState {
        case .waiting: verdict = "not started"
        case .preparing: verdict = "preparing"
        case .copying: verdict = "copying"
        case .verifying: verdict = "verifying"
        case .safeToErase: verdict = "safe to erase"
        case .copiedNotVerified: verdict = "copied, not verified (size check only)"
        case .needsAttention: verdict = reason.map { "needs attention: \($0)" } ?? "needs attention"
        case .failed: verdict = reason.map { "failed: \($0)" } ?? "failed"
        case .interrupted: verdict = "interrupted"
        }
        var parts = [cardName]
        if let sourceBytes {
            parts.append(ByteCountPresentation.fileSize(sourceBytes))
        }
        parts.append(verdict)
        if safetyState.eraseWarning != nil { parts.append("do not erase the card") }
        // The algorithm names a check that passed, so only a safe card lists it.
        if let algorithm, safetyState == .safeToErase { parts.append(algorithm) }
        if !destinations.isEmpty { parts.append(destinations.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private static func bannerDetail(
        safetyState: CardSafetyState,
        sourceFileCount: Int,
        sourceBytes: Int64,
        destinations: [String],
        algorithm: String?,
        duration: TimeInterval?,
        reason: String?,
        fallback: String
    ) -> String {
        let destinationText = naturalList(destinations)
        switch safetyState {
        case .safeToErase:
            let files = sourceFileCount == 1 ? "1 file" : "\(sourceFileCount) files"
            let size = ByteCountPresentation.fileSize(sourceBytes)
            return ["\(files) · \(size) verified on \(destinationText)", algorithm, duration.map(durationText)]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .copiedNotVerified:
            return "Only file sizes were compared. Do not erase the card."
        case .needsAttention:
            return reason ?? fallback
        case .failed:
            let failure = reason ?? fallback
            let separator = failure.last.map { ".!?".contains($0) } == true ? " " : ". "
            return "\(failure)\(separator)Do not erase the card."
        case .interrupted:
            // The interrupted headline carries the card warning itself, since
            // `bannerGuidance` is suppressed for this state (no duplication).
            return "The transfer stopped before every destination was verified. Do not erase the card."
        case .waiting, .preparing, .copying, .verifying:
            return fallback
        }
    }

    private static func naturalList(_ values: [String]) -> String {
        switch values.count {
        case 0: return "the selected destinations"
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default: return values.dropLast().joined(separator: ", ") + ", and " + values.last!
        }
    }
}

/// Counts for a live results list, taken from the rows themselves.
struct LiveResultsCounts: Equatable {
    let verified: Int
    let copiedNotVerified: Int
    let issues: Int

    static func make(rows: [ResultRow]) -> Self {
        var verified = 0, copied = 0, issues = 0
        for row in rows {
            if !row.isSuccessStatus {
                issues += 1
            } else if TransferOutcomePresentation.isVerified(row) {
                verified += 1
            } else {
                copied += 1
            }
        }
        return Self(verified: verified, copiedNotVerified: copied, issues: issues)
    }

    /// What the "no issues" view says: "all verified" only when every row
    /// was verified (Promise 2).
    var noIssuesMessage: String? {
        switch (verified, copiedNotVerified) {
        case (0, 0): return nil
        case (_, 0): return "All \(verified) files verified"
        case (0, _): return "\(copiedNotVerified) files copied, not verified"
        default: return "\(verified) verified, \(copiedNotVerified) copied but not verified"
        }
    }
}
