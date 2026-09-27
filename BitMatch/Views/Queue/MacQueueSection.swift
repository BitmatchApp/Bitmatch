import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// One journal-backed transfer list directly under the Mac composer.
struct MacQueueSection: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var progress: LiveProgressFeed
    @ObservedObject private var stateService: OperationStateService
    @State private var expandedIDs: Set<UUID> = []
    @State private var selectedWaitingID: UUID?
    @State private var heroID: UUID?
    @State private var heroDismissTask: Task<Void, Never>?
    @State private var confirmingCancel = false
    @State private var errorMessage: String?
    @State private var exportDocument: TransferHistoryDocument?
    @State private var exportType = UTType.json
    @State private var showingExporter = false
    @State private var transitionClearTask: Task<Void, Never>?
    @FocusState private var focusedWaitingID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let transferTransitionContext: QueueTransferTransitionContext?

    init(
        coordinator: SharedAppCoordinator,
        transferTransitionContext: QueueTransferTransitionContext? = nil
    ) {
        self.coordinator = coordinator
        self.transferTransitionContext = transferTransitionContext
        _progress = ObservedObject(wrappedValue: coordinator.liveProgress)
        _stateService = ObservedObject(wrappedValue: coordinator.stateService)
    }

    var body: some View {
        let presentation = coordinator.queuePresentation
        Group {
            if !presentation.rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if presentation.pausedCardID != nil {
                        QueuePauseBanner(
                            presentation: presentation,
                            review: { id in
                                coordinator.markQueueTransferReviewed(id)
                                expandedIDs.insert(id)
                            },
                            skipAndContinue: coordinator.skipPausedCardAndContinue,
                            remove: removePausedCard
                        )
                    }
                    header(presentation)
                    rows(presentation.rows)
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(CardSafetyTint.red.color)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                )
            }
        }
        .onChange(of: presentation.rows) { oldRows, newRows in
            handleRowChanges(from: oldRows, to: newRows)
        }
        .onDisappear {
            heroDismissTask?.cancel()
            transitionClearTask?.cancel()
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "BitMatch-transfer"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private func header(_ presentation: QueueSessionPresentation) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Transfers").font(.headline).accessibilityAddTraits(.isHeader)
                if let detail = presentation.headerDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if presentation.showsClearFinished {
                Button("Clear finished") { coordinator.clearFinishedQueueRows() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Remove finished rows from this list. They remain in History.")
            }
            if !coordinator.queueIsRunning,
               QueueCommandPolicy.showsResume(
                hasSessionStarted: coordinator.queueSessionStarted,
                waitingCount: presentation.rows.filter(\.isEditable).count
               ), coordinator.queuePausedRecordID == nil {
                Button("Resume Queue") { coordinator.startQueue() }
                    .controlSize(.small)
                    .disabled(!coordinator.queueRunCommandEnabled)
            }
        }
    }

    @ViewBuilder
    private func rows(_ rows: [QueueSessionRow]) -> some View {
        if rows.count > 8 {
            ScrollView {
                LazyVStack(spacing: 8) { transferRows(rows) }.padding(.trailing, 3)
            }
            .frame(maxHeight: 520)
        } else {
            VStack(spacing: 8) { transferRows(rows) }
        }
    }

    @ViewBuilder
    private func transferRows(_ rows: [QueueSessionRow]) -> some View {
        ForEach(rows) { row in
            if row.isEditable { reorderableWaitingRow(row, rows: rows) }
            else { transferRow(row) }
        }
    }

    private func reorderableWaitingRow(_ row: QueueSessionRow, rows: [QueueSessionRow]) -> some View {
        transferRow(row)
            .focusable()
            .focusEffectDisabled()
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
                remove(row.id)
                return .handled
            }
            .accessibilityAction(named: "Move up") { moveWaitingCard(row.id, offset: -1, rows: rows) }
            .accessibilityAction(named: "Move down") { moveWaitingCard(row.id, offset: 1, rows: rows) }
    }

    private func transferRow(_ row: QueueSessionRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            collapsedRow(row)
            if expandedIDs.contains(row.id) {
                Divider().padding(.horizontal, 10)
                expandedContent(row)
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(baseColor(for: row))
                    if row.isRunning {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: proxy.size.width * min(max(row.progressFraction ?? 0, 0), 1))
                            .animation(reduceMotion ? nil : .linear(duration: 0.25), value: row.progressFraction)
                    }
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor(for: row))
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.5), lineWidth: focusedWaitingID == row.id ? 1.5 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func collapsedRow(_ row: QueueSessionRow) -> some View {
        HStack(spacing: 8) {
            if row.isEditable || row.isFinished {
                Button { removeFromList(row) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary).frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(removeHelp(for: row))
                .accessibilityLabel(removeHelp(for: row))
            } else {
                Image(systemName: row.safetyState.symbol)
                    .foregroundStyle(row.isRunning ? Color.accentColor : row.safetyState.tint.color)
                    .frame(width: 24).accessibilityHidden(true)
            }
            if coordinator.editingSetupTransferID != row.id {
                collapsedSummary(row)
            } else {
                Spacer(minLength: 0)
            }
            if row.isEditable {
                Text("Waiting").font(.caption).foregroundStyle(.secondary)
                Button("Edit") { edit(row.id) }.buttonStyle(.borderless)
            } else {
                compactAction(row)
                Button { toggleExpanded(row.id) } label: {
                    Image(systemName: expandedIDs.contains(row.id) ? "chevron.up" : "chevron.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expandedIDs.contains(row.id) ? "Collapse \(row.cardName)" : "Expand \(row.cardName)")
            }
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isEditable {
                selectedWaitingID = row.id
                focusedWaitingID = row.id
            } else {
                toggleExpanded(row.id)
            }
        }
        .accessibilityLabel(row.accessibilityStatus)
        .contextMenu {
            if row.isEditable {
                Button("Edit") { edit(row.id) }
                Button("Move to Top") { moveToTop(row.id) }
                Button("Remove", role: .destructive) { remove(row.id) }
            }
        }
    }

    private func collapsedText(_ row: QueueSessionRow) -> String {
        row.isEditable
            ? row.waitingText
            : row.oneLineStatus(timeRemaining: row.isRunning ? liveProgressPresentation.timeRemaining : nil)
    }

    @ViewBuilder
    private func collapsedSummary(_ row: QueueSessionRow) -> some View {
        let text = Text(collapsedText(row))
            .font(.subheadline.weight(row.isFinished ? .medium : .regular))
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let transferTransitionContext {
            text.matchedGeometryEffect(
                id: transferTransitionContext.activeID.wrappedValue == row.id
                    ? AnyHashable("composer-transfer")
                    : AnyHashable(row.id),
                in: transferTransitionContext.namespace
            )
        } else {
            text
        }
    }

    @ViewBuilder
    private func compactAction(_ row: QueueSessionRow) -> some View {
        switch row.action {
        case .some(.eject):
            // The expanded row (or the safe-to-erase moment) has its own
            // Eject; one per row is enough.
            if heroID != row.id && !expandedIDs.contains(row.id) {
                Button("Eject") { eject(row.id) }.accessibilityLabel("Eject \(row.cardName)")
            }
        case .some(.review):
            Button("Review") {
                coordinator.markQueueTransferReviewed(row.id)
                expandedIDs.insert(row.id)
            }
        case .some(.ejected):
            Text("Ejected").font(.caption).foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func expandedContent(_ row: QueueSessionRow) -> some View {
        if row.isRunning {
            ProgressScreen(
                presentation: liveProgressPresentation,
                actions: ProgressActions(
                    pause: { Task { await coordinator.pauseOperation() } },
                    resume: { Task { await coordinator.resumeOperation() } },
                    cancel: { coordinator.cancelOperation() }
                ),
                confirmingCancel: $confirmingCancel
            )
        } else if heroID == row.id, let outcome = row.outcome, outcome.safetyState == .safeToErase {
            SafeTransferHero(
                row: row, outcome: outcome, reduceMotion: reduceMotion,
                eject: row.action == .eject ? { eject(row.id) } : nil
            )
        } else if let outcome = row.outcome {
            finishedDetails(row, outcome: outcome)
        }
    }

    private var liveProgressPresentation: TransferProgressPresentation {
        TransferProgressPresentation.make(coordinator: coordinator)
    }

    private func finishedDetails(_ row: QueueSessionRow, outcome: TransferOutcomePresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(outcome.verdict.detail)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let cause = row.cause {
                Label(cause, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(outcome.safetyState.tint.color)
            }
            ForEach(outcome.advisoryLines, id: \.self) { advisory in
                Label(advisory, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(CardSafetyTint.amber.color)
            }
            ForEach(outcome.clipFailureLines, id: \.self) { issue in
                Label(issue, systemImage: "film")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(outcome.destinations) { destination in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: destination.needsAttention ? "exclamationmark.triangle" : "externaldrive")
                        .foregroundStyle(destination.needsAttention ? CardSafetyTint.red.color : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destination.title).font(.subheadline.weight(.medium))
                        Text(destination.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                if outcome.canRetry {
                    Button("Retry") { coordinator.retryTransfer(row.id) }.buttonStyle(.borderedProminent)
                }
                if outcome.canExport {
                    Menu("Export Report") {
                        Button("JSON report") { export(row.id, asCSV: false) }
                        Button("CSV results") { export(row.id, asCSV: true) }
                    }.menuStyle(.button)
                }
                Button("Copy Summary") { TransferSummaryPasteboard.copy(row.copySummary) }
                if row.action == .eject { Button("Eject") { eject(row.id) } }
            }
        }
    }

    private func baseColor(for row: QueueSessionRow) -> Color {
        if row.isFinished { return row.safetyState.tint.color.opacity(0.08) }
        if selectedWaitingID == row.id { return Color.accentColor.opacity(0.08) }
        return Color.primary.opacity(0.025)
    }

    private func borderColor(for row: QueueSessionRow) -> Color {
        row.isFinished ? row.safetyState.tint.color.opacity(0.28) : Color.primary.opacity(0.07)
    }

    private func toggleExpanded(_ id: UUID) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            if expandedIDs.contains(id) { expandedIDs.remove(id) }
            else { expandedIDs.insert(id) }
        }
    }

    private func handleRowChanges(from oldRows: [QueueSessionRow], to newRows: [QueueSessionRow]) {
        if let heroID, newRows.contains(where: { $0.id != heroID && $0.isRunning }) {
            settleHero(heroID)
        }
        for row in newRows where row.showsSafeHero {
            let isNewlySafe = oldRows.first(where: { $0.id == row.id })?.showsSafeHero != true
            guard isNewlySafe else { continue }
            if coordinator.autoEjectWhenSafe && row.action == .eject { eject(row.id) }
            if QueueHeroPolicy.shouldExpand(row: row, previousRows: oldRows, currentRows: newRows) {
                showHero(for: row)
            }
        }
    }

    private func showHero(for row: QueueSessionRow) {
        heroDismissTask?.cancel()
        heroID = row.id
        expandedIDs.insert(row.id)
        heroDismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run { settleHero(row.id) }
        }
    }

    private func settleHero(_ id: UUID) {
        guard heroID == id else { return }
        heroDismissTask?.cancel()
        heroDismissTask = nil
        heroID = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { expandedIDs.remove(id) }
    }

    private func remove(_ id: UUID) { perform { try coordinator.removeQueuedTransfer(id) } }
    private func removeFinished(_ id: UUID) { perform { try coordinator.removeFinishedQueueRow(id) } }
    private func edit(_ id: UUID) {
        guard let transferTransitionContext else {
            perform { try coordinator.editSetupTransfer(id) }
            return
        }
        transitionClearTask?.cancel()
        withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(duration: 0.4, bounce: 0.18)) {
            transferTransitionContext.activeID.wrappedValue = id
            perform { try coordinator.editSetupTransfer(id) }
        }
        transitionClearTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run { transferTransitionContext.activeID.wrappedValue = nil }
        }
    }
    private func removePausedCard(_ id: UUID) { perform { try coordinator.removePausedCardFromQueue(id) } }

    private func removeFromList(_ row: QueueSessionRow) {
        if row.isFinished { removeFinished(row.id) }
        else if row.isEditable { remove(row.id) }
    }

    private func removeHelp(for row: QueueSessionRow) -> String {
        row.isFinished
            ? "Remove \(row.cardName) from the list — it stays in History"
            : "Remove \(row.cardName) from the queue"
    }

    private func moveToTop(_ id: UUID) {
        perform { try coordinator.moveQueuedTransferToTop(id) }
        selectedWaitingID = id
        focusedWaitingID = id
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func moveWaitingCard(_ id: UUID, offset: Int, rows: [QueueSessionRow]) {
        let waiting = rows.filter(\.isEditable)
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard waiting.indices.contains(destination) else { return }
        perform { try coordinator.moveQueuedTransfer(id: id, to: destination) }
        selectedWaitingID = id
        focusedWaitingID = id
    }

    @discardableResult
    private func moveWaitingCard(_ id: UUID, to targetID: UUID, rows: [QueueSessionRow]) -> Bool {
        let waiting = rows.filter(\.isEditable)
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

    private func eject(_ id: UUID) {
        Task { if let error = await coordinator.ejectQueueSource(id) { errorMessage = error } }
    }

    private func export(_ id: UUID, asCSV: Bool) {
        guard let record = coordinator.transferJournal.records.first(where: { $0.id == id }) else {
            errorMessage = "The transfer record is no longer available."
            return
        }
        do {
            exportDocument = try TransferHistoryDocument(record: record, asCSV: asCSV)
            exportType = asCSV ? .commaSeparatedText : .json
            showingExporter = true
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct SafeTransferHero: View {
    let row: QueueSessionRow
    let outcome: TransferOutcomePresentation
    let reduceMotion: Bool
    let eject: (() -> Void)?
    @State private var closesRing = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().stroke(CardSafetyTint.green.color.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: reduceMotion ? 1 : (closesRing ? 1 : 0.06))
                    .stroke(CardSafetyTint.green.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.title2.bold()).foregroundStyle(CardSafetyTint.green.color)
                    .scaleEffect(reduceMotion ? 1 : (closesRing ? 1 : 0.72))
                    .opacity(reduceMotion ? 1 : (closesRing ? 1 : 0))
            }
            .frame(width: 62, height: 62)
            .shadow(color: CardSafetyTint.green.color.opacity(0.22), radius: closesRing ? 10 : 5)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(outcome.finishTitle)
                    .font(.title2.weight(.semibold)).foregroundStyle(CardSafetyTint.green.color)
                Text(heroEvidence).font(.subheadline).foregroundStyle(.secondary)
                ForEach(outcome.advisoryLines, id: \.self) { advisory in
                    Label(advisory, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(CardSafetyTint.amber.color)
                }
            }
            Spacer(minLength: 8)
            if let eject {
                Button("Eject", action: eject)
                    .buttonStyle(.borderedProminent).tint(CardSafetyTint.green.color)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            guard !reduceMotion else { closesRing = true; return }
            withAnimation(.easeOut(duration: 0.8)) { closesRing = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(outcome.finishTitle). \(heroEvidence)")
    }

    private var heroEvidence: String {
        var parts: [String] = []
        if let evidence = row.evidence { parts.append(evidence) }
        let count = row.destinationNames.count
        parts.append("\(count) destination\(count == 1 ? "" : "s")")
        parts.append(row.verificationModeName)
        return parts.joined(separator: " · ")
    }
}
