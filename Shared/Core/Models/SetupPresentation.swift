import Foundation
import BitMatchEngine

enum SetupStartPolicy {
    /// Every ready one-time card enters the journal-backed queue before it
    /// runs, including a single card that is still in the composer.
    static func startsSetupBatch(
        stagedCardCount: Int,
        hasComposerCard: Bool,
        isOperationInProgress: Bool
    ) -> Bool {
        (stagedCardCount > 0 || hasComposerCard) && !isOperationInProgress
    }
}

/// The Start button on Setup, on every platform (UI plan step 4.8): its
/// title, whether it can be pressed, and the one line under it.
///
/// Rules, in order:
/// - A running transfer disables Start.
/// - A source or backup not chosen yet is the next step: the button names it
///   and the empty box glows (`nextStepHighlight`). No banner, no reason line.
/// - Project chosen but no card prepared: Start stays disabled and names the
///   step, and the project setup card glows (thesis decision S-2, the iPad
///   rule: choosing Project never quietly runs a plain transfer).
/// - Otherwise the readiness rule decides (`OperationReadinessAssessment`,
///   through `TransferPlanPresentation`), plus the project card's own gate.
struct StartButtonPresentation: Equatable, Sendable {
    enum NextStep: Equatable, Sendable {
        case chooseSource
        case addBackup
        case prepareCard
    }

    let title: String
    let symbol: String
    let canStart: Bool
    /// Starts through `startProjectOperation()` rather than a plain transfer.
    let startsProject: Bool
    /// The step not taken yet, highlighted instead of explained.
    let nextStep: NextStep?
    /// A real reason Start is disabled. Nil when the button already names
    /// the next step, or when Start is enabled.
    let blocker: String?
    /// Shown when Start is enabled: what will happen.
    let readyLine: String?
    let accessibilityHint: String

    static func make(
        plan: TransferPlanPresentation,
        usesProjectWorkflow: Bool,
        hasPreparedCard: Bool,
        projectBlocker: String?,
        projectUnit: String,
        isOperationInProgress: Bool,
        isQueuePaused: Bool = false,
        hasComposerCard: Bool,
        composerDestinationNames: [String] = [],
        composerDestinationIdentities: [String] = [],
        stagedCardCount: Int = 0,
        stagedDestinationNames: [[String]] = [],
        stagedDestinationIdentities: [[String]] = [],
        stagedVerificationModes: [VerificationMode] = [],
        sourceFileCount: Int?,
        sourceBytes: Int64?,
        destinationCount: Int
    ) -> Self {
        let isProject = usesProjectWorkflow || hasPreparedCard
        let unit = projectUnit.lowercased()
        let cardCount = stagedCardCount + (hasComposerCard ? 1 : 0)
        let composerRoute = composerDestinationNames.isEmpty ? plan.destinationTitles : composerDestinationNames
        let destinationRoutes = stagedDestinationNames + (hasComposerCard ? [composerRoute] : [])
        let destinationRouteIdentities = stagedDestinationIdentities
            + (hasComposerCard ? [composerDestinationIdentities] : [])

        if isOperationInProgress {
            return Self(
                title: "Transfer in progress",
                symbol: "hourglass",
                canStart: false,
                startsProject: isProject,
                nextStep: nil,
                blocker: nil,
                readyLine: nil,
                accessibilityHint: "A transfer is already running"
            )
        }

        if isQueuePaused {
            return Self(
                title: "Start",
                symbol: "play.fill",
                canStart: false,
                startsProject: isProject,
                nextStep: nil,
                blocker: nil,
                readyLine: nil,
                accessibilityHint: "Review, skip, or remove the paused card first"
            )
        }

        if sourceFileCount == 0 {
            return Self(
                title: "Source is empty",
                symbol: "tray",
                canStart: false,
                startsProject: isProject,
                nextStep: nil,
                blocker: "Choose a source that contains files.",
                readyLine: nil,
                accessibilityHint: "The selected source folder is empty"
            )
        }

        if let step = plan.nextStep {
            if step == .chooseSource, stagedCardCount > 0, !isProject {
                return Self(
                    title: startTitle(
                        cardCount: stagedCardCount,
                        fallback: singleTransferTitle(
                            verificationMode: stagedVerificationModes.first ?? plan.verificationMode
                        )
                    ),
                    symbol: "play.fill",
                    canStart: true,
                    startsProject: false,
                    nextStep: nil,
                    blocker: nil,
                    readyLine: readyCardsLine(
                        cardCount: stagedCardCount,
                        destinationRoutes: destinationRoutes,
                        destinationRouteIdentities: destinationRouteIdentities
                    ),
                    accessibilityHint: "Starts each staged card in queue order and leaves every source unchanged"
                )
            }
            return Self(
                title: plan.actionTitle,
                symbol: "arrow.up",
                canStart: false,
                startsProject: isProject,
                nextStep: step == .chooseSource ? NextStep.chooseSource : NextStep.addBackup,
                blocker: nil,
                readyLine: nil,
                accessibilityHint: step == .chooseSource
                    ? "Choose the card or folder to copy first"
                    : "Add a folder on a destination drive first"
            )
        }

        let planBlocker: String?
        if case .analyzing = plan.status {
            planBlocker = nil
        } else {
            planBlocker = plan.canStart ? nil : TransferPlanStatusDisplay.make(plan.status).detail
        }

        if isProject && !hasPreparedCard {
            return Self(
                title: "Set up the \(unit) to start",
                symbol: "arrow.up",
                canStart: false,
                startsProject: true,
                nextStep: .prepareCard,
                // A real problem still gets its line; the missing card
                // setup is named by the button and the glow.
                blocker: planBlocker,
                readyLine: nil,
                accessibilityHint: "Fill in project setup and set up the \(unit) first"
            )
        }

        let canStart: Bool
        let blocker: String?
        let title: String
        if isProject {
            canStart = plan.canStart && projectBlocker == nil
            blocker = canStart ? nil : (planBlocker ?? projectBlocker)
            title = "Start project transfer"
        } else {
            canStart = plan.canStart
            blocker = planBlocker
            title = startTitle(cardCount: cardCount, fallback: plan.actionTitle)
        }

        return Self(
            title: title,
            symbol: canStart ? "play.fill" : "exclamationmark.triangle.fill",
            canStart: canStart,
            startsProject: isProject,
            nextStep: nil,
            blocker: blocker,
            readyLine: canStart
                ? (cardCount > 1
                    ? readyCardsLine(
                        cardCount: cardCount,
                        destinationRoutes: destinationRoutes,
                        destinationRouteIdentities: destinationRouteIdentities
                    )
                    : readyLine(fileCount: sourceFileCount, bytes: sourceBytes, destinationCount: destinationCount))
                : nil,
            accessibilityHint: canStart
                ? (cardCount > 1
                    ? "Starts each card in queue order and leaves every source unchanged"
                    : "Copies files to each destination and leaves the source unchanged")
                : (blocker ?? "Not ready to start")
        )
    }

    private static func startTitle(cardCount: Int, fallback: String) -> String {
        cardCount > 1 ? "Start \(cardCount) transfers" : fallback
    }

    private static func singleTransferTitle(verificationMode: VerificationMode) -> String {
        verificationMode == .quick
            ? "Start copy without checksum verification"
            : "Start verified copy"
    }

    private static func readyCardsLine(
        cardCount: Int,
        destinationRoutes: [[String]],
        destinationRouteIdentities: [[String]]
    ) -> String {
        let cards = cardCount == 1 ? "1 card" : "\(cardCount) cards"
        guard let firstRoute = destinationRoutes.first else {
            return "Ready to copy \(cards). Source files stay in place."
        }
        let usesIdentities = destinationRouteIdentities.count == destinationRoutes.count
            && destinationRouteIdentities.allSatisfy { !$0.isEmpty }
        let routesForComparison = usesIdentities ? destinationRouteIdentities : destinationRoutes
        func normalized(_ route: [String]) -> [String] {
            usesIdentities ? route.sorted() : normalizedDestinationRoute(route)
        }
        let baseline = normalized(routesForComparison[0])
        let differentCount = routesForComparison.dropFirst().filter {
            normalized($0) != baseline
        }.count
        if differentCount > 0 {
            let verb = differentCount == 1 ? "goes" : "go"
            return "Ready to copy \(cards); \(differentCount) \(verb) to different destinations."
        }
        let destinations = joinedDestinationNames(firstRoute)
        guard !destinations.isEmpty else {
            return "Ready to copy \(cards). Source files stay in place."
        }
        return "Ready to copy \(cards) to \(destinations). Source files stay in place."
    }

    private static func normalizedDestinationRoute(_ names: [String]) -> [String] {
        names.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }.sorted()
    }

    private static func joinedDestinationNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and \(names.last ?? "")"
        }
    }

    private static func readyLine(fileCount: Int?, bytes: Int64?, destinationCount: Int) -> String {
        let backups = destinationCount == 1 ? "1 destination" : "\(destinationCount) destinations"
        guard let fileCount, let bytes else {
            return "Copies to \(backups). Source files stay in place."
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: fileCount)) ?? "\(fileCount)"
        let files = fileCount == 1 ? "1 file" : "\(count) files"
        let size = ByteCountPresentation.fileSize(bytes)
        return "Ready to copy \(files) (\(size)) to \(backups). Source files stay in place."
    }
}

/// Everything the Setup screen shows, built from values so every platform
/// renders the same thing for the same selection.
struct SetupPresentation: Equatable {
    let plan: TransferPlanPresentation
    let start: StartButtonPresentation
    let workflow: TransferWorkflowPresentation
    /// A prepared card keeps the workflow on Project until it runs.
    let isWorkflowLocked: Bool
    let showsProjectSetup: Bool
    let showsProjectEvidence: Bool
    /// Setup always reserves its Start row. A paused queue keeps a disabled
    /// Start while its inline card owns all recovery actions.
    let showsStartArea: Bool

    static func make(
        plan: TransferPlanPresentation,
        usesProjectWorkflow: Bool,
        hasPreparedCard: Bool,
        projectBlocker: String?,
        projectUnit: String,
        isOperationInProgress: Bool,
        isQueuePaused: Bool = false,
        hasComposerCard: Bool,
        composerDestinationNames: [String] = [],
        composerDestinationIdentities: [String] = [],
        stagedCardCount: Int = 0,
        stagedDestinationNames: [[String]] = [],
        stagedDestinationIdentities: [[String]] = [],
        stagedVerificationModes: [VerificationMode] = [],
        sourceFileCount: Int?,
        sourceBytes: Int64?,
        destinationCount: Int,
        hasProjectEvidence: Bool
    ) -> Self {
        let isProject = usesProjectWorkflow || hasPreparedCard
        return Self(
            plan: plan,
            start: StartButtonPresentation.make(
                plan: plan,
                usesProjectWorkflow: usesProjectWorkflow,
                hasPreparedCard: hasPreparedCard,
                projectBlocker: projectBlocker,
                projectUnit: projectUnit,
                isOperationInProgress: isOperationInProgress,
                isQueuePaused: isQueuePaused,
                hasComposerCard: hasComposerCard,
                composerDestinationNames: composerDestinationNames,
                composerDestinationIdentities: composerDestinationIdentities,
                stagedCardCount: stagedCardCount,
                stagedDestinationNames: stagedDestinationNames,
                stagedDestinationIdentities: stagedDestinationIdentities,
                stagedVerificationModes: stagedVerificationModes,
                sourceFileCount: sourceFileCount,
                sourceBytes: sourceBytes,
                destinationCount: destinationCount
            ),
            workflow: isProject ? .project : .quick,
            isWorkflowLocked: hasPreparedCard,
            showsProjectSetup: isProject,
            showsProjectEvidence: hasProjectEvidence,
            showsStartArea: true
        )
    }
}

/// Decision S-3: at launch the Mac puts back the last-used backups only
/// when every one of them is still there. A partial set could quietly send
/// a card to fewer backups than last time, so it restores nothing instead.
/// The same holds when `BackupTargetPolicy` refuses one of them for a
/// restore (`refusal`): a saved temp folder or system volume is never put
/// back, and neither is the rest of that list.
enum LastBackupsRestorePolicy {
    static func backupsToRestore(
        savedPaths: [String],
        exists: (String) -> Bool,
        refusal: (URL) -> String? = { _ in nil }
    ) -> [URL] {
        guard !savedPaths.isEmpty, savedPaths.allSatisfy(exists) else { return [] }
        let urls = savedPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        for url in urls {
            if let reason = refusal(url) {
                SharedLogger.info("Not restoring last backups: \(url.path): \(reason)", category: .transfer)
                return []
            }
        }
        return urls
    }
}
