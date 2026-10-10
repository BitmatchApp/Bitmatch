import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// Finished transfers in the same window as the operational workflow.
struct TransferLibraryView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var journal: LocalTransferJournal
    @State private var search = ""
    @State private var pdfTask: Task<Void, Never>?
    @State private var preparingPDF = false
    @State private var errorMessage: String?
    @State private var exportDocument: TransferHistoryDocument?
    @State private var showExport = false
    @State private var showDiagnostics = false
    @State private var diagnosticsDocument: TransferDiagnosticsDocument?
    @State private var reauthorizeRecord: LocalTransferRecord?
    @State private var exportType = UTType.json
    @State private var expandedIDs: Set<UUID> = []
    @State private var searchIndex: TransferLibraryPresentation.SearchIndex
    private let initialRecordID: UUID?
    private let onBack: (() -> Void)?

    init(
        coordinator: SharedAppCoordinator,
        journal: LocalTransferJournal,
        initialRecordID: UUID? = nil,
        onBack: (() -> Void)? = nil
    ) {
        self.initialRecordID = initialRecordID
        self.onBack = onBack
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _journal = ObservedObject(wrappedValue: journal)
        _expandedIDs = State(initialValue: initialRecordID.map { Set([$0]) } ?? [])
        _searchIndex = State(initialValue: TransferLibraryPresentation.SearchIndex(records: journal.records))
    }

    private var visibleMatches: [TransferLibraryPresentation.SearchMatch] {
        TransferLibraryPresentation.visibleMatches(
            journal.records,
            showHistory: true,
            search: search,
            index: searchIndex
        )
    }

    private var visibleRecords: [LocalTransferRecord] {
        visibleMatches.map(\.record)
    }

    private var tabCounts: (queue: Int, history: Int) {
        TransferLibraryPresentation.tabCounts(journal.records)
    }

    /// Search only makes sense once History has something to search, and it
    /// never grabs focus on its own — `.searchable` never autofocuses.
    private var searchIsAvailable: Bool {
        tabCounts.history > 0
    }

    var body: some View {
        listContent
            #if os(macOS)
            .navigationTitle("History")
            #else
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            #endif
            .modifier(OptionalSearchable(isActive: searchIsAvailable, text: $search))
            .onReceive(journal.$records) { records in
                searchIndex = TransferLibraryPresentation.SearchIndex(records: records)
            }
            .onDisappear { pdfTask?.cancel() }
            .sheet(item: $reauthorizeRecord) { record in
                ReauthorizeLocationsView(coordinator: coordinator, journal: journal, recordID: record.id)
            }
            .fileExporter(isPresented: $showExport, document: exportDocument, contentType: exportType,
                          defaultFilename: "BitMatch-transfer") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
            }
            .fileExporter(isPresented: $showDiagnostics, document: diagnosticsDocument,
                          contentType: .json, defaultFilename: "BitMatch-diagnostics") { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
            }
        #if os(macOS)
        .onExitCommand { onBack?() }
        #endif
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            if let message = coordinator.queueMessage ?? journal.persistenceError ?? errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(ResultStatusTone.warning.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }

            if visibleRecords.isEmpty {
                ContentUnavailableView(
                    "No finished transfers yet",
                    systemImage: "clock",
                    description: Text("Finished transfers show up here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(visibleMatches) { match in
                            rowView(match.record, clipLine: match.clipLine)
                                .id(match.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowSeparator(.visible)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
                        }
                    }
                    .task(id: reviewTargetID) {
                        guard let reviewTargetID else { return }
                        await Task.yield()
                        proxy.scrollTo(reviewTargetID, anchor: .center)
                    }
                    #if os(macOS)
                    .listStyle(.inset)
                    #else
                    .listStyle(.plain)
                    #endif
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    do {
                        diagnosticsDocument = TransferDiagnosticsDocument(data: try TransferDiagnosticStore.shared.exportData())
                        showDiagnostics = true
                    } catch { errorMessage = "Diagnostics could not be exported. \(error.localizedDescription)" }
                } label: {
                    Label("Export diagnostics…", systemImage: "doc.badge.gearshape")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                Text("Recent transfer phases and errors. No footage names or paths. Nothing is sent automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var reviewTargetID: UUID? {
        TransferLibraryPresentation.reviewTargetRecordID(
            requested: initialRecordID,
            visibleRecords: visibleRecords
        )
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onBack {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                    .accessibilityHint("Returns to the transfer screen")
            }
        }
    }
    #endif

    private func rowView(_ record: LocalTransferRecord, clipLine: String?) -> some View {
        let actions = TransferLibraryPresentation.actions(for: record)
        return DisclosureGroup(isExpanded: expandedBinding(record.id)) {
            detailsView(record, actions: actions)
        } label: {
            TransferRecordRow(record: record, clipMatchLine: clipLine) {
                Menu {
                    menuItems(record, actions: actions)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .modifier(TouchTarget())
                .accessibilityLabel("More actions for \(record.title)")
            }
        }
        .contextMenu { menuItems(record, actions: actions) }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if actions.removeFromQueue {
                Button("Remove", role: .destructive) {
                    do { try coordinator.removeQueuedTransfer(record.id) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
            if actions.retry {
                Button("Retry") { retry(record.id) }.tint(.blue)
            }
        }
        #endif
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { expandedIDs.insert(id) } else { expandedIDs.remove(id) }
            }
        )
    }

    @ViewBuilder
    private func menuItems(_ record: LocalTransferRecord, actions: TransferLibraryPresentation.Actions) -> some View {
        if actions.retry {
            Button("Retry") { retry(record.id) }
        }
        if actions.retryWithoutASCMHL {
            Button("Retry without ASC MHL") { retry(record.id, generateASCMHL: false) }
        }
        if actions.reconnect {
            Button("Reconnect…") { reauthorizeRecord = record }
        }
        if actions.export {
            Menu("Export report") {
                Button(preparingPDF ? "Preparing PDF…" : "PDF report") { exportPDF(record, previews: false) }.disabled(preparingPDF)
                Button("PDF with clip previews") { exportPDF(record, previews: true) }.disabled(preparingPDF)
                Button("JSON report") { export(record, asCSV: false) }
                Button("CSV results") { export(record, asCSV: true) }
            }
        }
        if actions.removeFromQueue {
            Divider()
            Button("Move to Top") {
                do { try coordinator.moveQueuedTransferToTop(record.id) }
                catch { errorMessage = error.localizedDescription }
            }
            Button("Remove from queue", role: .destructive) {
                do { try coordinator.removeQueuedTransfer(record.id) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }

    @ViewBuilder
    private func detailsView(_ record: LocalTransferRecord, actions: TransferLibraryPresentation.Actions) -> some View {
        let safetyState = TransferLibraryPresentation.safetyState(for: record)
        VStack(alignment: .leading, spacing: 8) {
            Text(record.summary).fixedSize(horizontal: false, vertical: true)
            if let warning = safetyState.eraseWarning {
                Label(warning, systemImage: safetyState.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(safetyState.tint.color)
            }
            if actions.showsProjectReviewNote {
                Text("Review this card in its project before preparing another ingest.")
                    .foregroundStyle(.secondary)
            }
            ForEach(TransferHistoryMetrics.make(record)) { metric in
                Text("\(metric.title): \(metric.value)").textSelection(.enabled)
            }
            Text("Counts describe saved result rows, including exclusions. Missing measurements are shown as —.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Source: \(record.source.url.path)").textSelection(.enabled)
            ForEach(record.destinations.indices, id: \.self) { index in
                Text("Destination: \(record.destinations[index].url.path)").textSelection(.enabled)
            }
            if actions.retryWithoutASCMHL {
                Button("Retry without ASC MHL") {
                    retry(record.id, generateASCMHL: false)
                }
                .modifier(TouchTarget())
                Text("Rechecks copies and retries unfinished work. Existing ASC MHL histories are preserved; this attempt won’t create new ones.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(record.results.prefix(100)) { row in
                VStack(alignment: .leading) {
                    Text(row.fileName)
                    Text("\(row.destination ?? "Destination"): \(row.status)").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if record.results.count > 100 { Text("Showing the first 100 files. Export includes every result.") }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func exportPDF(_ record: LocalTransferRecord, previews: Bool) {
        pdfTask?.cancel()
        preparingPDF = true
        pdfTask = Task {
            defer { preparingPDF = false }
            do {
                let work = Task.detached { try await ReportExporter.historyPDF(record: record, includeThumbnails: previews) }
                let data = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                exportDocument = TransferHistoryDocument(data: data)
                exportType = .pdf
                showExport = true
            } catch is CancellationError { }
            catch { errorMessage = "PDF could not be exported. \(error.localizedDescription)" }
        }
    }

    private func export(_ record: LocalTransferRecord, asCSV: Bool) {
        do {
            exportDocument = try TransferHistoryDocument(record: record, asCSV: asCSV)
            exportType = asCSV ? .commaSeparatedText : .json
            showExport = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func retry(_ id: UUID, generateASCMHL: Bool? = nil) {
        coordinator.retryTransfer(id, generateASCMHL: generateASCMHL)
        onBack?()
    }
}

/// Attaches `.searchable` only when it makes sense, so the field never
/// appears empty over an empty Queue and never grabs focus on its own.
private struct OptionalSearchable: ViewModifier {
    let isActive: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isActive {
            content.searchable(text: $text, prompt: "Search cards, clips, or destinations")
        } else {
            content
        }
    }
}

/// Gives a control a 44 pt touch target on iPhone and iPad. The Mac keeps
/// its native control size.
private struct TouchTarget: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.frame(minHeight: 44).contentShape(Rectangle())
        #else
        content
        #endif
    }
}

/// Reconnects expired transfer locations to their identical original folders.
/// A different drive or folder is rejected, never substituted; earlier attempts
/// and their evidence stay untouched.
struct ReauthorizeLocationsView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var journal: LocalTransferJournal
    let recordID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var stale: [Int]?
    @State private var pickingIndex: Int?
    @State private var showingPicker = false
    @State private var scopedURLs: [URL] = []
    @State private var message: String?
    @State private var messageIsError = false

    private var record: LocalTransferRecord? {
        journal.records.first { $0.id == recordID }
    }

    private var locations: [(index: Int, title: String, path: String, identityCanBeConfirmed: Bool)] {
        guard let record else { return [] }
        let resources = [record.source] + record.destinations
        let urls = resources.map(\.url)
        return urls.indices.map { i in
            (index: i, title: i == 0 ? "Source" : "Destination \(i)", path: urls[i].path,
             identityCanBeConfirmed: resources[i].volumeID != nil && resources[i].resourceID != nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Pick the original folders to restore access. Anything else is rejected: choose the original drive and folder, or start a new transfer. Earlier attempts and their evidence are kept.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if record != nil {
                    Section("Locations") {
                        ForEach(locations, id: \.index) { location in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(location.title).font(.headline)
                                    Text(URL(fileURLWithPath: location.path).lastPathComponent)
                                    Text(location.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                if stale == nil {
                                    ProgressView().controlSize(.small)
                                } else if stale?.contains(location.index) == true && !location.identityCanBeConfirmed {
                                    Label("Cannot reconnect", systemImage: "exclamationmark.triangle")
                                        .font(.callout)
                                        .foregroundStyle(ResultStatusTone.warning.color)
                                        .labelStyle(.titleAndIcon)
                                } else if stale?.contains(location.index) == true {
                                    Button("Choose") {
                                        pickingIndex = location.index
                                        showingPicker = true
                                    }
                                } else {
                                    Label("Connected", systemImage: "checkmark.circle.fill")
                                        .font(.callout)
                                        .foregroundStyle(NonVerificationSuccessPresentation.tone.color)
                                        .labelStyle(.iconOnly)
                                }
                            }
                        }
                    }
                    if let stale, locations.contains(where: { stale.contains($0.index) && !$0.identityCanBeConfirmed }) {
                        Section {
                            Text("BitMatch cannot safely reconnect a location whose original volume and folder identity was not recorded. Start a new transfer for that location.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if stale?.isEmpty == true {
                        Section {
                            Text("Every location resolves. Dismiss and choose Retry on the transfer.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section {
                        Text("This transfer is no longer in history.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Section {
                        Label(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(messageIsError ? .orange : .green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    Button("Check again") { refresh() }
                        .disabled(record == nil)
                }
            }
            .navigationTitle("Reconnect folders")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                guard let index = pickingIndex else { return }
                pickingIndex = nil
                select(result, resourceIndex: index)
            }
            .onAppear { refresh() }
            .onDisappear { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440)
        #endif
    }

    private func refresh() {
        stale = coordinator.reauthorizationStatus(id: recordID)
    }

    private func select(_ result: Result<[URL], Error>, resourceIndex: Int) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            try coordinator.reauthorizeTransfer(recordID, resourceIndex: resourceIndex, url: url)
            message = "Reconnected. Dismiss and choose Retry on the transfer to continue."
            messageIsError = false
            refresh()
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }
}

private struct TransferDiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
