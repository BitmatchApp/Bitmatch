import Foundation
import BitMatchEngine

/// The finish screen's headline, sub-line, symbol and one plain safety
/// sentence for a `CompletionVerdict`. Plain American English throughout: no
/// engine jargon ("handoff records", "transfer evidence"), and the same
/// vocabulary `TransferFinishNotice` uses for the background notification, so
/// the screen and the notification always agree.
struct CompletionVerdictPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let symbol: String
    let sourceGuidance: String

    static func make(
        _ verdict: CompletionVerdict,
        cardName: String = "",
        backupCount: Int = 0,
        issueCount: Int = 0
    ) -> Self {
        // A real card name reads fine anywhere in a sentence; the generic
        // fallback needs "The card" to open a sentence and "the card"
        // everywhere else, or "Keep The card" reads as a typo.
        let card = cardName.isEmpty ? "the card" : cardName
        let safetyState = CardSafetyState.make(
            state: .completed(.init(success: verdict == .success, message: "")),
            verdict: verdict
        )
        switch safetyState {
        case .safeToErase:
            let backups = backupCount == 1 ? "1 backup" : "\(backupCount) backups"
            return Self(
                title: safetyState.headline(cardName: cardName),
                detail: "Copied to \(backups) and verified.",
                symbol: safetyState.symbol,
                sourceGuidance: "Every file on every backup was read back and matched the card."
            )
        case .copiedNotVerified:
            return Self(
                title: safetyState.headline(cardName: cardName),
                detail: "Quick mode only compares file sizes, not what's inside the files.",
                symbol: safetyState.symbol,
                sourceGuidance: "Do not erase \(card). Run a verified copy first; Quick mode can't confirm every file arrived intact."
            )
        case .needsAttention:
            let files = issueCount == 1 ? "1 file" : "\(issueCount) files"
            return Self(
                title: safetyState.headline(cardName: cardName),
                detail: "\(files) had problems. Review them below.",
                symbol: safetyState.symbol,
                sourceGuidance: "Do not erase \(card) until every file below is resolved."
            )
        case .failed:
            return Self(
                title: safetyState.headline(cardName: cardName),
                detail: "No files were confirmed copied and verified.",
                symbol: safetyState.symbol,
                sourceGuidance: "Do not erase \(card). Nothing here has been confirmed safe."
            )
        case .waiting, .preparing, .copying, .verifying, .interrupted:
            preconditionFailure("A completion verdict must produce a finish state")
        }
    }

    static func make(
        state: OperationState,
        rows: [ResultRow],
        hasErrors: Bool,
        hasCriticalErrors: Bool,
        cardName: String = "",
        backupCount: Int = 0
    ) -> Self {
        let card = cardName.isEmpty ? "the card" : cardName
        // A cancelled operation keeps its partial results, but it is not
        // an issue state: label it plainly instead of "Review required".
        if state == .cancelled {
            return Self(
                title: CardSafetyState.interrupted.headline(cardName: cardName),
                detail: "The transfer stopped before every backup was verified.",
                symbol: CardSafetyState.interrupted.symbol,
                sourceGuidance: "Do not erase \(card)."
            )
        }
        let verdict = CompletionVerdict.resolve(
            state: state,
            rows: rows,
            hasErrors: hasErrors,
            hasCriticalErrors: hasCriticalErrors
        )
        let issueCount = rows.filter { !$0.isSuccessStatus }.count
        let presentation = make(verdict, cardName: cardName, backupCount: backupCount, issueCount: issueCount)
        if case .completed(let info) = state, !info.success {
            return Self(
                title: presentation.title,
                detail: info.message,
                symbol: presentation.symbol,
                sourceGuidance: "Do not erase \(card) until the problems are resolved."
            )
        }
        return presentation
    }
}
