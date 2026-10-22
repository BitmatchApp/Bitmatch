import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// Finished transfers in the same window as the operational workflow.
struct TransferLibraryView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var journal: LocalTransferJournal
    @State private var search = ""
    @State private var pdfTask: Task<Void, Never>?
    @State private var retryTask: Task<Void, Never>?
    @State private var preparingPDF = false
    @State private var errorMessage: String?
    @State private var exportDocument: TransferHistoryDocument?
    @State private var showExport = false
    @State private var showDiagnostics = false
    @State private var diagnosticsDocument: TransferDiagnosticsDocument?
    @State private var reauthorizeRecord: LocalTransferRecord?
    @State private var exportType = UTType.json
    @State private var expandedIDs: Set<UUID> = []
    @StateObject private var historySearch = TransferHistorySearchModel()
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
    }

    private var visibleMatches: [TransferLibraryPresentation.SearchMatch] {
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return journal.records.compactMap { record in
                guard TransferLibraryPresentation.isVisible(state: record.state, showHistory: true) else { return nil }
                return TransferLibraryPresentation.SearchMatch(record: record, clipLine: nil)
            }
        }
        return historySearch.matches
    }

    private var searchBinding: Binding<String> {
        Binding(get: { search }, set: { query in
            search = query
            historySearch.updateQuery(query)
        })
    }

    private var tabCounts: (queue: Int, history: Int) {
        TransferLibraryPresentation.tabCounts(journal.records)
    }

    var body: some View {
        // One scan set per body pass: visibleMatches/tabCounts used to be
        // recomputed by every property the body touched (list, placeholder,
        // review target, searchable gate).
        let matches = visibleMatches
        let counts = tabCounts
        return listContent(matches: matches, historyCount: counts.history)
            #if os(macOS)
            .navigationTitle("History")
            .toolbar { toolbarContent }
            #else
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            #endif
            // Search only makes sense once History has something to search,
            // and it never grabs focus on its own — `.searchable` never autofocuses.
            .modifier(OptionalSearchable(isActive: counts.history > 0, text: searchBinding))
            .onAppear { historySearch.resume(records: journal.records, query: search) }
            .onReceive(journal.$records) { records in
                historySearch.replaceRecords(records)
            }
            .onDisappear {
                pdfTask?.cancel()
                retryTask?.cancel()
                historySearch.cancel()
            }
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
    private func listContent(matches: [TransferLibraryPresentation.SearchMatch], historyCount: Int) -> some View {
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

            if let placeholder = searchPlaceholder(matches: matches, historyCount: historyCount) {
                TransferHistorySearchPlaceholderView(state: placeholder) {
                    historySearch.resume(records: journal.records, query: search)
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(matches) { match in
                            rowView(match.record, clipLine: match.clipLine)
                                .id(match.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowSeparator(.visible)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
                        }
                    }
                    .task(id: reviewTargetID(matches: matches)) {
                        guard let targetID = reviewTargetID(matches: matches) else { return }
                        await Task.yield()
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                    #if os(macOS)
                    .listStyle(.inset)
                    #else
                    .listStyle(.plain)
                    #endif
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Button { exportDiagnostics() } label: {
                    Label("Export diagnostics…", systemImage: "doc.badge.gearshape")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                #if os(macOS)
                Text("Diagnostics stay on this Mac until you export them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                Text("Diagnostics stay on this device until you export them.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func searchPlaceholder(
        matches: [TransferLibraryPresentation.SearchMatch], historyCount: Int
    ) -> TransferHistorySearchPlaceholder? {
        if historySearch.isSearching { return .searching }
        if historySearch.searchFailed { return .failed }
        guard matches.isEmpty else { return nil }
        return historyCount > 0 ? .noMatches : .emptyHistory
    }

    private func reviewTargetID(matches: [TransferLibraryPresentation.SearchMatch]) -> UUID? {
        TransferLibraryPresentation.reviewTargetRecordID(
            requested: initialRecordID,
            visibleRecords: matches.map(\.record)
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // On Mac the shell already provides Back; History adds only Export.
        #if os(iOS)
        if let onBack {
            ToolbarItem(placement: .navigation) {
                Button(action: onBack) { Label("Back", systemImage: "chevron.left") }
                    .accessibilityHint("Returns to the transfer screen")
            }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Button { exportDiagnostics() } label: {
                Label("Export diagnostics…", systemImage: "doc.badge.gearshape")
            }
            .accessibilityHint("Exports diagnostics as a file; nothing is sent automatically")
        }
    }

    private func exportDiagnostics() {
        do {
            diagnosticsDocument = TransferDiagnosticsDocument(data: try TransferDiagnosticStore.shared.exportData())
            showDiagnostics = true
        } catch { errorMessage = "Diagnostics could not be exported. \(error.localizedDescription)" }
    }

    private func rowView(_ record: LocalTransferRecord, clipLine: String?) -> some View {
        let actions = TransferLibraryPresentation.actions(for: record)
        return DisclosureGroup(isExpanded: expandedBinding(record.id)) {
            if expandedIDs.contains(record.id) {
                detailsView(record, actions: actions)
            }
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
                Button("Retry") { retry(record.id) }.tint(.blue).disabled(retryTask != nil)
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
                .disabled(retryTask != nil)
        }
        if actions.retryWithoutASCMHL {
            Button("Retry without ASC MHL") { retry(record.id, generateASCMHL: false) }
                .disabled(retryTask != nil)
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
            Button("Move to top") {
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
        let scope = VerificationScopeEvidence(selectedMode: record.verificationMode,
            results: record.results, includeModePlan: record.plannedFileCounts != nil)
        VStack(alignment: .leading, spacing: 8) {
            Label(safetyState.title, systemImage: safetyState.symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(safetyState.tint.color)
            Text("Saved attempt message: \(record.summary)")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(scope.selectedModeLine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(scope.recordedResultsLine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let exclusion = scope.exclusionLine {
                Text(exclusion).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if record.plannedFileCounts == nil {
                Text("Original selected-file plan was not saved; these details describe recorded results only.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if TransferLibraryPresentation.savedResultsCoverSelectedPlan(record) == false {
                Text("Saved results do not cover the selected-file plan.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if [.interrupted, .cancelled, .failed].contains(record.state) {
                Text("The attempt ended before completion; the selected mode does not mean every check finished.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let operatorName = EvidenceWriter.normalizedNotes(record.reportSettings.operatorName) {
                Text("Operator: \(operatorName)").font(.caption).textSelection(.enabled)
            }
            if let notes = EvidenceWriter.normalizedNotes(record.reportSettings.notes) {
                Text(notes).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
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
            TransferRecoveryDetails(record: record, history: coordinator.transferJournal.records)
            Text("Source: \(record.source.url.path)").textSelection(.enabled)
            ForEach(record.destinations.indices, id: \.self) { index in
                Text("Destination: \(record.destinations[index].url.path)").textSelection(.enabled)
            }
            if actions.retryWithoutASCMHL {
                Button("Retry without ASC MHL") {
                    retry(record.id, generateASCMHL: false)
                }
                .disabled(retryTask != nil)
                .modifier(TouchTarget())
                Text("Rechecks copies and retries unfinished work. Existing ASC MHL histories are preserved; this attempt won’t create new ones.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(record.results.prefix(100)) { row in
                VStack(alignment: .leading) {
                    Text(row.fileName)
                    Text("\(row.destination ?? "Destination"): \(TransferHistoryResultPresentation.statusText(for: row, mode: record.verificationMode))")
                        .foregroundStyle(.secondary)
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
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor in
            defer { retryTask = nil }
            await coordinator.retryTransferPrepared(id, generateASCMHL: generateASCMHL)
            guard !Task.isCancelled else { return }
            onBack?()
        }
    }
}

/// Attaches `.searchable` only when it makes sense, so the field never
/// appears empty over an empty Queue and never grabs focus on its own.
private struct OptionalSearchable: ViewModifier {
    let isActive: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isActive {
            content.searchable(text: $text, prompt: "Search cards, clips, or backups")
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
    @State private var accessTask: Task<Void, Never>?
    @State private var requestGeneration = UUID()
    @State private var isBusy = true
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
                                if stale == nil && isBusy {
                                    ProgressView().controlSize(.small)
                                } else if stale == nil {
                                    Label("Status unavailable", systemImage: "exclamationmark.triangle")
                                        .font(.callout)
                                        .foregroundStyle(ResultStatusTone.warning.color)
                                        .labelStyle(.titleAndIcon)
                                } else if stale?.contains(location.index) == true && !location.identityCanBeConfirmed {
                                    Label("Cannot reconnect", systemImage: "exclamationmark.triangle")
                                        .font(.callout)
                                        .foregroundStyle(ResultStatusTone.warning.color)
                                        .labelStyle(.titleAndIcon)
                                } else if stale?.contains(location.index) == true {
                                    Button("Choose") {
                                        pickingIndex = location.index
                                        showingPicker = true
                                    }.disabled(isBusy)
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
                        .disabled(record == nil || isBusy)
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
            .onDisappear {
                accessTask?.cancel()
                // A reauthorization commit owns its mount until it returns.
                // Its task releases any picker scope in defer; otherwise there
                // is no worker using these scopes and they can be released now.
                if accessTask == nil { releaseAllScopes() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440)
        #endif
    }

    private func refresh() {
        accessTask?.cancel()
        let request = UUID()
        requestGeneration = request
        stale = nil
        message = nil
        messageIsError = false
        isBusy = true
        accessTask = Task { @MainActor in
            defer {
                if requestGeneration == request {
                    isBusy = false
                    accessTask = nil
                }
            }
            do {
                let result = try await coordinator.reauthorizationStatusPrepared(id: recordID)
                guard !Task.isCancelled, requestGeneration == request else { return }
                stale = result
            } catch is CancellationError {
                return
            } catch {
                guard requestGeneration == request else { return }
                stale = nil
                message = "Could not check folder access. \(error.localizedDescription)"
                messageIsError = true
            }
        }
    }

    private func select(_ result: Result<[URL], Error>, resourceIndex: Int) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            guard !isBusy else { return }
            if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
            let request = UUID()
            requestGeneration = request
            stale = nil
            message = nil
            messageIsError = false
            isBusy = true
            accessTask = Task { @MainActor in
                defer {
                    releaseScope(for: url)
                    if requestGeneration == request {
                        isBusy = false
                        accessTask = nil
                    }
                }
                do {
                    try await coordinator.reauthorizeTransferPrepared(
                        recordID, resourceIndex: resourceIndex, url: url
                    )
                    guard !Task.isCancelled, requestGeneration == request else { return }
                    let status = try await coordinator.reauthorizationStatusPrepared(id: recordID)
                    guard !Task.isCancelled, requestGeneration == request else { return }
                    stale = status
                    message = "Reconnected. Dismiss and choose Retry on the transfer to continue."
                    messageIsError = false
                } catch is CancellationError {
                    return
                } catch {
                    guard requestGeneration == request else { return }
                    stale = nil
                    message = "Could not reconnect this folder. \(error.localizedDescription)"
                    messageIsError = true
                }
            }
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }

    private func releaseScope(for url: URL) {
        guard let index = scopedURLs.lastIndex(of: url) else { return }
        let scopedURL = scopedURLs.remove(at: index)
        scopedURL.stopAccessingSecurityScopedResource()
    }

    private func releaseAllScopes() {
        let urls = scopedURLs
        scopedURLs.removeAll()
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
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

/// Kept inside expanded transfer details on every platform.
struct TransferRecoveryDetails: View {
    let record: LocalTransferRecord
    let history: [LocalTransferRecord]

    private var summaries: [TransferRecoverySummary] { TransferRecoverySummary.make(record) }
    private var isRecovery: Bool {
        record.retryOf != nil || record.results.contains(where: \.wasReused)
            || [.interrupted, .cancelled, .failed, .issues].contains(record.state)
    }

    var body: some View {
        if isRecovery {
            VStack(alignment: .leading, spacing: 8) {
                if let previousID = record.retryOf {
                    if let previous = history.first(where: { $0.id == previousID }) {
                        Text("Retry of \(previous.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Retry · previous attempt no longer in history")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(summaries) { summary in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.title).font(.caption.weight(.semibold))
                        Text("Verified: \(summary.reused) reused · \(summary.copied) copied")
                        if summary.unverified > 0 { Text("\(summary.unverified) copied, unverified") }
                        Text("\(summary.failed) failed · \(summary.pending.map(String.init) ?? "—") pending")
                        if summary.excluded > 0 { Text("\(summary.excluded) excluded") }
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
                if summaries.contains(where: { $0.pending == nil || ($0.pending ?? 0) > 0 }) {
                    Text(summaries.contains(where: { $0.pending == nil })
                         ? "Pending: no saved result. — means the file count wasn’t recorded."
                         : "Pending files have no saved result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
