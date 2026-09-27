import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

struct MacQueueSection: View {
    private enum EditorFocus: Hashable { case addButton, source }
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject private var progress: LiveProgressFeed
    @ObservedObject private var volumeMonitor = VolumeMonitorService.shared
    @State private var selectedID: UUID?
    @State private var errorMessage: String?
    @State private var isAdding = false
    @State private var draftSource: URL?
    @State private var draftSourceUsesDriveAccess = false
    @State private var draftDestinations: [URL] = []
    @State private var draftMode = VerificationMode.standard
    @State private var draftASCMHL = true
    @State private var choosingSource = false
    @State private var choosingBackups = false
    @State private var isDropTargeted = false
    @FocusState private var editorFocus: EditorFocus?
    @FocusState private var focusedQueueRowID: UUID?
    @FocusState private var focusedGhostURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var volumeAccess: MacVolumeAccessModel

    init(coordinator: SharedAppCoordinator) {
        self.coordinator = coordinator
        _progress = ObservedObject(wrappedValue: coordinator.liveProgress)
    }

    var body: some View {
        let presentation = coordinator.queuePresentation
        let offers = connectedCardOffers
        VStack(alignment: .leading, spacing: 12) {
            if !presentation.rows.isEmpty || !offers.isEmpty {
                if presentation.pausedTitle != nil, coordinator.queuePausedRecordID != nil {
                    QueuePauseBanner(
                        presentation: presentation,
                        review: coordinator.reviewQueuedTransfer,
                        skipAndContinue: coordinator.skipPausedCardAndContinue,
                        remove: removePausedCard
                    )
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.headerTitle ?? "Queue")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        if let detail = presentation.headerDetail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !coordinator.queueIsRunning,
                       QueueCommandPolicy.showsResume(
                           hasSessionStarted: coordinator.queueSessionStarted,
                           waitingCount: presentation.rows.filter(\.isEditable).count
                       ),
                       coordinator.queuePausedRecordID == nil {
                        Button("Resume Queue") { coordinator.startQueue() }
                            .controlSize(.small)
                            .disabled(!coordinator.queueRunCommandEnabled)
                    }
                }
                queueRows(presentation.rows, ghostRows: offers)
            } else {
                Text("Queue")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            if coordinator.queueIsRunning || coordinator.isOperationInProgress {
                addCardRow
            }
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
        .fileImporter(isPresented: $choosingSource, allowedContentTypes: [.folder], allowsMultipleSelection: false) {
            choose($0, asSource: true)
        }
        .fileImporter(isPresented: $choosingBackups, allowedContentTypes: [.folder], allowsMultipleSelection: true) {
            choose($0, asSource: false)
        }
    }

    @ViewBuilder
    private var addCardRow: some View {
        if isAdding {
            inlineEditor
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            Button {
                openEditor()
            } label: {
                Label("Queue another card", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .focused($editorFocus, equals: .addButton)
            .accessibilityHint("Adds a card that arrived while this queue is running")
        }
    }

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sdcard").foregroundStyle(.secondary).accessibilityHidden(true)
                Picker("Card", selection: connectedCardSelection) {
                    Text("Choose a connected card").tag(nil as URL?)
                    ForEach(connectedCardRows) { row in
                        Text(row.displayName).tag(Optional(row.url))
                    }
                }
                .pickerStyle(.menu)
                .focused($editorFocus, equals: .source)
                Button("Choose Folder…") { choosingSource = true }
                    .controlSize(.small)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Destinations").font(.caption).foregroundStyle(.secondary)
                ForEach(draftDestinations, id: \.self) { destination in
                    HStack(spacing: 4) {
                        Text(destination.lastPathComponent).lineLimit(1)
                        Button {
                            draftDestinations.removeAll { $0 == destination }
                        } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(destination.lastPathComponent)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                }
                Button("Add destination…") { choosingBackups = true }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }

            HStack(spacing: 16) {
                Picker("Verification", selection: $draftMode) {
                    ForEach(VerificationMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.menu)
                Toggle("ASC MHL", isOn: $draftASCMHL)
                    .disabled(draftMode == .quick)
                Spacer(minLength: 0)
                Button("Cancel", action: closeEditor)
                    .keyboardShortcut(.cancelAction)
                Button("Queue Card", action: enqueueDraft)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftSource == nil || draftDestinations.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor).frame(width: 2)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isDropTargeted ? 2 : 1)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            draftSource = first
            draftSourceUsesDriveAccess = false
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onExitCommand(perform: closeEditor)
    }

    private var connectedCardRows: [ConnectedDrivesPresentation.Row] {
        let cardURLs = Set(volumeMonitor.connectedVolumes.filter { $0.cameraName != nil || $0.isRemovable }.map(\.url))
        return ConnectedDrivesPresentation.make(
            volumes: volumeMonitor.connectedVolumes,
            sourceURL: coordinator.sourceURL,
            destinationURLs: draftDestinations
        ).filter { cardURLs.contains($0.url) && $0.state == .none }
    }

    private var connectedCardOffers: [ConnectedDrivesPresentation.Row] {
        QueueConnectedCardPresentation.ghostRows(
            isTransferOrQueueRunning: coordinator.runningOneTimeTransfer != nil || coordinator.queueIsRunning,
            eligibleRows: coordinator.queueCandidates(volumes: volumeMonitor.connectedVolumes)
        )
    }

    private var connectedCardSelection: Binding<URL?> {
        Binding(
            get: { draftSource },
            set: { source in
                draftSource = source
                draftSourceUsesDriveAccess = source != nil
            }
        )
    }

    private func openEditor() {
        draftSource = nil
        draftSourceUsesDriveAccess = false
        draftDestinations = coordinator.destinationURLs
        draftMode = coordinator.verificationMode
        draftASCMHL = coordinator.generateASCMHL
        errorMessage = nil
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isAdding = true }
        Task { @MainActor in
            await Task.yield()
            editorFocus = .source
        }
    }

    private func closeEditor() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { isAdding = false }
        Task { @MainActor in
            await Task.yield()
            editorFocus = .addButton
        }
    }

    private func choose(_ result: Result<[URL], Error>, asSource: Bool) {
        do {
            for url in try result.get() {
                if asSource {
                    draftSource = url
                    draftSourceUsesDriveAccess = false
                }
                else if !draftDestinations.contains(url) { draftDestinations.append(url) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func enqueueDraft() {
        guard let source = draftSource else { return }
        let enqueue = {
            do {
                try coordinator.enqueueInlineCard(
                    source: source,
                    destinations: draftDestinations,
                    verificationMode: draftMode,
                    generateASCMHL: draftASCMHL && draftMode != .quick
                )
                closeEditor()
            } catch { errorMessage = error.localizedDescription }
        }
        guard draftSourceUsesDriveAccess && volumeAccess.needsDriveAccess else {
            enqueue()
            return
        }
        volumeAccess.requestVolumeAccess { granted in
            if granted { enqueue() }
        }
    }

    @ViewBuilder
    private func queueRows(
        _ rows: [QueueSessionRow],
        ghostRows: [ConnectedDrivesPresentation.Row]
    ) -> some View {
        if rows.count + ghostRows.count > 2 {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in reorderableQueueRow(row, rows: rows) }
                    ForEach(ghostRows) { row in ghostRow(row) }
                }
            }
            .frame(maxHeight: 160)
        } else {
            VStack(spacing: 8) {
                ForEach(rows) { row in reorderableQueueRow(row, rows: rows) }
                ForEach(ghostRows) { row in ghostRow(row) }
            }
        }
    }

    @ViewBuilder
    private func reorderableQueueRow(_ row: QueueSessionRow, rows: [QueueSessionRow]) -> some View {
        if row.safetyState == .waiting {
            queueRow(row)
                .focusable()
                .focused($focusedQueueRowID, equals: row.id)
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
        } else {
            queueRow(row)
        }
    }

    private func ghostRow(_ row: ConnectedDrivesPresentation.Row) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sdcard")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(row.displayName) is connected")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Queue next") { queueNext(row) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Queue \(row.displayName) next")
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 8)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .focusable()
        .focused($focusedGhostURL, equals: row.url)
        .onKeyPress(.return) {
            queueNext(row)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.displayName) is connected")
    }

    private func queueRow(_ row: QueueSessionRow) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sdcard").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.cardName).lineLimit(1).truncationMode(.middle).help(row.cardName)
                    HStack(spacing: 8) {
                        if let evidence = row.evidence { Text(evidence) }
                        Text(row.destinations).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if row.isEditable {
                    Label("Waiting", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(row.statusText, systemImage: row.safetyState.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(row.safetyState.tint.color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(row.safetyState.tint.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityStatus)
            if row.isEditable && selectedID == row.id {
                Button("Edit") { edit(row.id) }
                Button("Remove", role: .destructive) { remove(row.id) }
            } else {
                action(row)
            }
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 8)
        .background(
            selectedID == row.id || isRunning(row.safetyState)
                ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedID = row.id
            focusedQueueRowID = row.safetyState == .waiting ? row.id : nil
        }
        .contextMenu {
            if row.safetyState == .waiting {
                Button("Edit") { edit(row.id) }
                Button("Move to Top") { moveToTop(row.id) }
                Button("Remove", role: .destructive) { remove(row.id) }
            }
        }
    }

    @ViewBuilder
    private func action(_ row: QueueSessionRow) -> some View {
        if coordinator.queuePausedRecordID == row.id {
            EmptyView()
        } else {
            switch row.action {
            case .some(.eject):
                Button("Eject") { eject(row.id) }.accessibilityLabel("Eject \(row.cardName)")
            case .some(.review):
                Button("Review") { coordinator.reviewQueuedTransfer(row.id) }
                    .accessibilityLabel("Review \(row.cardName)")
            case .some(.ejected):
                Text("Ejected").font(.caption).foregroundStyle(.secondary)
            case .none:
                EmptyView()
            }
        }
    }

    private func remove(_ id: UUID) {
        do { try coordinator.removeQueuedTransfer(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func edit(_ id: UUID) {
        do { try coordinator.editSetupTransfer(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func removePausedCard(_ id: UUID) {
        do { try coordinator.removePausedCardFromQueue(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func moveToTop(_ id: UUID) {
        do { try coordinator.moveQueuedTransferToTop(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func moveWaitingCard(_ id: UUID, offset: Int, rows: [QueueSessionRow]) {
        let waiting = rows.filter { $0.safetyState == .waiting }
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard waiting.indices.contains(destination) else { return }
        do {
            try coordinator.moveQueuedTransfer(id: id, to: destination)
            selectedID = id
            focusedQueueRowID = id
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    private func moveWaitingCard(_ id: UUID, to targetID: UUID, rows: [QueueSessionRow]) -> Bool {
        let waiting = rows.filter { $0.safetyState == .waiting }
        guard let destination = waiting.firstIndex(where: { $0.id == targetID }),
              waiting.contains(where: { $0.id == id }) else { return false }
        do {
            try coordinator.moveQueuedTransfer(id: id, to: destination)
            selectedID = id
            focusedQueueRowID = id
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func queueNext(_ row: ConnectedDrivesPresentation.Row) {
        let enqueue = {
            do {
                try coordinator.enqueueNext(source: row.url)
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
        guard volumeAccess.needsDriveAccess else {
            enqueue()
            return
        }
        volumeAccess.requestVolumeAccess { granted in
            if granted { enqueue() }
        }
    }

    private func eject(_ id: UUID) {
        Task {
            if let error = await coordinator.ejectQueueSource(id) { errorMessage = error }
        }
    }

    private func isRunning(_ state: CardSafetyState) -> Bool {
        switch state {
        case .copying, .verifying, .preparing: true
        default: false
        }
    }
}

struct MacQueueSummaryView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @State private var errorMessage: String?
    @State private var exportDocument: TransferHistoryDocument?
    @State private var exportType = UTType.json
    @State private var showingExporter = false

    var body: some View {
        let presentation = coordinator.queuePresentation
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.summaryTitle ?? "Queue finished")
                .font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                if presentation.showsEjectAllButton {
                    Button("Eject all safe cards") { ejectAllSafeCards() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Eject all safe cards")
                }
                Button("Copy Summary") { TransferSummaryPasteboard.copy(presentation.copySummary) }
                if presentation.showsExportReport {
                    Menu("Export Report") {
                        ForEach(reportRecords) { record in
                            Menu(record.title) {
                                Button("JSON report") { export(record, asCSV: false) }
                                Button("CSV results") { export(record, asCSV: true) }
                            }
                        }
                    }
                }
                Button("New Transfer") { coordinator.finishQueueSessionAndStartNewTransfer() }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(CardSafetyTint.red.color) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fileExporter(
            isPresented: $showingExporter,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: "BitMatch-transfer"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private var reportRecords: [LocalTransferRecord] {
        coordinator.transferJournal.records.filter {
            coordinator.queueSessionRecordIDs.contains($0.id)
                && $0.reportSettings.makeReport && $0.state != .queued && $0.state != .running
                && !$0.summary.localizedCaseInsensitiveContains("report could not be saved")
        }
    }

    private func export(_ record: LocalTransferRecord, asCSV: Bool) {
        do {
            exportDocument = try TransferHistoryDocument(record: record, asCSV: asCSV)
            exportType = asCSV ? .commaSeparatedText : .json
            showingExporter = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func ejectAllSafeCards() {
        Task {
            errorMessage = await coordinator.ejectAllSafeQueueSources()
        }
    }
}
