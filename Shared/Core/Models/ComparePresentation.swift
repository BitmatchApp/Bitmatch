import Foundation
import BitMatchEngine

// Compare readiness and outcome, shared by Mac, iPad and iPhone (UI plan
// step 4.1). Every rule that decides whether Compare can start, and what the
// finished compare says, lives here as a pure function so the platforms cannot
// drift apart and each rule can be tested without a view.

// MARK: - What each verification mode checks in Compare

// MARK: - Folder slots

/// One side of the compare, as the screen shows it.
struct CompareFolderSlot: Equatable, Sendable {
    let url: URL?
    let fileCount: Int?
    let totalSize: Int64?
    /// Folder details are still being read for `url`.
    let isLoading: Bool

    var name: String? { url?.lastPathComponent }
    var path: String? { url?.path }

    /// `infoURL` is the folder the details were read from. Details left over
    /// from a previous pick are ignored, so a slot never shows another
    /// folder's counts and never counts as loaded early.
    static func make(
        url: URL?,
        infoURL: URL?,
        fileCount: Int?,
        totalSize: Int64?,
        isFetching: Bool
    ) -> Self {
        guard let url else {
            return Self(url: nil, fileCount: nil, totalSize: nil, isLoading: false)
        }
        let infoIsCurrent = infoURL.map { $0.standardizedFileURL == url.standardizedFileURL } ?? false
        let hasInfo = infoIsCurrent && fileCount != nil
        return Self(
            url: url,
            fileCount: hasInfo ? fileCount : nil,
            totalSize: hasInfo ? totalSize : nil,
            isLoading: isFetching && !hasInfo
        )
    }

    var fileCountText: String? {
        fileCount.map { count in
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            return count == 1 ? "1 file" : "\(formatted) files"
        }
    }

    var sizeText: String? {
        totalSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// Shown when a folder is chosen but its details could not be read.
    /// Compare still runs: it opens the folder itself and reports failures.
    var detailsUnavailable: Bool { url != nil && !isLoading && fileCount == nil }
}

// MARK: - Readiness

/// Why two chosen folders cannot be compared.
enum CompareBlock: Equatable, Sendable {
    case sameFolder
    case rightInsideLeft
    case leftInsideRight

    /// Same or nested folders. A folder compared with itself always "matches",
    /// which would be a false green (THESIS promise 2, decision C-1).
    static func check(left: URL, right: URL) -> CompareBlock? {
        switch SafetyValidator.folderOverlap(left, right) {
        case .same: return CompareBlock.sameFolder
        case .secondInsideFirst: return CompareBlock.rightInsideLeft
        case .firstInsideSecond: return CompareBlock.leftInsideRight
        case nil: return nil
        }
    }

    var message: String {
        switch self {
        case .sameFolder:
            "Both sides are the same folder. Choose two different folders."
        case .rightInsideLeft:
            "The right folder is inside the left folder. Choose two separate folders."
        case .leftInsideRight:
            "The left folder is inside the right folder. Choose two separate folders."
        }
    }
}

enum CompareReadiness: Equatable, Sendable {
    case needsLeft
    case needsRight
    case blocked(CompareBlock)
    /// A folder's details are still loading.
    case loading
    /// A compare (or any other operation) is running.
    case running
    case ready

    var canStart: Bool { self == .ready }

    static func resolve(left: CompareFolderSlot, right: CompareFolderSlot, isRunning: Bool) -> Self {
        if isRunning { return .running }
        guard let leftURL = left.url else { return .needsLeft }
        guard let rightURL = right.url else { return .needsRight }
        if let block = CompareBlock.check(left: leftURL, right: rightURL) { return .blocked(block) }
        if left.isLoading || right.isLoading { return .loading }
        return .ready
    }

    /// The reason line under a disabled Compare button. Nil when ready.
    var message: String? {
        switch self {
        case .needsLeft: "Choose the reference folder, the one you trust."
        case .needsRight: "Choose the folder to check against the reference."
        case .blocked(let block): block.message
        case .loading: "Reading folder details…"
        case .running: "A compare is running."
        case .ready: nil
        }
    }
}

// MARK: - Outcome

/// How the last compare ended, recorded by `SharedAppCoordinator`. Kept apart
/// from the shared `operationState`, which a transfer also writes, so a
/// finished transfer can never show up as a compare outcome.
enum CompareRunEnd: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}

enum CompareOutcome: Equatable, Sendable {
    /// Every file matched, and contents were verified.
    case match
    /// Every file has the same size, but contents were not read (Quick).
    case sizesMatchNotVerified
    /// Something differs.
    case differ
    case cancelled
    case failed(String)

    static func resolve(stats: CompareStats?, end: CompareRunEnd?, mode: VerificationMode) -> Self? {
        switch end {
        case .cancelled:
            return .cancelled
        case .failed(let message):
            return .failed(message)
        case .completed, nil:
            guard let stats else { return nil }
            if !stats.isClean { return .differ }
            return CompareCheckPlan.make(for: mode).verifiesContents ? .match : .sizesMatchNotVerified
        }
    }
}

/// Tone of the outcome headline. Green is only for verified matches; a
/// size-only match is amber (THESIS decision: "Sizes match, not verified").
enum CompareTone: Equatable, Sendable {
    case verified
    case notVerified
    case differ
    case failed
    case cancelled
}

struct CompareVerdictPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let symbol: String
    let tone: CompareTone

    /// Text for a VoiceOver announcement when the compare finishes.
    var announcement: String { "\(title). \(detail)" }

    static func make(
        _ outcome: CompareOutcome,
        leftName: String,
        rightName: String,
        mode: VerificationMode,
        stats: CompareStats?
    ) -> Self {
        let plan = CompareCheckPlan.make(for: mode)
        switch outcome {
        case .match:
            return Self(
                title: "Folders match",
                detail: "Every file in \(leftName) matches \(rightName). Checked with: \(plan.summary).",
                symbol: "checkmark.seal.fill",
                tone: .verified
            )
        case .sizesMatchNotVerified:
            return Self(
                title: "Sizes match, not verified",
                detail: "Every file in \(leftName) has the same size in \(rightName). Quick mode does not read file contents, so a damaged copy of the same size would not be caught.",
                symbol: "exclamationmark.shield.fill",
                tone: .notVerified
            )
        case .differ:
            var parts: [String] = []
            if let stats {
                if stats.mismatchedCount > 0 {
                    parts.append("\(stats.mismatchedCount) \(plan.verifiesContents ? "with different contents" : "with different sizes")")
                }
                if stats.onlyInLeftCount > 0 { parts.append("\(stats.onlyInLeftCount) only in \(leftName)") }
                if stats.onlyInRightCount > 0 { parts.append("\(stats.onlyInRightCount) only in \(rightName)") }
            }
            return Self(
                title: "Folders differ",
                detail: parts.isEmpty ? "The folders are not the same." : parts.joined(separator: ", ") + ".",
                symbol: "xmark.octagon.fill",
                tone: .differ
            )
        case .cancelled:
            return Self(
                title: "Compare cancelled",
                detail: "Nothing was concluded. Compare again when ready.",
                symbol: "stop.circle",
                tone: .cancelled
            )
        case .failed(let message):
            return Self(
                title: "Compare failed",
                detail: message.isEmpty ? "The folders could not be compared." : message,
                symbol: "exclamationmark.triangle.fill",
                tone: .failed
            )
        }
    }
}

// MARK: - Progress

struct CompareProgressPresentation: Equatable, Sendable {
    let fraction: Double
    let filesProcessed: Int
    let totalFiles: Int
    let currentFile: String?

    static let starting = Self(fraction: 0, filesProcessed: 0, totalFiles: 0, currentFile: nil)

    var percentText: String { "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%" }

    var countText: String {
        totalFiles == 0 ? "Listing files…" : "\(filesProcessed) of \(totalFiles) files checked"
    }
}

// MARK: - Screen

/// Which empty folder box Compare highlights (see `ComparePresentation.nextStep`).
enum CompareNextStep: Equatable, Sendable {
    case chooseLeft
    case chooseRight
}

enum ComparePhase: Equatable, Sendable {
    case setup
    case running(CompareProgressPresentation)
    case finished(CompareOutcome)
}

struct ComparePresentation: Equatable, Sendable {
    static let nonDestructiveMessage = "Compare does not change either folder."
    static let referenceFolderLabel = "Reference folder"
    static let folderToCheckLabel = "Folder to check"

    let left: CompareFolderSlot
    let right: CompareFolderSlot
    let mode: VerificationMode
    let readiness: CompareReadiness
    let phase: ComparePhase
    let stats: CompareStats?

    var checkPlan: CompareCheckPlan { CompareCheckPlan.make(for: mode) }

    /// The empty folder box to highlight, as Setup does for its source and
    /// backups: Left first, then Right. A missing folder is a step not taken
    /// yet, not an error, so it gets a highlight rather than a warning line.
    var nextStep: CompareNextStep? {
        switch readiness {
        case .needsLeft: .chooseLeft
        case .needsRight: .chooseRight
        case .blocked, .loading, .running, .ready: nil
        }
    }

    /// The Compare button names what happens next, so no hint line is
    /// needed under it.
    var actionTitle: String {
        switch readiness {
        case .needsLeft: "Choose the reference folder"
        case .needsRight: "Choose the folder to check"
        case .blocked: "Choose two separate folders"
        case .loading: "Reading folder details…"
        case .running: "Comparing…"
        case .ready: isFinished ? "Compare again" : "Compare folders"
        }
    }

    var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    /// Only a real problem (same or nested folders) gets a line of its own.
    /// Missing folders are shown by `nextStep` and `actionTitle` instead.
    var blockMessage: String? {
        if case .blocked(let block) = readiness { return block.message }
        return nil
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Folder pickers, drops, clear buttons and the verification picker are
    /// all locked while anything runs.
    var allowsEditing: Bool { !isRunning }

    var leftName: String { left.name ?? Self.referenceFolderLabel }
    var rightName: String { right.name ?? Self.folderToCheckLabel }

    var verdict: CompareVerdictPresentation? {
        guard case .finished(let outcome) = phase else { return nil }
        return CompareVerdictPresentation.make(outcome, leftName: leftName, rightName: rightName, mode: mode, stats: stats)
    }

    /// - Parameters:
    ///   - isRunning: any operation is in progress (a compare or a transfer).
    ///   - end: how the last compare ended, if one finished for this selection.
    static func make(
        left: CompareFolderSlot,
        right: CompareFolderSlot,
        mode: VerificationMode,
        isRunning: Bool,
        progress: CompareProgressPresentation?,
        stats: CompareStats?,
        end: CompareRunEnd?
    ) -> Self {
        let readiness = CompareReadiness.resolve(left: left, right: right, isRunning: isRunning)
        let phase: ComparePhase
        if isRunning {
            phase = .running(progress ?? .starting)
        } else if let outcome = CompareOutcome.resolve(stats: stats, end: end, mode: mode) {
            phase = .finished(outcome)
        } else {
            phase = .setup
        }
        return Self(left: left, right: right, mode: mode, readiness: readiness, phase: phase, stats: stats)
    }
}

// MARK: - Mode switching

/// Decision C-2: the app-mode switcher is locked while anything runs, on
/// every platform, so a running compare or transfer is never hidden behind
/// another mode's screen.
enum ModeSwitchPolicy {
    static func isLocked(isOperationInProgress: Bool, queueIsRunning: Bool) -> Bool {
        isOperationInProgress || queueIsRunning
    }
}
