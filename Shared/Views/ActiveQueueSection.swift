import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// Active queue controls shared by iPhone and iPad. The Mac uses the denser
/// `MacQueueSection`, but both surfaces call the same coordinator actions and
/// preserve Add, Resume/Stop, Move, Edit, Remove, and Review.
struct ActiveQueueSection: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @State private var choosingSource = false
    @State private var errorMessage: String?
    @State private var selectedWaitingID: UUID?
    @FocusState private var focusedWaitingID: UUID?

    var body: some View {
        Group {
            if isAvailable {
                queueContent
            }
        }
    }

    private var queueContent: some View {
        let presentation = coordinator.queuePresentation
        return VStack(alignment: .leading, spacing: 12) {
            if presentation.pausedCardID != nil {
                QueuePauseBanner(
                    presentation: presentation,
                    review: coordinator.reviewQueuedTransfer,
                    skipAndContinue: coordinator.skipPausedCardAndContinue,
                    remove: removePausedCard
                )
            }
            HStack {
                Text(presentation.summaryTitle ?? presentation.headerTitle ?? "Queue")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if coordinator.queueIsRunning {
                    Button("Stop Queue") { coordinator.stopQueueAfterCurrentTransfer() }
                        .buttonStyle(.bordered)
                } else if QueueCommandPolicy.showsResume(
                    hasSessionStarted: coordinator.queueSessionStarted,
                    waitingCount: presentation.rows.filter(\.isEditable).count
                ) && coordinator.queuePausedRecordID == nil {
                    Button("Resume Queue") { coordinator.startQueue() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!coordinator.queueRunCommandEnabled)
                }
            }

            ForEach(presentation.rows) { row in
                reorderableQueueRow(row, rows: presentation.rows)
                if row.id != presentation.rows.last?.id { Divider() }
            }

            if !presentation.showsQueueSummary {
                Button { choosingSource = true } label: {
                    Label("Add Card", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!canAddCard)
                .accessibilityHint("Choose another card to run with the current destinations")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .fileImporter(
            isPresented: $choosingSource,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let source = try result.get().first else { return }
                try coordinator.enqueueInlineCard(
                    source: source,
                    destinations: queueDestinations,
                    verificationMode: queueTemplate?.verificationMode ?? coordinator.verificationMode,
                    generateASCMHL: queueTemplate?.generateASCMHL ?? coordinator.generateASCMHL
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var isAvailable: Bool {
        coordinator.runningOneTimeTransfer != nil
            || coordinator.queueIsRunning
            || coordinator.queuePausedRecordID != nil
            || (coordinator.queueSessionEnded && coordinator.queuePresentation.isMultiCard)
            || coordinator.queueSessionStarted
    }

    private var queueTemplate: LocalTransferRecord? {
        coordinator.runningOneTimeTransfer
            ?? coordinator.transferJournal.records.first(where: {
                coordinator.queueSessionRecordIDs.contains($0.id) && $0.projectID == nil
            })
    }

    private var queueDestinations: [URL] {
        queueTemplate?.destinations.map(\.url) ?? coordinator.destinationURLs
    }

    private var canAddCard: Bool {
        ActiveQueuePresentation.canAddCard(
            isOperationInProgress: coordinator.runningOneTimeTransfer != nil,
            queueIsRunning: coordinator.queueIsRunning,
            destinationCount: queueDestinations.count
        )
    }

    private func queueRow(_ row: QueueSessionRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sdcard").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.cardName).lineLimit(1).truncationMode(.middle)
                Text(row.destinations).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Label(row.statusText, systemImage: row.safetyState.symbol)
                .font(.caption)
                .foregroundStyle(row.isEditable ? Color.secondary : row.safetyState.tint.color)
            if row.isEditable {
                Button("Edit") { edit(row.id) }.buttonStyle(.borderless)
                Button { remove(row.id) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove \(row.cardName) from the queue")
                .accessibilityLabel("Remove \(row.cardName) from the queue")
            } else if row.action == .review && coordinator.queuePausedRecordID != row.id {
                Button("Review") { coordinator.reviewQueuedTransfer(row.id) }
            }
        }
        .padding(.horizontal, 6)
        .background(
            selectedWaitingID == row.id ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard row.safetyState == .waiting else { return }
            selectedWaitingID = row.id
            focusedWaitingID = row.id
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func reorderableQueueRow(_ row: QueueSessionRow, rows: [QueueSessionRow]) -> some View {
        if row.safetyState == .waiting {
            queueRow(row)
                .focusable()
                .focused($focusedWaitingID, equals: row.id)
                .draggable(row.id.uuidString)
                .dropDestination(for: String.self) { values, _ in
                    guard let value = values.first, let draggedID = UUID(uuidString: value) else { return false }
                    return moveWaitingCard(draggedID, to: row.id, rows: rows)
                }
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                    guard press.modifiers.contains(.option) else { return .ignored }
                    moveWaitingCard(row.id, offset: -1, rows: rows)
                    return .handled
                }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                    guard press.modifiers.contains(.option) else { return .ignored }
                    moveWaitingCard(row.id, offset: 1, rows: rows)
                    return .handled
                }
                .onKeyPress(.delete) {
                    perform { try coordinator.removeQueuedTransfer(row.id) }
                    return .handled
                }
                .accessibilityAction(named: "Move up") { moveWaitingCard(row.id, offset: -1, rows: rows) }
                .accessibilityAction(named: "Move down") { moveWaitingCard(row.id, offset: 1, rows: rows) }
                .accessibilityAction(named: "Edit") { edit(row.id) }
                .accessibilityAction(named: "Remove from queue") {
                    remove(row.id)
                }
                .contextMenu {
                    Button("Edit") { edit(row.id) }
                    Button("Move to Top") { moveToTop(row.id) }
                    Button("Remove", role: .destructive) { remove(row.id) }
                }
        } else {
            queueRow(row)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func moveWaitingCard(_ id: UUID, offset: Int, rows: [QueueSessionRow]) {
        let waiting = rows.filter { $0.safetyState == .waiting }
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard waiting.indices.contains(destination) else { return }
        perform { try coordinator.moveQueuedTransfer(id: id, to: destination) }
        selectedWaitingID = id
        focusedWaitingID = id
    }

    private func edit(_ id: UUID) {
        perform { try coordinator.editSetupTransfer(id) }
    }

    private func remove(_ id: UUID) {
        perform { try coordinator.removeQueuedTransfer(id) }
    }

    private func moveToTop(_ id: UUID) {
        perform { try coordinator.moveQueuedTransferToTop(id) }
        selectedWaitingID = id
        focusedWaitingID = id
    }

    @discardableResult
    private func moveWaitingCard(_ id: UUID, to targetID: UUID, rows: [QueueSessionRow]) -> Bool {
        let waiting = rows.filter { $0.safetyState == .waiting }
        guard let destination = waiting.firstIndex(where: { $0.id == targetID }),
              waiting.contains(where: { $0.id == id }) else { return false }
        do {
            try coordinator.moveQueuedTransfer(id: id, to: destination)
            errorMessage = nil
            selectedWaitingID = id
            focusedWaitingID = id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func removePausedCard(_ id: UUID) {
        perform { try coordinator.removePausedCardFromQueue(id) }
    }
}

/// The queue owns the interruption announcement and its recovery actions.
/// Button labels stay short because the title already names the card.
struct QueuePauseBanner: View {
    let presentation: QueueSessionPresentation
    let review: (UUID) -> Void
    let skipAndContinue: (UUID) -> Void
    let remove: (UUID) -> Void

    var body: some View {
        if let id = presentation.pausedCardID,
           let title = presentation.pausedTitle,
           let cardName = presentation.rows.first(where: { $0.id == id })?.cardName {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(cardName)
                if let cause = presentation.pausedCause {
                    Text(cause)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons(id: id) }
                    VStack(alignment: .leading, spacing: 8) { buttons(id: id) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSafetyTint.amber.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func buttons(id: UUID) -> some View {
        Button("Review") { review(id) }
            .buttonStyle(.borderedProminent)
        Button("Skip and Continue") { skipAndContinue(id) }
            .buttonStyle(.bordered)
        Button("Remove from Queue", role: .destructive) { remove(id) }
            .buttonStyle(.bordered)
    }
}
