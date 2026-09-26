import Foundation
import BitMatchEngine

/// How the progress screen colours its header and bar. Progress is never
/// green: green means verified (THESIS promise 2, accessibility audit H5).
enum ProgressTone: Equatable, Sendable {
    case active
    case paused
    /// Something already failed; the run continues and the outcome lists it.
    case attention
}

/// The step the run is on, from the engine's `progress.currentStage` and the
/// one operation state. Never inferred from `.inProgress` alone, which the
/// state keeps for the whole copy and verify (UI plan 3.2.1).
enum ProgressPhase: Equatable, Sendable {
    case preparing
    case copying
    case verifying
    case writingReports
    case finishing
    case paused
    case resuming
}

/// Which button the screen draws as the primary control.
enum ProgressPrimaryControl: Equatable, Sendable {
    case pause
    case resume
}

struct ProgressControls: Equatable, Sendable {
    let canPause: Bool
    let canResume: Bool
    /// False when nothing is running, so Cancel (and Mac ⌘.) cannot fake a
    /// cancelled outcome for a transfer that is not there.
    let canCancel: Bool

    var primary: ProgressPrimaryControl? {
        if canResume { return .resume }
        if canPause { return .pause }
        return nil
    }
}

/// One backup's line while a run is in progress. It reports copying only:
/// the engine counts a backup's files as they are copied (failures
/// included), and verification is judged on the outcome screen. So a row is
/// never green and never says "Done" (accessibility audit C1).
struct DestinationProgressRow: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case waiting
        case copying
        /// Every file was copied to this backup; not a verdict.
        case copied
        case verifying
    }

    let id: String
    let name: String
    let path: String
    let state: State
    /// This backup's own copied fraction, or nil when the engine has not
    /// reported per-backup counts yet. Never the overall fraction.
    let fraction: Double?
    let countText: String?

    var stateLabel: String {
        switch state {
        case .waiting: "Waiting"
        case .copying: "Copying"
        case .copied: "Copied"
        case .verifying: "Verifying"
        }
    }

    var symbol: String {
        switch state {
        case .waiting: "clock"
        case .copying: "arrow.right.doc.on.clipboard"
        case .copied: "doc.on.doc"
        case .verifying: "magnifyingglass"
        }
    }
}

/// A line about this device (keep-awake, background time). Informational
/// unless `isWarning`; only a warning is drawn in colour.
struct ProgressDeviceNote: Equatable, Hashable, Sendable {
    let text: String
    let symbol: String
    let isWarning: Bool
}

/// The device facts the screen explains. Built by the adapter; the rules
/// that turn them into text are here so they can be tested.
enum ProgressDevice: Equatable, Sendable {
    /// The Mac holds an idle-sleep activity while a transfer runs.
    case mac
    /// iPad and iPhone: whether the screen is kept awake, and the background
    /// time left when the app is not in front (nil when it is).
    case iOS(keepsScreenAwake: Bool, backgroundSecondsLeft: Double?)
}

/// Everything the shared `ProgressScreen` shows while a transfer runs, on
/// Mac, iPad and iPhone (UI plan step 4.9, §3.3). It decides nothing about
/// the verdict; the outcome screen does that when the run ends.
struct TransferProgressPresentation: Equatable, Sendable {
    let phase: ProgressPhase
    let title: String
    let symbol: String
    /// "A001 to 2 backups", or why the run is paused.
    let detail: String?
    let tone: ProgressTone
    /// One definition everywhere: the engine's (copied + verified) /
    /// (files × stages). Nil before the engine reports, so the bar is
    /// indeterminate rather than a false 0%.
    let fraction: Double?
    let percentText: String?
    /// "120 of 400" (file copies across all backups). The phase and heading
    /// already say whether BitMatch is copying or verifying, so the changing
    /// value stays compact and matches the live-results header.
    let countText: String?
    let speed: String?
    /// From observed copy speed only; `estimatingTimeLeft` until enough
    /// copying has been measured. There is no estimate before a run starts.
    let timeRemaining: String?
    let elapsed: String?
    let currentFile: String?
    /// Only when something already went wrong (a real problem).
    let issueLine: String?
    let destinations: [DestinationProgressRow]
    let controls: ProgressControls
    let deviceNotes: [ProgressDeviceNote]

    /// What VoiceOver reads for the bar.
    var accessibilityValue: String {
        [title, percentText, countText].compactMap { $0 }.joined(separator: ", ")
    }

    /// Speed and time left before enough copying has been measured.
    static let estimating = "Estimating..."
    static let estimatingTimeLeft = estimating

    static let cancelConfirmationTitle = "Cancel this transfer?"
    static let cancelConfirmationMessage =
        "Copying and verifying stop now. The card is not changed, but the backups will be incomplete, so do not erase the card."
    static let cancelConfirmationAction = "Cancel transfer"
    static let cancelKeepAction = "Keep going"

    static func make(
        state: OperationState,
        isRunning: Bool,
        progress: OperationProgress?,
        sourceName: String?,
        destinations: [URL],
        destinationNames: [String]? = nil,
        speed: String?,
        timeRemaining: String?,
        elapsed: String?,
        issueCount: Int,
        device: ProgressDevice
    ) -> Self {
        let phase = Self.phase(state: state, stage: progress?.currentStage)
        let isPaused = phase == .paused
        let fraction = progress.map { min(1, max(0, $0.overallProgress)) }
        let controls = ProgressControls(
            canPause: state.canPause,
            canResume: state.canResume,
            canCancel: isRunning || state.canCancel
        )
        let tone: ProgressTone = isPaused ? .paused : (issueCount > 0 ? .attention : .active)
        return Self(
            phase: phase,
            title: Self.title(for: phase),
            symbol: Self.symbol(for: phase),
            detail: Self.detail(state: state, sourceName: sourceName, backupCount: destinations.count),
            tone: tone,
            fraction: fraction,
            percentText: fraction.map { "\(Int(($0 * 100).rounded(.down)))%" },
            countText: Self.countText(progress: progress),
            // Speed and time left mean nothing while paused.
            speed: isPaused ? nil : Self.speedText(phase: phase, measured: speed),
            timeRemaining: Self.timeLeft(phase: phase, measured: timeRemaining),
            elapsed: elapsed,
            currentFile: progress?.currentFile.flatMap { $0.isEmpty ? nil : $0 },
            issueLine: Self.issueLine(issueCount),
            destinations: Self.rows(
                destinations: destinations,
                destinationNames: destinationNames,
                progress: progress,
                phase: phase
            ),
            controls: controls,
            deviceNotes: Self.notes(for: device)
        )
    }

    // MARK: Rules

    /// Time left as the screen shows it. `measured` comes from observed copy
    /// speed (`ProgressPresentationModel.formattedTimeRemaining`). Before
    /// copying starts there is no speed yet, so it says so; once copying is
    /// done, or while paused, there is nothing honest to show.
    static func timeLeft(phase: ProgressPhase, measured: String?) -> String? {
        switch phase {
        case .preparing: return estimatingTimeLeft
        case .copying, .verifying: return measured
        case .paused, .resuming, .writingReports, .finishing: return nil
        }
    }

    static func speedText(phase: ProgressPhase, measured: String?) -> String? {
        phase == .copying ? measured ?? estimating : nil
    }

    static func phase(state: OperationState, stage: ProgressStage?) -> ProgressPhase {
        switch state {
        case .paused: return .paused
        case .resuming: return .resuming
        default: break
        }
        switch stage ?? .idle {
        case .copying: return .copying
        case .verifying: return .verifying
        case .generating: return .writingReports
        case .completed: return .finishing
        case .idle, .preparing:
            // The state names a stage only when the engine has not yet.
            switch state {
            case .copying: return .copying
            case .verifying: return .verifying
            default: return .preparing
            }
        }
    }

    static func title(for phase: ProgressPhase) -> String {
        switch phase {
        case .preparing: "Preparing"
        case .copying: "Copying"
        case .verifying: "Verifying"
        case .writingReports: "Writing reports"
        case .finishing: "Finishing"
        case .paused: "Paused"
        case .resuming: "Resuming"
        }
    }

    /// No check marks before anything is verified (audit H5).
    static func symbol(for phase: ProgressPhase) -> String {
        switch phase {
        case .preparing: "circle.dotted"
        case .copying: "arrow.right.circle"
        case .verifying: "magnifyingglass.circle"
        case .writingReports: "doc.text"
        case .finishing: "hourglass"
        case .paused: "pause.circle"
        case .resuming: "arrow.clockwise.circle"
        }
    }

    private static func detail(state: OperationState, sourceName: String?, backupCount: Int) -> String? {
        if case .paused(let info) = state {
            switch info.reason {
            case .userRequested: return "Paused. Resume to continue copying."
            case .lowBattery: return "Paused because the battery is low. Connect power, then resume."
            case .systemSleep: return "Paused while the device slept. Resume to continue."
            case .backgrounded: return "Paused while BitMatch was in the background. Resume to continue."
            case .error: return "Paused after a problem. Resume to try again."
            }
        }
        guard backupCount > 0 else { return sourceName }
        let backups = backupCount == 1 ? "1 backup" : "\(backupCount) backups"
        guard let sourceName, !sourceName.isEmpty else { return "To \(backups)" }
        return "\(sourceName) to \(backups)"
    }

    private static func countText(progress: OperationProgress?) -> String? {
        guard let progress, progress.totalFiles > 0 else { return nil }
        let total = progress.totalFiles
        return "\(min(progress.filesProcessed, total).formatted()) of \(total.formatted())"
    }

    private static func issueLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let problems = count == 1 ? "1 problem" : "\(count) problems"
        return "\(problems) so far. The transfer continues; details appear when it ends."
    }

    static func rows(
        destinations: [URL],
        destinationNames: [String]? = nil,
        progress: OperationProgress?,
        phase: ProgressPhase
    ) -> [DestinationProgressRow] {
        let totals = progress?.perDestinationTotals
        let completed = progress?.perDestinationCompleted
        let hasCounts = totals?.count == destinations.count && completed?.count == destinations.count
        return destinations.enumerated().map { index, url in
            var fraction: Double?
            var countText: String?
            var state = DestinationProgressRow.State.waiting
            if hasCounts, let totals, let completed {
                let total = totals[index]
                let done = min(completed[index], total)
                fraction = total > 0 ? Double(done) / Double(total) : nil
                countText = total > 0 ? "\(done.formatted()) of \(total.formatted()) copied" : nil
                if total > 0 && done >= total {
                    state = phase == .verifying ? .verifying : .copied
                } else if done > 0 {
                    state = .copying
                }
            }
            let name = destinationNames.flatMap { names in
                names.indices.contains(index) ? names[index] : nil
            } ?? DestinationVolumeLabel.name(for: url)
            return DestinationProgressRow(
                id: url.path,
                name: name,
                path: url.path,
                state: state,
                fraction: fraction,
                countText: countText
            )
        }
    }

    static func notes(for device: ProgressDevice) -> [ProgressDeviceNote] {
        switch device {
        case .mac:
            return [ProgressDeviceNote(
                text: "This Mac stays awake until the transfer ends.",
                symbol: "moon.zzz",
                isWarning: false
            )]
        case .iOS(let keepsScreenAwake, let backgroundSecondsLeft):
            var notes: [ProgressDeviceNote] = []
            if let seconds = backgroundSecondsLeft, seconds.isFinite, seconds > 0 {
                let minutes = max(1, Int((seconds / 60).rounded(.up)))
                notes.append(ProgressDeviceNote(
                    text: "About \(minutes) min of background time left. Return to BitMatch to keep copying.",
                    symbol: "exclamationmark.triangle",
                    isWarning: true
                ))
            }
            if keepsScreenAwake {
                notes.append(ProgressDeviceNote(
                    text: "The screen stays on while BitMatch copies.",
                    symbol: "sun.max",
                    isWarning: false
                ))
            }
            // An actual limit, stated plainly (AGENTS.md): iOS gives an app
            // only a few minutes in the background.
            notes.append(ProgressDeviceNote(
                text: "Keep BitMatch open until the transfer ends. In the background, iOS allows only a few minutes.",
                symbol: "iphone",
                isWarning: false
            ))
            return notes
        }
    }
}
