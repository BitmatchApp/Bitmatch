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
                MenuBarBrandMark()
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .accessibilityLabel("BitMatch")
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Two copies and a check, drawn as a single-color menu bar template. The
/// normal app icon loses its fine segmented ring at this size.
private struct MenuBarBrandMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        let unit = side / 18
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }

        var mark = Path()
        // Only the exposed edges of the rear copy are drawn; lines do not show
        // through the foreground copy when macOS changes the menu bar color.
        mark.move(to: point(4.9, 13.1))
        mark.addLine(to: point(3.7, 13.1))
        mark.addQuadCurve(to: point(2.5, 11.9), control: point(2.5, 13.1))
        mark.addLine(to: point(2.5, 3.8))
        mark.addQuadCurve(to: point(3.8, 2.5), control: point(2.5, 2.5))
        mark.addLine(to: point(11.8, 2.5))
        mark.addQuadCurve(to: point(13.1, 3.8), control: point(13.1, 2.5))
        mark.addLine(to: point(13.1, 4.8))

        mark.addRoundedRect(
            in: CGRect(x: origin.x + 5 * unit, y: origin.y + 5 * unit,
                       width: 10.5 * unit, height: 10.5 * unit),
            cornerSize: CGSize(width: 1.35 * unit, height: 1.35 * unit)
        )
        mark.move(to: point(7.4, 10.2))
        mark.addLine(to: point(9.4, 12.2))
        mark.addLine(to: point(13.1, 8.45))
        return mark
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
        guard let result = status(for: record) else { return nil }
        return Self(cardName: record.title, status: result.text, needsAttention: result.needsAttention)
    }

    static func status(for record: LocalTransferRecord) -> (text: String, needsAttention: Bool)? {
        guard record.state != .queued, record.state != .running else { return nil }
        return switch TransferLibraryPresentation.safetyState(for: record) {
        case .safeToErase: ("Completed · review results in BitMatch", false)
        case .copiedNotVerified: ("Copied, not verified", true)
        case .needsAttention: ("Needs review", true)
        case .failed: ("Transfer failed", true)
        case .interrupted:
            (record.state == .cancelled ? "Transfer cancelled" : "Transfer interrupted", true)
        case .waiting, .preparing, .copying, .verifying, .finishing: nil
        }
    }
}
