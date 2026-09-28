import Foundation

struct QueueAttentionToken: Hashable, Sendable {
    let recordID: UUID
    let state: String
    let reason: String?
}

/// The platform-neutral summary used by the iOS queue bar and the collapsed
/// iPad inspector control. Green is reserved for `.safeToErase` verdicts.
struct QueueAccessoryPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case neutral, progress, safeToErase, warning, failure
    }

    let title: String
    let detail: String?
    let backgroundMessage: String?
    let symbol: String
    let tone: Tone
    let progressFraction: Double?
    let attentionRecordID: UUID?

    var isVisible: Bool { !title.isEmpty }
    var accessibilityLabel: String {
        [title, detail, backgroundMessage].compactMap { $0 }.joined(separator: ". ")
    }

    static let hidden = Self(
        title: "", detail: nil, backgroundMessage: nil, symbol: "tray",
        tone: .neutral, progressFraction: nil, attentionRecordID: nil
    )

    static func make(
        queue: QueueSessionPresentation,
        timeRemaining: String? = nil,
        backgroundMessage: String? = nil,
        flashedSafeRecordID: UUID? = nil,
        acknowledgedAttention: Set<QueueAttentionToken> = [],
        isQueueRunning: Bool = false
    ) -> Self {
        guard !queue.rows.isEmpty else { return .hidden }

        let running = queue.rows.first(where: \QueueSessionRow.isRunning)
        let problems = queue.rows.filter { row in
            switch row.safetyState {
            case .copiedNotVerified: running == nil && !isQueueRunning
            case .needsAttention, .failed, .interrupted: true
            default: false
            }
        }
        let unacknowledgedProblem = problems.first {
            guard let token = attentionToken(for: $0) else { return true }
            return !acknowledgedAttention.contains(token)
        }

        // A completion flash may replace progress, but never an unopened issue.
        if let problem = unacknowledgedProblem ?? (running == nil ? problems.first : nil) {
            return problemPresentation(problem)
        }

        if let flashedSafeRecordID,
           let row = queue.rows.first(where: {
               $0.id == flashedSafeRecordID && $0.safetyState == .safeToErase
           }) {
            return Self(
                title: "\(row.cardName) · safe to erase",
                detail: queuePosition(of: row.id, rows: queue.rows),
                backgroundMessage: nil,
                symbol: "checkmark.circle.fill",
                tone: .safeToErase,
                progressFraction: nil,
                attentionRecordID: nil
            )
        }

        if let running, let index = queue.rows.firstIndex(where: { $0.id == running.id }) {
            let completed = queue.rows.filter(\.isFinished).count
            let cardProgress = min(max(running.progressFraction ?? 0, 0), 1)
            let overall = min(
                max((Double(completed) + cardProgress) / Double(queue.rows.count), 0),
                1
            )
            var details = ["\(index + 1) of \(queue.rows.count)", percent(overall)]
            if let timeRemaining { details.append("\(timeRemaining) left") }
            return Self(
                title: running.cardName,
                detail: details.joined(separator: " · "),
                backgroundMessage: backgroundMessage,
                symbol: "arrow.triangle.2.circlepath",
                tone: .progress,
                progressFraction: overall,
                attentionRecordID: nil
            )
        }

        if queue.rows.allSatisfy({ $0.safetyState == .safeToErase }) {
            return Self(
                title: "All cards safe to erase",
                detail: "\(queue.rows.count) of \(queue.rows.count) verified",
                backgroundMessage: nil,
                symbol: "checkmark.circle.fill",
                tone: .safeToErase,
                progressFraction: 1,
                attentionRecordID: nil
            )
        }

        let waiting = queue.rows.filter(\.isEditable).count
        return Self(
            title: waiting == 1 ? "1 card in queue" : "\(waiting) cards in queue",
            detail: queue.summaryTitle ?? "Ready to start",
            backgroundMessage: nil,
            symbol: "tray.full",
            tone: .neutral,
            progressFraction: nil,
            attentionRecordID: nil
        )
    }

    private static func problemPresentation(_ row: QueueSessionRow) -> Self {
        let failure = row.safetyState == .failed
        return Self(
            title: "\(row.cardName) · \(row.statusText.lowercased())",
            detail: row.cause,
            backgroundMessage: nil,
            symbol: failure ? "xmark.octagon.fill" : "exclamationmark.triangle.fill",
            tone: failure ? .failure : .warning,
            progressFraction: nil,
            attentionRecordID: row.id
        )
    }

    static func attentionTokens(in rows: [QueueSessionRow]) -> Set<QueueAttentionToken> {
        Set(rows.compactMap(attentionToken(for:)))
    }

    static func reconciledAcknowledgements(
        _ acknowledged: Set<QueueAttentionToken>,
        with rows: [QueueSessionRow]
    ) -> Set<QueueAttentionToken> {
        acknowledged.intersection(attentionTokens(in: rows))
    }

    private static func attentionToken(for row: QueueSessionRow) -> QueueAttentionToken? {
        switch row.safetyState {
        case .copiedNotVerified, .needsAttention, .failed, .interrupted:
            QueueAttentionToken(recordID: row.id, state: row.statusText, reason: row.cause)
        default:
            nil
        }
    }

    private static func queuePosition(of id: UUID, rows: [QueueSessionRow]) -> String? {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return "\(index + 1) of \(rows.count)"
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))%"
    }
}
