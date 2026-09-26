import Foundation
import BitMatchEngine

struct PhotographerJobSetupPresentation: Equatable, Sendable {
    let presetTitle: String
    let collapsedSummary: String
    let pathPreview: String
    let blockers: [String]
    let duplicateWarningText: String?
    let duplicateLinkTitle: String?

    var canSetUpCard: Bool { blockers.isEmpty }

    /// One plain line under the fields: "Still needed: client, job name and
    /// camera." Nil when nothing is missing.
    var blockerSentence: String? {
        guard let first = blockers.first else { return nil }
        if blockers.count == 1, first.hasSuffix("preparing") { return first + "…" }
        let items = blockers.filter { !$0.hasSuffix("preparing") }
        guard !items.isEmpty else { return first + "…" }
        let list = items.count == 1 ? items[0]
            : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        return "Still needed: \(list)."
    }

    static func make(
        clientName: String,
        jobName: String,
        eventDate: Date,
        photographerName: String,
        cameraName: String,
        cardNumber: Int,
        recipe: FolderRecipe,
        workflow: ProjectWorkflow = .photography,
        duplicateWarningText: String?,
        hasSource: Bool = true,
        isPreparing: Bool = false
    ) -> Self {
        let cleanClient = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanJob = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPhotographer = photographerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCamera = cameraName.trimmingCharacters(in: .whitespacesAndNewlines)
        var blockers: [String] = []
        if cleanClient.isEmpty { blockers.append("client") }
        if cleanJob.isEmpty { blockers.append("job name") }
        if cleanPhotographer.isEmpty { blockers.append(workflow.contributorLabel.lowercased()) }
        if cleanCamera.isEmpty { blockers.append("camera") }
        if !hasSource { blockers.append("source \(workflow.sourceUnitLabel.lowercased())") }
        if isPreparing { blockers.append("\(workflow.sourceUnitLabel) setup is still preparing") }

        let rendered = try? FolderRecipeRenderer.render(
            recipe,
            context: FolderRecipeContext(
                eventDate: eventDate,
                jobName: cleanJob,
                photographer: cleanPhotographer,
                camera: cleanCamera,
                cardNumber: cardNumber
            )
        )

        return Self(
            presetTitle: recipe.name,
            collapsedSummary: [
                cleanJob,
                cleanPhotographer,
                cleanCamera,
                "\(workflow.sourceUnitLabel) " + String(format: "%03d", cardNumber)
            ].filter { !$0.isEmpty }.joined(separator: " · "),
            pathPreview: rendered?.relativePath ?? "Complete setup to preview the package path",
            blockers: blockers,
            duplicateWarningText: duplicateWarningText,
            duplicateLinkTitle: duplicateWarningText == nil ? nil : "Show earlier ingest"
        )
    }
}

struct PhotographerStartContext: Equatable, Sendable {
    let preflightReady: Bool
    let isPreparing: Bool
    let activeCardState: PhotographerLocalState?
    let sourceMatches: Bool
    let setupMatches: Bool
    let destinationCount: Int
    let requiredDestinationCount: Int
    let verificationMode: VerificationMode

    init(
        preflightReady: Bool,
        isPreparing: Bool,
        activeCardState: PhotographerLocalState?,
        sourceMatches: Bool,
        setupMatches: Bool,
        destinationCount: Int,
        requiredDestinationCount: Int,
        verificationMode: VerificationMode = .standard
    ) {
        self.preflightReady = preflightReady
        self.isPreparing = isPreparing
        self.activeCardState = activeCardState
        self.sourceMatches = sourceMatches
        self.setupMatches = setupMatches
        self.destinationCount = destinationCount
        self.requiredDestinationCount = requiredDestinationCount
        self.verificationMode = verificationMode
    }
}

struct PhotographerStartPresentation: Equatable, Sendable {
    let blocker: String?
    var canStart: Bool { blocker == nil }

    static func make(context: PhotographerStartContext) -> Self {
        let blocker: String?
        if !context.preflightReady {
            blocker = "Resolve transfer preflight issues"
        } else if context.isPreparing {
            blocker = "Card setup is still preparing"
        } else if context.activeCardState == nil {
            blocker = "Set up this card before starting"
        } else if context.activeCardState != .notStarted {
            blocker = "Set up the next card before starting"
        } else if context.verificationMode == .quick {
            blocker = "Photographer ingests require Standard, Thorough, or Paranoid verification; Quick mode cannot establish locally safe evidence."
        } else if !context.sourceMatches {
            blocker = "Source changed; set up the card again"
        } else if !context.setupMatches {
            blocker = "Setup changed; set up the card again"
        } else if context.destinationCount < context.requiredDestinationCount {
            let missing = context.requiredDestinationCount - context.destinationCount
            let noun = missing == 1 ? "destination" : "destinations"
            blocker = "Add \(missing) more \(noun) for this \(context.requiredDestinationCount)-copy job"
        } else {
            blocker = nil
        }
        return Self(blocker: blocker)
    }
}

struct RemoteBackupStatusPresentation: Equatable, Sendable {
    let title: String
    let symbol: String
    let isFullyBackedUp: Bool
    let isWarning: Bool
    /// Audit M11: a failed off-site backup is an error, not merely a
    /// warning like "retrying" or "unverified" — it needs the red tint.
    var isError: Bool = false
    /// The underlying item state, so views can offer valid next actions
    /// (retry for parked/failed work, cancel for runnable work).
    let state: RemoteBackupState

    static func make(summary: RemoteBackupCardSummary) -> Self {
        make(state: summary.state, evidence: summary.verificationEvidence)
    }

    static func make(
        state: RemoteBackupState,
        evidence: RemoteVerificationEvidence
    ) -> Self {
        switch state {
        case .queued:
            return Self(title: "Remote Queued", symbol: "clock", isFullyBackedUp: false, isWarning: false, state: state)
        case .uploading:
            return Self(title: "Remote Uploading", symbol: "arrow.up.circle", isFullyBackedUp: false, isWarning: false, state: state)
        case .retrying:
            return Self(title: "Remote Retrying", symbol: "arrow.clockwise", isFullyBackedUp: false, isWarning: true, state: state)
        case .paused:
            return Self(title: "Remote Paused", symbol: "pause.circle", isFullyBackedUp: false, isWarning: true, state: state)
        case .uploadedUnverified:
            return Self(title: "Uploaded · Unverified", symbol: "exclamationmark.shield", isFullyBackedUp: false, isWarning: true, state: state)
        case .verifying:
            return Self(title: "Remote Verifying", symbol: "checkmark.shield", isFullyBackedUp: false, isWarning: false, state: state)
        case .verified where evidence.digest != nil:
            return Self(title: "Fully Backed Up", symbol: "checkmark.icloud.fill", isFullyBackedUp: true, isWarning: false, state: state)
        case .verified:
            return Self(title: "Verification Evidence Missing", symbol: "exclamationmark.shield", isFullyBackedUp: false, isWarning: true, state: state)
        case .failed:
            return Self(title: "Remote Failed", symbol: "exclamationmark.triangle.fill", isFullyBackedUp: false, isWarning: false, isError: true, state: state)
        case .cancelled:
            return Self(title: "Remote Cancelled", symbol: "xmark.circle.fill", isFullyBackedUp: false, isWarning: true, state: state)
        case .conflict:
            return Self(title: "Remote Conflict", symbol: "arrow.triangle.branch", isFullyBackedUp: false, isWarning: true, state: state)
        }
    }
}

/// Keeps the optional off-site choice compact until a photographer elects to
/// configure it. This contains profile metadata only; credentials stay in the
/// Keychain/SSH agent boundary.
struct RemoteBackupDestinationPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let isExpanded: Bool

    static func make(isEnabled: Bool, profiles: [RemoteDestinationProfile]) -> Self {
        Self(
            title: "Off-site Backup",
            detail: isEnabled ? (profiles.isEmpty ? "No saved destinations" : "Configured") : "Optional",
            isExpanded: isEnabled
        )
    }
}

struct PhotographerCardRowPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let photographerName: String
    let cameraName: String
    let cardTitle: String
    let fileCountTitle: String
    let byteCountTitle: String
    let renderedPath: String
    let statusTitle: String
    let status: ResultStatusPresentation
    let verifiedDestinationCount: Int
    let verifiedCopyTitle: String
    let remoteBackupPresentations: [UUID: RemoteBackupStatusPresentation]

    var statusSymbol: String { status.symbol }

    static func make(
        card: CardIngest,
        verifiedDestinationCount: Int,
        requiredCopyCount: Int = 0,
        workflow: ProjectWorkflow = .photography
    ) -> Self {
        let copyTitle = requiredCopyCount > 0
            ? "\(verifiedDestinationCount) of \(requiredCopyCount) verified"
            : "\(verifiedDestinationCount) verified destinations"
        return Self(
            id: card.id,
            photographerName: card.provenance.photographerName,
            cameraName: card.provenance.cameraName,
            cardTitle: "\(workflow.sourceUnitLabel) " + String(format: "%03d", card.provenance.cardNumber),
            fileCountTitle: formattedFileCount(card.fileCount),
            byteCountTitle: ByteCountPresentation.fileSize(card.totalBytes),
            renderedPath: card.renderedRelativePath,
            statusTitle: statusTitle(for: card.localState),
            status: .make(localState: card.localState),
            verifiedDestinationCount: verifiedDestinationCount,
            verifiedCopyTitle: copyTitle,
            remoteBackupPresentations: card.remoteBackupSummaries.mapValues(RemoteBackupStatusPresentation.make)
        )
    }

    private static func statusTitle(for state: PhotographerLocalState) -> String {
        switch state {
        case .notStarted: return "Not Started"
        case .copying: return "Copying"
        case .verifying: return "Verifying"
        case .locallySafe: return "Locally Safe"
        case .issues: return "Issues"
        case .cancelled: return "Cancelled"
        }
    }

    private static func formattedFileCount(_ count: Int) -> String {
        let formatted = count.formatted(.number)
        return count == 1 ? "\(formatted) file" : "\(formatted) files"
    }
}

struct PhotographerSessionPresentation: Equatable, Sendable {
    let title: String
    let requiredCopyTitle: String
    let rows: [PhotographerCardRowPresentation]

    static func make(job: PhotographerJob) -> Self {
        let sortedCards = job.cardIngests.sorted { lhs, rhs in
            let lhsPending = lhs.localState == .notStarted
            let rhsPending = rhs.localState == .notStarted
            if lhsPending != rhsPending { return lhsPending }
            let lhsDate = lhs.startedAt ?? .distantPast
            let rhsDate = rhs.startedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.provenance.cardNumber > rhs.provenance.cardNumber
        }
        let required = job.requiredLocalCopyCount
        let rows = sortedCards.map { card in
            return PhotographerCardRowPresentation.make(
                card: card,
                verifiedDestinationCount: card.verifiedDestinationCount,
                requiredCopyCount: required,
                workflow: job.workflow
            )
        }
        let copyNoun = required == 1 ? "copy" : "copies"
        return Self(
            title: "\(job.jobName) session",
            requiredCopyTitle: "\(required) verified local \(copyNoun) required",
            rows: rows
        )
    }
}
