import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// One journal-backed transfer list rendered directly below Setup on every
/// platform. Platform-only capabilities are injected: iOS can offer its Files
/// importer, while only macOS supplies an eject action and transition context.
struct TransferQueueSection: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var progress: LiveProgressFeed
    @ObservedObject private var stateService: OperationStateService
    @ObservedObject private var background: IOSBackgroundTaskService
    @State private var expandedIDs: Set<UUID> = []
    @State private var selectedWaitingID: UUID?
    @State private var heroID: UUID?
    @State private var heroDismissTask: Task<Void, Never>?
    @State private var confirmingCancel = false
    @State private var errorMessage: String?
    @State private var exportDocument: TransferHistoryDocument?
    @State private var exportType = UTType.json
    @State private var showingExporter = false
    @State private var choosingSource = false
    @State private var transitionClearTask: Task<Void, Never>?
    @FocusState private var focusedWaitingID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let offersAddCard: Bool
    private let showsHeaderTitle: Bool
    private let ejectSource: ((UUID) async -> String?)?
    private let transferTransitionContext: QueueTransferTransitionContext?

    init(
        coordinator: SharedAppCoordinator,
        offersAddCard: Bool = false,
        showsHeaderTitle: Bool = true,
        ejectSource: ((UUID) async -> String?)? = nil,
        transferTransitionContext: QueueTransferTransitionContext? = nil
    ) {
        self.coordinator = coordinator
        self.offersAddCard = offersAddCard
        self.showsHeaderTitle = showsHeaderTitle
        self.ejectSource = ejectSource
        self.transferTransitionContext = transferTransitionContext
        _progress = ObservedObject(wrappedValue: coordinator.liveProgress)
        _stateService = ObservedObject(wrappedValue: coordinator.stateService)
        _background = ObservedObject(wrappedValue: IOSBackgroundTaskService.shared)
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
                    queueRunningNotice(presentation)
                    rows(presentation.rows)
                    addCardButton(presentation)
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
        .fileImporter(
            isPresented: $choosingSource,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: addCard
        )
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "BitMatch-transfer"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func header(_ presentation: QueueSessionPresentation) -> some View {
        if showsHeaderTitle {
            #if os(macOS)
            headerRow(presentation)
            #else
            ViewThatFits(in: .horizontal) {
                headerRow(presentation)
                VStack(alignment: .leading, spacing: 8) {
                    headerTitle(presentation)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        headerActions(presentation)
                    }
                }
                .controlSize(.large)
            }
            #endif
        } else {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                headerActions(presentation)
            }
            #if os(iOS)
            .controlSize(.large)
            #endif
        }
    }

    private func headerRow(_ presentation: QueueSessionPresentation) -> some View {
        HStack(alignment: .firstTextBaseline) {
            headerTitle(presentation)
            Spacer()
            headerActions(presentation)
        }
    }

    private func headerTitle(_ presentation: QueueSessionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Transfers").font(.headline).accessibilityAddTraits(.isHeader)
            if let detail = presentation.headerDetail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func headerActions(_ presentation: QueueSessionPresentation) -> some View {
        if presentation.showsClearFinished {
            #if os(macOS)
            Button("Clear finished") { coordinator.clearFinishedQueueRows() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Remove finished rows from this list. They remain in History.")
            #else
            Button("Clear finished") { coordinator.clearFinishedQueueRows() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Remove finished rows from this list. They remain in History.")
            #endif
        }
        if !coordinator.queueIsRunning,
           QueueCommandPolicy.showsResume(
            hasSessionStarted: coordinator.queueSessionStarted,
            waitingCount: presentation.rows.filter(\.isEditable).count
           ), coordinator.queuePausedRecordID == nil {
            #if os(macOS)
            Button("Resume Queue") { coordinator.startQueue() }
                .controlSize(.small)
                .disabled(!coordinator.queueRunCommandEnabled)
            #else
            Button("Resume Queue") { coordinator.startQueue() }
                .controlSize(.large)
                .disabled(!coordinator.queueRunCommandEnabled)
            #endif
        }
    }

    @ViewBuilder
    private func rows(_ rows: [QueueSessionRow]) -> some View {
        #if os(macOS)
        if rows.count > 8 {
            ScrollView {
                LazyVStack(spacing: 8) { transferRows(rows) }.padding(.trailing, 3)
            }
            .frame(maxHeight: 520)
        } else {
            VStack(spacing: 8) { transferRows(rows) }
        }
        #else
        LazyVStack(spacing: 8) { transferRows(rows) }
        #endif
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
            .accessibilityAction(named: "Edit") { edit(row.id) }
            .accessibilityAction(named: "Remove from queue") { remove(row.id) }
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
        .background(RoundedRectangle(cornerRadius: 8).fill(baseColor(for: row)))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor(for: row))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func collapsedRow(_ row: QueueSessionRow) -> some View {
        #if os(macOS)
        macCollapsedRow(row)
        #else
        mobileCollapsedRow(row)
        #endif
    }

    private func macCollapsedRow(_ row: QueueSessionRow) -> some View {
        HStack(spacing: 8) {
            if row.isEditable || row.isFinished {
                removeIcon(row)
            } else {
                statusIcon(row)
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
                expandButton(row)
            }
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { selectOrExpand(row) }
        .accessibilityLabel(row.accessibilityStatus)
        .contextMenu { waitingContextMenu(row) }
    }

    @ViewBuilder
    private func mobileCollapsedRow(_ row: QueueSessionRow) -> some View {
        if row.isFinished {
            mobileFinishedRow(row)
        } else {
            mobileActiveRow(row)
        }
    }

    private func mobileFinishedRow(_ row: QueueSessionRow) -> some View {
        HStack(spacing: 8) {
            removeIcon(row)
            statusIcon(row)
            mobileFinishedSummary(row)
            Spacer(minLength: 4)
            expandButton(row)
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { selectOrExpand(row) }
        .accessibilityLabel(row.accessibilityStatus)
    }

    private func mobileActiveRow(_ row: QueueSessionRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                if row.isEditable { removeIcon(row) }
                else { statusIcon(row) }
                if coordinator.editingSetupTransferID != row.id {
                    if row.isEditable {
                        mobileWaitingSummary(row)
                    } else {
                        collapsedSummary(row)
                    }
                } else {
                    Spacer(minLength: 0)
                }
                if row.isEditable {
                    Button("Waiting · Edit") { edit(row.id) }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                } else {
                    compactAction(row)
                    expandButton(row)
                }
            }
            .frame(minHeight: 44)
            if row.isRunning, let fraction = row.progressFraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .accessibilityLabel(row.statusText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { selectOrExpand(row) }
        .accessibilityLabel(row.accessibilityStatus)
        .contextMenu { waitingContextMenu(row) }
    }

    private func mobileWaitingSummary(_ row: QueueSessionRow) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(row.waitingText)
                .font(.subheadline)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 4) {
                Text(row.cardName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text("→ \(row.waitingDestinationText)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.waitingText)
    }

    private func removeIcon(_ row: QueueSessionRow) -> some View {
        Button { removeFromList(row) } label: {
            #if os(macOS)
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary).frame(width: 24, height: 24)
            #else
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary).frame(width: 44, height: 44)
            #endif
        }
        .buttonStyle(.borderless)
        .help(removeHelp(for: row))
        .accessibilityLabel(removeHelp(for: row))
    }

    private func statusIcon(_ row: QueueSessionRow) -> some View {
        Image(systemName: row.safetyState.symbol)
            .foregroundStyle(row.isRunning ? Color.accentColor : row.safetyState.tint.color)
            .frame(width: 24).accessibilityHidden(true)
    }

    private func expandButton(_ row: QueueSessionRow) -> some View {
        Button { toggleExpanded(row.id) } label: {
            #if os(macOS)
            Image(systemName: expandedIDs.contains(row.id) ? "chevron.up" : "chevron.down")
                .frame(width: 24, height: 24)
            #else
            Image(systemName: expandedIDs.contains(row.id) ? "chevron.up" : "chevron.down")
                .frame(width: 44, height: 44)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expandedIDs.contains(row.id) ? "Collapse \(row.cardName)" : "Expand \(row.cardName)")
    }

    @ViewBuilder
    private func waitingContextMenu(_ row: QueueSessionRow) -> some View {
        if row.isEditable {
            Button("Edit") { edit(row.id) }
            Button("Move to Top") { moveToTop(row.id) }
            Button("Remove", role: .destructive) { remove(row.id) }
        }
    }

    private func selectOrExpand(_ row: QueueSessionRow) {
        if row.isEditable {
            selectedWaitingID = row.id
            focusedWaitingID = row.id
        } else {
            toggleExpanded(row.id)
        }
    }

    private func collapsedText(_ row: QueueSessionRow) -> String {
        row.isEditable
            ? row.waitingText
            : row.oneLineStatus(timeRemaining: row.isRunning ? liveProgressPresentation.timeRemaining : nil)
    }

    @ViewBuilder
    private func collapsedSummary(_ row: QueueSessionRow) -> some View {
        #if os(macOS)
        let text = Text(collapsedText(row))
            .font(.subheadline.weight(row.isFinished ? .medium : .regular))
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
        let text = Text(collapsedText(row))
            .font(.subheadline.weight(row.isFinished ? .medium : .regular))
            .lineLimit(row.isEditable ? 1 : 2).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
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
            if QueueEjectPolicy.canOfferEject(
                row: row,
                platformSupportsEject: ejectSource != nil
            ), heroID != row.id && !expandedIDs.contains(row.id) {
                Button("Eject") { eject(row.id) }.accessibilityLabel("Eject \(row.cardName)")
            }
        case .some(.review):
            #if os(macOS)
            Button("Review") {
                coordinator.markQueueTransferReviewed(row.id)
                expandedIDs.insert(row.id)
            }
            #else
            Button("Review") {
                coordinator.markQueueTransferReviewed(row.id)
                expandedIDs.insert(row.id)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            #endif
        case .some(.ejected):
            Text("Ejected").font(.caption).foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func queueRunningNotice(_ presentation: QueueSessionPresentation) -> some View {
        #if os(iOS)
        if let note = QueueRunningNoticePolicy.sectionNote(
            isRunning: presentation.rows.contains(where: \.isRunning),
            isMobile: true,
            progress: liveProgressPresentation
        ) {
            Label(note.text, systemImage: note.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
        }
        #endif
    }

    private func mobileFinishedSummary(_ row: QueueSessionRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Text(row.cardName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· " + row.statusText.lowercased())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.subheadline.weight(.medium))

            VStack(alignment: .leading, spacing: 1) {
                Text(row.cardName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.statusText.lowercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
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
                row: row,
                outcome: outcome,
                reduceMotion: reduceMotion,
                eject: QueueEjectPolicy.canOfferEject(
                    row: row,
                    platformSupportsEject: ejectSource != nil
                ) ? { eject(row.id) } : nil
            )
        } else if let outcome = row.outcome {
            finishedDetails(row, outcome: outcome)
        }
    }

    private var liveProgressPresentation: TransferProgressPresentation {
        // These observed services publish independently of the coordinator.
        // Reading them here keeps pause/resume and the iOS background-time
        // line live while a row remains collapsed.
        _ = stateService.currentState
        _ = background.isInBackground
        _ = background.backgroundTimeRemainingSeconds
        return TransferProgressPresentation.make(coordinator: coordinator)
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
            finishedActions(row, outcome: outcome)
        }
    }

    @ViewBuilder
    private func finishedActions(_ row: QueueSessionRow, outcome: TransferOutcomePresentation) -> some View {
        #if os(macOS)
        finishedActionRow(row, outcome: outcome)
        #else
        ViewThatFits(in: .horizontal) {
            finishedActionRow(row, outcome: outcome)
            VStack(alignment: .leading, spacing: 8) { finishedActionButtons(row, outcome: outcome) }
        }
        .controlSize(.large)
        #endif
    }

    private func finishedActionRow(_ row: QueueSessionRow, outcome: TransferOutcomePresentation) -> some View {
        HStack(spacing: 8) { finishedActionButtons(row, outcome: outcome) }
    }

    @ViewBuilder
    private func finishedActionButtons(_ row: QueueSessionRow, outcome: TransferOutcomePresentation) -> some View {
        if outcome.canRetry {
            Button("Retry") { coordinator.retryTransfer(row.id) }.buttonStyle(.borderedProminent)
        }
        if outcome.canExport {
            #if os(macOS)
            Menu("Export Report") {
                Button("JSON report") { export(row.id, asCSV: false) }
                Button("CSV results") { export(row.id, asCSV: true) }
            }.menuStyle(.button)
            #else
            Menu("Export Report") {
                Button("JSON report") { export(row.id, asCSV: false) }
                Button("CSV results") { export(row.id, asCSV: true) }
            }
            .buttonStyle(.bordered)
            #endif
        }
        Button("Copy Summary") { TransferSummaryPasteboard.copy(row.copySummary) }
        if QueueEjectPolicy.canOfferEject(
            row: row,
            platformSupportsEject: ejectSource != nil
        ) {
            Button("Eject") { eject(row.id) }
        }
    }

    @ViewBuilder
    private func addCardButton(_ presentation: QueueSessionPresentation) -> some View {
        if offersAddCard && !presentation.showsQueueSummary {
            Button { choosingSource = true } label: {
                Label("Add Card", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!canAddCard)
            .accessibilityHint("Choose another card to run with the current destinations")
        }
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

    private func addCard(_ result: Result<[URL], Error>) {
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
            if QueueEjectPolicy.shouldAutoEject(
                row: row,
                platformSupportsEject: ejectSource != nil,
                preferenceEnabled: coordinator.autoEjectWhenSafe
            ) {
                eject(row.id)
            }
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
        guard let ejectSource,
              let row = coordinator.queuePresentation.rows.first(where: { $0.id == id }),
              QueueEjectPolicy.canOfferEject(row: row, platformSupportsEject: true)
        else { return }
        Task { if let error = await ejectSource(id) { errorMessage = error } }
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
        Group {
            #if os(macOS)
            heroRow
            #else
            ViewThatFits(in: .horizontal) {
                heroRow
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 16) {
                        ring
                        evidence
                    }
                    if let eject {
                        Button("Eject", action: eject)
                            .buttonStyle(.borderedProminent).tint(CardSafetyTint.green.color)
                    }
                }
            }
            #endif
        }
        .padding(.vertical, 6)
        .onAppear {
            guard !reduceMotion else { closesRing = true; return }
            withAnimation(.easeOut(duration: 0.8)) { closesRing = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(outcome.finishTitle). \(heroEvidence)")
    }

    private var heroRow: some View {
        HStack(alignment: .center, spacing: 16) {
            ring
            evidence
            Spacer(minLength: 8)
            if let eject {
                Button("Eject", action: eject)
                    .buttonStyle(.borderedProminent).tint(CardSafetyTint.green.color)
            }
        }
    }

    private var ring: some View {
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
                .symbolEffect(.bounce, value: closesRing)
        }
        .frame(width: 62, height: 62)
        .shadow(color: CardSafetyTint.green.color.opacity(0.22), radius: 10)
        .accessibilityHidden(true)
    }

    private var evidence: some View {
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

extension CardSafetyTint {
    var color: Color {
        switch self {
        case .gray: .gray
        case .blue: .blue
        case .green: .green
        case .amber: .orange
        case .red: .red
        }
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
