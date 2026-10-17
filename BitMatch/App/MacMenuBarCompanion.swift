import AppKit
import BitMatchEngine
import SwiftUI

/// A read-only, small window onto the same operation shown in BitMatch.
/// Nothing here starts, pauses, or settles a transfer.
@MainActor
struct MacMenuBarCompanion: View {
    @ObservedObject private var coordinator: SharedAppCoordinator
    @ObservedObject private var stateService: OperationStateService
    @ObservedObject private var liveProgress: LiveProgressFeed
    @ObservedObject private var journal: LocalTransferJournal
    @Environment(\.openWindow) private var openWindow
    private let appDelegate: AppDelegate

    init(coordinator: SharedAppCoordinator, appDelegate: AppDelegate) {
        self.coordinator = coordinator
        self.stateService = coordinator.stateService
        self.liveProgress = coordinator.liveProgress
        self.journal = coordinator.transferJournal
        self.appDelegate = appDelegate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BitMatch")
                .font(.headline)

            if coordinator.isOperationInProgress && coordinator.currentMode == .copyAndVerify {
                activeTransfer
            } else if coordinator.queueIsRunning {
                Label("Preparing the next card", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else {
                Text("No transfer running")
                    .foregroundStyle(.secondary)
            }

            if let recent = MenuBarRecentTransfer.latest(in: journal.records) {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last transfer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(recent.cardName)
                        .lineLimit(1)
                    Text(recent.status)
                        .font(.caption)
                        .foregroundStyle(recent.needsAttention ? Color.orange : Color.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            Divider()
            HStack {
                Button("Open BitMatch") {
                    if !appDelegate.focusExistingContentWindow() {
                        openWindow(id: "main")
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    private var activeTransfer: some View {
        let presentation = TransferProgressPresentation.make(coordinator: coordinator)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.title).font(.headline)
                Spacer()
                if let percent = presentation.percentText {
                    Text(percent).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let fraction = presentation.fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(presentation.title)
                    .accessibilityValue(presentation.percentText ?? "")
            } else {
                ProgressView().accessibilityLabel(presentation.title)
            }
            if let detail = presentation.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !presentation.destinations.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(presentation.destinations) { destination in
                            HStack(spacing: 8) {
                                Text(destination.name).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(MenuBarDestinationLabel.text(for: destination.state))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxHeight: 145)
            }
            if let issueLine = presentation.issueLine {
                Text(issueLine).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// The menu bar item always occupies the same width; progress never claims a
/// green verdict, including while report generation holds it near 100%.
@MainActor
struct MacMenuBarStatusLabel: View {
    @ObservedObject private var coordinator: SharedAppCoordinator
    @ObservedObject private var stateService: OperationStateService
    @ObservedObject private var liveProgress: LiveProgressFeed

    init(coordinator: SharedAppCoordinator) {
        self.coordinator = coordinator
        self.stateService = coordinator.stateService
        self.liveProgress = coordinator.liveProgress
    }

    var body: some View {
        Group {
            if coordinator.isOperationInProgress && coordinator.currentMode == .copyAndVerify {
                let presentation = TransferProgressPresentation.make(coordinator: coordinator)
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.4), lineWidth: 2.5)
                    if let fraction = presentation.fraction {
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        Circle().fill(Color.primary).frame(width: 4, height: 4)
                    }
                }
                .accessibilityLabel("BitMatch, \(presentation.title), \(presentation.percentText ?? "progress not yet measured")")
            } else {
                Image(systemName: "square.on.square")
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("BitMatch")
            }
        }
        .frame(width: 18, height: 18)
    }
}

enum MenuBarDestinationLabel {
    static func text(for state: DestinationProgressRow.State) -> String {
        switch state {
        case .waiting: "Waiting"
        case .copying: "Copying"
        case .copied: "Processed · result pending"
        case .verifying: "Verifying"
        }
    }
}

struct MenuBarRecentTransfer: Equatable {
    let cardName: String
    let status: String
    let needsAttention: Bool

    static func latest(in records: [LocalTransferRecord]) -> Self? {
        guard let record = records
            .filter({ $0.state != .queued && $0.state != .running })
            .max(by: { ($0.endedAt ?? $0.createdAt) < ($1.endedAt ?? $1.createdAt) }) else {
            return nil
        }
        guard let result = status(for: record.state) else { return nil }
        return Self(cardName: record.title, status: result.text, needsAttention: result.needsAttention)
    }

    static func status(for state: LocalTransferState) -> (text: String, needsAttention: Bool)? {
        switch state {
        case .completed: ("Completed · review results in BitMatch", false)
        case .issues: ("Needs review", true)
        case .failed: ("Transfer failed", true)
        case .cancelled: ("Transfer cancelled", true)
        case .interrupted: ("Transfer interrupted", true)
        case .queued, .running: nil
        }
    }
}
