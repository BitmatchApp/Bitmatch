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
    @State private var reauthorizeRecord: LocalTransferRecord?
    @FocusState private var editorFocus: EditorFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var volumeAccess: MacVolumeAccessModel

    init(coordinator: SharedAppCoordinator) {
        self.coordinator = coordinator
        _progress = ObservedObject(wrappedValue: coordinator.liveProgress)
    }

    var body: some View {
        let presentation = coordinator.queuePresentation
        VStack(alignment: .leading, spacing: 12) {
            if !presentation.rows.isEmpty {
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
                       presentation.rows.contains(where: { $0.safetyState == .waiting }),
                       coordinator.queuePausedRecordID == nil {
                        Button("Run Queue") { coordinator.startQueue() }
                            .controlSize(.small)
                            .disabled(!coordinator.queueRunCommandEnabled)
                    }
                }
                queueRows(presentation.rows)
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
        .sheet(item: $reauthorizeRecord) { record in
            ReauthorizeLocationsView(
                coordinator: coordinator,
                journal: coordinator.transferJournal,
                recordID: record.id
            )
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
                Text("Backups").font(.caption).foregroundStyle(.secondary)
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
                Button("Add Backup…") { choosingBackups = true }
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
    private func queueRows(_ rows: [QueueSessionRow]) -> some View {
        if rows.count > 2 {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in queueRow(row) }
                }
            }
            .frame(maxHeight: 160)
        } else {
            VStack(spacing: 8) {
                ForEach(rows) { row in queueRow(row) }
            }
        }
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
                Label(row.statusText, systemImage: row.safetyState.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(row.safetyState.tint.color)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(row.safetyState.tint.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityStatus)
            action(row)
        }
        .frame(minHeight: 46)
        .padding(.horizontal, 8)
        .background(
            selectedID == row.id || isRunning(row.safetyState)
                ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedID = row.id }
        .contextMenu {
            if row.safetyState == .waiting {
                Button("Move to Top") { moveToTop(row.id) }
                Button("Reconnect…") {
                    reauthorizeRecord = coordinator.transferJournal.records.first { $0.id == row.id }
                }
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

    private func removePausedCard(_ id: UUID) {
        do { try coordinator.removePausedCardFromQueue(id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func moveToTop(_ id: UUID) {
        do { try coordinator.moveQueuedTransferToTop(id) }
        catch { errorMessage = error.localizedDescription }
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
            Text(presentation.tally.text).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Button(presentation.ejectButtonTitle) { ejectAll(presentation.ejectableCardIDs) }
                        .buttonStyle(.borderedProminent)
                        .disabled(presentation.ejectableCardIDs.isEmpty)
                    if let reason = presentation.ejectDisabledReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
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

    private func ejectAll(_ ids: [UUID]) {
        Task {
            for id in ids {
                if let error = await coordinator.ejectQueueSource(id) {
                    errorMessage = error
                }
            }
        }
    }
}
