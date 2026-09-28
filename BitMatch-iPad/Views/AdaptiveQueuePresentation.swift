import SwiftUI

@MainActor
final class CompactQueuePresentationState: ObservableObject {
    @Published var showingQueue = false
    @Published private(set) var flashedSafeRecordID: UUID?
    @Published private(set) var acknowledgedAttention: Set<QueueAttentionToken> = []
    @Published private(set) var successFeedbackCount = 0
    private var flashTask: Task<Void, Never>?

    func openQueue(rows: [QueueSessionRow]) {
        acknowledgedAttention.formUnion(QueueAccessoryPresentation.attentionTokens(in: rows))
        showingQueue = true
    }

    func update(previousRows: [QueueSessionRow], currentRows: [QueueSessionRow]) {
        acknowledgedAttention = QueueAccessoryPresentation.reconciledAcknowledgements(
            acknowledgedAttention,
            with: currentRows
        )
        showSafeFlash(previousRows: previousRows, currentRows: currentRows)
    }

    private func showSafeFlash(previousRows: [QueueSessionRow], currentRows: [QueueSessionRow]) {
        guard let newlySafe = currentRows.first(where: { row in
            row.safetyState == .safeToErase
                && previousRows.first(where: { $0.id == row.id })?.safetyState != .safeToErase
        }) else { return }
        beginSafeFlash(for: newlySafe)
    }

    private func beginSafeFlash(for row: QueueSessionRow) {
        guard flashedSafeRecordID != row.id else { return }
        flashedSafeRecordID = row.id
        successFeedbackCount += 1
        AccessibilityNotification.Announcement(row.cardName + " is safe to erase").post()
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            if self.flashedSafeRecordID == row.id {
                self.flashedSafeRecordID = nil
            }
        }
    }
}

struct CompactQueuePresentation<Content: View>: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var state: CompactQueuePresentationState
    @ObservedObject private var progress: LiveProgressFeed
    @ObservedObject private var background: IOSBackgroundTaskService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(
        coordinator: SharedAppCoordinator,
        state: CompactQueuePresentationState,
        @ViewBuilder content: () -> Content
    ) {
        self.coordinator = coordinator
        self.state = state
        _progress = ObservedObject(wrappedValue: coordinator.liveProgress)
        _background = ObservedObject(wrappedValue: IOSBackgroundTaskService.shared)
        self.content = content()
    }

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if accessory.isVisible {
                    QueueAccessoryButton(
                        presentation: accessory,
                        reduceMotion: reduceMotion,
                        successEffectValue: state.successFeedbackCount,
                        action: openQueue
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.bar)
                    .transition(reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(
                reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.28),
                value: accessory.isVisible
            )
            .sensoryFeedback(.success, trigger: state.successFeedbackCount)
            .onChange(of: coordinator.queuePresentation.rows) { oldRows, newRows in
                state.update(previousRows: oldRows, currentRows: newRows)
            }
    }

    private var accessory: QueueAccessoryPresentation {
        let live = TransferProgressPresentation.make(coordinator: coordinator)
        let keepOpen = live.deviceNotes.first {
            $0.text == TransferProgressPresentation.iOSBackgroundLimit
        }?.text
        return QueueAccessoryPresentation.make(
            queue: coordinator.queuePresentation,
            timeRemaining: live.timeRemaining,
            backgroundMessage: keepOpen,
            flashedSafeRecordID: state.flashedSafeRecordID,
            acknowledgedAttention: state.acknowledgedAttention,
            isQueueRunning: coordinator.queueIsRunning
        )
    }

    private func openQueue() {
        state.openQueue(rows: coordinator.queuePresentation.rows)
    }
}

private struct QueueAccessoryButton: View {
    let presentation: QueueAccessoryPresentation
    let reduceMotion: Bool
    let successEffectValue: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                statusIcon
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let message = presentation.backgroundMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(tint.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint("Shows the queue")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if reduceMotion {
            Image(systemName: presentation.symbol)
        } else {
            Image(systemName: presentation.symbol)
                .symbolEffect(.bounce, value: successEffectValue)
        }
    }

    private var tint: Color {
        switch presentation.tone {
        case .safeToErase: .green
        case .warning: .orange
        case .failure: .red
        case .neutral: .secondary
        case .progress: .accentColor
        }
    }
}

struct RegularQueuePresentation<Content: View>: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var isInspectorPresented: Bool
    private let content: Content

    init(
        coordinator: SharedAppCoordinator,
        isInspectorPresented: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self.coordinator = coordinator
        _isInspectorPresented = isInspectorPresented
        self.content = content()
    }

    var body: some View {
        content
            .inspector(isPresented: $isInspectorPresented) {
                ScrollView {
                    TransferQueueSection(coordinator: coordinator, offersAddCard: true)
                        .padding()
                }
                .inspectorColumnWidth(
                    min: AdaptiveQueueLayoutPolicy.minimumInspectorWidth,
                    ideal: AdaptiveQueueLayoutPolicy.inspectorWidth,
                    max: AdaptiveQueueLayoutPolicy.maximumInspectorWidth
                )
            }
            .onChange(of: coordinator.queuePresentation.rows.map(\.id)) { oldIDs, newIDs in
                if oldIDs.isEmpty && !newIDs.isEmpty { isInspectorPresented = true }
                if newIDs.isEmpty { isInspectorPresented = false }
            }
    }
}

struct QueueInspectorToolbarButton: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var progress: LiveProgressFeed
    let isInspectorPresented: Bool
    let action: () -> Void

    init(
        coordinator: SharedAppCoordinator,
        isInspectorPresented: Bool,
        action: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        _progress = ObservedObject(wrappedValue: coordinator.liveProgress)
        self.isInspectorPresented = isInspectorPresented
        self.action = action
    }

    var body: some View {
        if status.isVisible {
            Button(action: action) {
                if isInspectorPresented {
                    Image(systemName: "sidebar.right")
                } else {
                    Label(compactTitle, systemImage: status.symbol)
                        .foregroundStyle(tint)
                }
            }
            .frame(minHeight: 44)
            .accessibilityLabel(isInspectorPresented ? "Hide queue" : status.accessibilityLabel)
            .accessibilityHint(isInspectorPresented ? "Hides the queue" : "Shows the queue")
        }
    }

    private var status: QueueAccessoryPresentation {
        let live = TransferProgressPresentation.make(coordinator: coordinator)
        return QueueAccessoryPresentation.make(
            queue: coordinator.queuePresentation,
            timeRemaining: live.timeRemaining,
            isQueueRunning: coordinator.queueIsRunning
        )
    }

    private var compactTitle: String {
        if status.tone == .warning || status.tone == .failure { return "Needs attention" }
        if let fraction = status.progressFraction, fraction < 1 {
            return "\(Int((fraction * 100).rounded(.down)))%"
        }
        return "Queue"
    }

    private var tint: Color {
        switch status.tone {
        case .safeToErase: .green
        case .warning: .orange
        case .failure: .red
        case .neutral, .progress: .primary
        }
    }
}
