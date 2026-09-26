import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// One shared queue/history surface; choosing another card never mutates the active transfer.
struct TransferLibraryView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var journal: LocalTransferJournal
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showAddTransfer = false
    @State private var showHistory = false
    @State private var errorMessage: String?
    @State private var exportDocument: TransferHistoryDocument?
    @State private var showExport = false
    @State private var reauthorizeRecord: LocalTransferRecord?
    @State private var exportType = UTType.json
    @State private var expandedIDs: Set<UUID> = []
    private let initialRecordID: UUID?

    init(
        coordinator: SharedAppCoordinator,
        journal: LocalTransferJournal,
        initialRecordID: UUID? = nil
    ) {
        self.initialRecordID = initialRecordID
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _journal = ObservedObject(wrappedValue: journal)
        _showHistory = State(initialValue: initialRecordID != nil)
        _expandedIDs = State(initialValue: initialRecordID.map { Set([$0]) } ?? [])
    }

    private var visibleRecords: [LocalTransferRecord] {
        TransferLibraryPresentation.visibleRecords(journal.records, showHistory: showHistory, search: showHistory ? search : "")
    }

    private var tabCounts: (queue: Int, history: Int) {
        TransferLibraryPresentation.tabCounts(journal.records)
    }

    /// Search only makes sense once History has something to search, and it
    /// never grabs focus on its own — `.searchable` never autofocuses.
    private var searchIsAvailable: Bool {
        showHistory && tabCounts.history > 0
    }

    var body: some View {
        NavigationStack {
            listContent
                #if os(macOS)
                .navigationTitle("")
                #else
                .navigationTitle("Transfers")
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbarContent }
                .modifier(OptionalSearchable(isActive: searchIsAvailable, text: $search))
                .sheet(isPresented: $showAddTransfer) { AddQueuedTransferView(coordinator: coordinator) }
                .sheet(item: $reauthorizeRecord) { record in
                    ReauthorizeLocationsView(coordinator: coordinator, journal: journal, recordID: record.id)
                }
                .fileExporter(isPresented: $showExport, document: exportDocument, contentType: exportType,
                              defaultFilename: "BitMatch-transfer") { result in
                    if case .failure(let error) = result { errorMessage = error.localizedDescription }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 700, minHeight: 480, idealHeight: 650)
        #endif
    }

    @ViewBuilder
    private var listContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                #if os(macOS)
                Text("Transfers")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                #endif
                Picker("Transfers", selection: $showHistory) {
                    Text("Queue (\(tabCounts.queue))").tag(false)
                    Text("History (\(tabCounts.history))").tag(true)
                }
                .pickerStyle(.segmented)
                .tint(.secondary)
                .labelsHidden()

                if let message = coordinator.queueMessage ?? journal.persistenceError ?? errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(ResultStatusTone.warning.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !showHistory {
                    Text("Queued transfers keep their own folders and settings. The queue stops when a transfer needs attention.")
                        .font(.caption).foregroundStyle(.secondary)
                    #if os(iOS)
                    Text("Keep BitMatch open. If iOS interrupts a transfer, reconnect the original folders and retry here.")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            if visibleRecords.isEmpty {
                ContentUnavailableView(
                    showHistory ? "No transfers yet" : "Queue is empty",
                    systemImage: showHistory ? "clock" : "tray",
                    description: Text(showHistory
                        ? "Finished transfers show up here."
                        : "Add a transfer to get started.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(visibleRecords) { record in
                            rowView(record).id(record.id)
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
        }
    }

    private var reviewTargetID: UUID? {
        TransferLibraryPresentation.reviewTargetRecordID(
            requested: initialRecordID,
            visibleRecords: visibleRecords
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !showHistory {
            ToolbarItem {
                Button("Add Transfer", systemImage: "plus") { showAddTransfer = true }
            }
            ToolbarItem {
                if coordinator.queueIsRunning {
                    Button("Stop After Current") { coordinator.stopQueueAfterCurrentTransfer() }
                } else {
                    Button("Run Queue", systemImage: "play.fill") { coordinator.startQueue() }
                        .disabled(journal.persistenceError != nil || !coordinator.queueRunCommandEnabled)
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
    }

    private func rowView(_ record: LocalTransferRecord) -> some View {
        let actions = TransferLibraryPresentation.actions(for: record)
        return DisclosureGroup(isExpanded: expandedBinding(record.id)) {
            detailsView(record, actions: actions)
        } label: {
            TransferRecordRow(record: record) {
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
                Button("Retry") { coordinator.retryTransfer(record.id) }.tint(.blue)
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
            Button("Retry") { coordinator.retryTransfer(record.id) }
        }
        if actions.retryWithoutASCMHL {
            Button("Retry without ASC MHL") { coordinator.retryTransfer(record.id, generateASCMHL: false) }
        }
        if actions.reconnect {
            Button("Reconnect…") { reauthorizeRecord = record }
        }
        if actions.export {
            Menu("Export") {
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
        VStack(alignment: .leading, spacing: 8) {
            Text(record.summary).fixedSize(horizontal: false, vertical: true)
            if actions.showsProjectReviewNote {
                Text("Review this card in its project before preparing another ingest.")
                    .foregroundStyle(.secondary)
            }
            Text("Source: \(record.source.url.path)").textSelection(.enabled)
            ForEach(record.destinations.indices, id: \.self) { index in
                Text("Backup: \(record.destinations[index].url.path)").textSelection(.enabled)
            }
            if actions.retryWithoutASCMHL {
                Button("Retry without ASC MHL") {
                    coordinator.retryTransfer(record.id, generateASCMHL: false)
                }
                .modifier(TouchTarget())
                Text("Rechecks copies and retries unfinished work. Existing ASC MHL histories are preserved; this attempt won’t create new ones.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(record.results.prefix(100)) { row in
                VStack(alignment: .leading) {
                    Text(row.fileName)
                    Text("\(row.destination ?? "Backup"): \(row.status)").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if record.results.count > 100 { Text("Showing the first 100 files. Export includes every result.") }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func export(_ record: LocalTransferRecord, asCSV: Bool) {
        do {
            exportDocument = try TransferHistoryDocument(record: record, asCSV: asCSV)
            exportType = asCSV ? .commaSeparatedText : .json
            showExport = true
        } catch { errorMessage = error.localizedDescription }
    }
}

/// Attaches `.searchable` only when it makes sense, so the field never
/// appears empty over an empty Queue and never grabs focus on its own.
private struct OptionalSearchable: ViewModifier {
    let isActive: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isActive {
            content.searchable(text: $text, prompt: "Search cards, jobs, or backups")
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
private struct ReauthorizeLocationsView: View {
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
            (index: i, title: i == 0 ? "Source" : "Backup \(i)", path: urls[i].path,
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

private struct AddQueuedTransferView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var destinations: [URL] = []
    @State private var mode = VerificationMode.standard
    @State private var generateASCMHL = true
    @State private var showSourcePicker = false
    @State private var showDestinationPicker = false
    @State private var scopedURLs: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    if let source { Text(source.lastPathComponent).font(.headline) }
                    Button("Choose card or folder") { showSourcePicker = true }
                }
                Section("Backups") {
                    ForEach(destinations, id: \.self) { destination in
                        HStack {
                            Text(destination.lastPathComponent)
                            Spacer()
                            Button("Remove", role: .destructive) { destinations.removeAll { $0 == destination } }
                        }
                    }
                    Button("Add backup folder") { showDestinationPicker = true }
                }
                Section {
                    Text(verificationSummary)
                    DisclosureGroup("Advanced") {
                        Picker("Verification", selection: $mode) {
                            ForEach(VerificationMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Text(mode.description).font(.callout)
                        Toggle("ASC MHL handoff record", isOn: $generateASCMHL).disabled(mode == .quick)
                    }
                    Text("Creates a one-time transfer using the current report settings. Locations and free space are checked again before copying.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(ResultStatusTone.warning.color) }
            }
            .formStyle(.grouped)
            .navigationTitle("Add transfer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to Queue") { enqueue() }.disabled(source == nil || destinations.isEmpty)
                }
            }
            .fileImporter(isPresented: $showSourcePicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                select(result, isSource: true)
            }
            .fileImporter(isPresented: $showDestinationPicker, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                select(result, isSource: false)
            }
        }
        .onDisappear { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440)
        #endif
    }

    private var verificationSummary: String {
        switch mode {
        case .quick: return "Copy only · size check"
        case .standard: return "Verified copy · SHA-256"
        case .thorough: return "Verified copy · SHA-256 and MD5"
        case .paranoid: return "Verified copy · checksums and byte comparison"
        }
    }

    private func select(_ result: Result<[URL], Error>, isSource: Bool) {
        do {
            for url in try result.get() {
                if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
                if isSource { source = url }
                else if !destinations.contains(url) { destinations.append(url) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func enqueue() {
        guard let source else { return }
        do {
            try coordinator.enqueue(source: source, destinations: destinations,
                verificationMode: mode, generateASCMHL: generateASCMHL)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
