// TransferFinishNotice.swift - What the "transfer finished" notification says.
import Foundation
import BitMatchEngine

/// The notification sent when a transfer ends while BitMatch is in the
/// background. Only a real success says the card is safe to erase
/// (Promise 2).
struct TransferFinishNotice: Equatable, Sendable {
    let title: String
    let body: String
    let kind: TransferNotificationKind

    init(title: String, body: String, kind: TransferNotificationKind) {
        self.title = title
        self.body = body
        self.kind = kind
    }

    static func make(
        state: OperationState,
        record: LocalTransferRecord,
        issueCount: Int,
        kind: TransferNotificationKind
    ) -> TransferFinishNotice? {
        make(
            state: state,
            sourceName: record.title,
            destinations: record.destinations.map(\.url),
            issueCount: issueCount,
            kind: kind
        )
    }

    /// `nil` while a transfer is active or has not started. `kind` is how
    /// the finish is routed (standalone or queued card); anything that is
    /// not safe or a clean Quick copy is always an attention notice.
    static func make(
        state: OperationState,
        sourceName: String,
        destinations: [URL],
        issueCount: Int,
        kind: TransferNotificationKind
    ) -> TransferFinishNotice? {
        let card = sourceName.isEmpty ? "The card" : sourceName
        let verdict = completionVerdict(state: state, issueCount: issueCount)
        let safetyState = CardSafetyState.make(state: state, verdict: verdict)
        switch safetyState {
        case .safeToErase:
            let names = destinations.map(TransferOutcomePresentation.destinationDriveName)
            return .init(title: "\(card) is safe to erase", body: "Verified on \(naturalList(names)).", kind: kind)
        case .copiedNotVerified:
            guard kind != .queuedCardSuccess else { return nil }
            return .init(title: "\(card) was copied without checksum verification", body: "Do not erase the card.", kind: kind)
        case .needsAttention:
            return .init(title: "\(card) needs attention", body: "Do not erase the card.", kind: .attention)
        case .failed:
            return .init(title: "\(card) failed", body: "Do not erase the card.", kind: .attention)
        case .interrupted:
            return .init(title: "\(card) was interrupted", body: "Do not erase the card.", kind: .attention)
        case .waiting, .preparing, .copying, .verifying:
            return nil
        }
    }

    static func queueFinished(title: String, tally: String) -> TransferFinishNotice {
        .init(title: "\(title): \(tally)", body: "", kind: .queueFinished)
    }

    private static func completionVerdict(state: OperationState, issueCount: Int) -> CompletionVerdict {
        switch state {
        case .completed(let info) where info.success && issueCount == 0: return .success
        case .completed(let info) where info.copiedNotVerified && issueCount == 0: return .copiedNotVerified
        case .completed: return .issues
        case .failed: return .failed
        default: return .issues
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
