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
            let backups = backupCount == 1 ? "1 destination" : "\(backupCount) destinations"
            return Self(
                title: safetyState.headline(cardName: cardName),
                detail: "Copied to \(backups) and verified.",
                symbol: safetyState.symbol,
                sourceGuidance: "BitMatch read every file on every backup and checked it against the bytes it read from the card."
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
                detail: issueCount == 0
                    ? "The saved results don't confirm the full transfer. Review them below."
                    : "\(files) had problems. Review them below.",
                symbol: safetyState.symbol,
                sourceGuidance: "Do not erase \(card). These results don't establish a complete verified backup."
            )
        case .failed:
            return Self(
                title: safetyState.headline(cardName: cardName),
                detail: "The transfer did not finish safely. Review any recorded results below.",
                symbol: safetyState.symbol,
                sourceGuidance: "Do not erase \(card). The transfer did not finish safely."
            )
        case .waiting, .preparing, .copying, .verifying, .finishing, .interrupted:
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
                detail: "The transfer stopped before every destination was verified.",
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
                sourceGuidance: presentation.sourceGuidance
            )
        }
        return presentation
    }
}
