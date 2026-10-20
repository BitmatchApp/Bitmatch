import SwiftUI
import UniformTypeIdentifiers
import BitMatchEngine

/// The same quiet Settings section and review flow on Mac, iPhone and iPad.
struct TransferSettingsSection: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @StateObject private var importer = TransferSettingsImportModel()
    @State private var choosingFile = false
    @State private var exporting = false
    @State private var exportDocument: TransferSettingsDocument?
    @State private var errorMessage: String?
    @State private var readTask: Task<Void, Never>?
    @State private var isReading = false

    var body: some View {
        Section {
            Button("Export settings…") {
                do {
                    exportDocument = TransferSettingsDocument(data: try coordinator.portableTransferSettings.encoded())
                    exporting = true
                } catch { errorMessage = error.localizedDescription }
            }
            .disabled(!coordinator.canImportTransferSettings)
            Button("Import settings…") { choosingFile = true }
                .disabled(!coordinator.canImportTransferSettings || isReading)
        } header: {
            Text("Transfer settings")
        } footer: {
            Text(coordinator.canImportTransferSettings
                ? "Move transfer options between devices. Backups and project details stay on this device."
                : "Finish current or queued work before importing settings.")
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                readTask?.cancel()
                isReading = true
                readTask = Task {
                    let reader = Task.detached { try TransferSettingsFileReader.read(url) }
                    do {
                        let data = try await withTaskCancellationHandler {
                            try await reader.value
                        } onCancel: { reader.cancel() }
                        try Task.checkCancellation()
                        try importer.preview(data, coordinator: coordinator)
                    } catch is CancellationError {
                        // Dismissing Settings cancels this read, not a transfer.
                    } catch { errorMessage = error.localizedDescription }
                    isReading = false
                }
            case .failure(let error):
                if (error as NSError).code != CocoaError.userCancelled.rawValue { errorMessage = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "BitMatch-transfer-settings") { result in
            if case .failure(let error) = result,
               (error as NSError).code != CocoaError.userCancelled.rawValue { errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: Binding(get: { importer.review != nil }, set: { if !$0 { importer.cancel(); errorMessage = nil } })) {
            if let review = importer.review {
                TransferSettingsReviewView(review: review, errorMessage: errorMessage,
                    apply: {
                        do { try importer.apply(to: coordinator); errorMessage = nil }
                        catch { errorMessage = error.localizedDescription }
                    }, cancel: { importer.cancel(); errorMessage = nil })
            }
        }
        .alert("Couldn’t use settings file", isPresented: Binding(
            get: { errorMessage != nil && importer.review == nil }, set: { if !$0 { errorMessage = nil } })
        ) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .onDisappear { readTask?.cancel() }
    }
}

struct TransferSettingsReviewView: View {
    let review: TransferSettingsReview
    var errorMessage: String? = nil
    let apply: () -> Void
    let cancel: () -> Void
    #if os(macOS)
    @State private var contentHeight: CGFloat = 440
    #endif

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text("Import settings")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 4)
            ScrollView {
                macReviewContent
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: TransferSettingsReviewHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            // Size short reviews to their content; keep long lists and errors
            // in a bounded viewport while the actions remain visible.
            .frame(height: min(440, contentHeight))
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply", action: apply).keyboardShortcut(.defaultAction)
                    .disabled(review.changes.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 480)
        .onPreferenceChange(TransferSettingsReviewHeightKey.self) { contentHeight = $0 }
        #else
        NavigationStack {
            Form { reviewFields }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply).disabled(review.changes.isEmpty)
                }
            }
        }
        #endif
    }

    #if os(macOS)
    private var macReviewContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if review.changes.isEmpty {
                Text("These transfer settings already match.")
            } else {
                GroupBox("Changes") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(review.changes) { change in
                            changeRow(change)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            if change.id != review.changes.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            if review.proposed.verificationMode == .quick { quickWarning.fixedSize(horizontal: false, vertical: true) }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            preservationNote.fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    #endif

    @ViewBuilder
    private var reviewFields: some View {
        if review.changes.isEmpty {
            Section { Text("These transfer settings already match.") }
        } else {
            Section("Changes") {
                ForEach(review.changes) { change in
                    changeRow(change).padding(.vertical, 2)
                }
            }
        }
        if review.proposed.verificationMode == .quick { Section { quickWarning } }
        if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
        Section { preservationNote }
    }

    private func changeRow(_ change: PortableTransferSettings.Change) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(change.title)
            Text("\(change.before) → \(change.after)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var quickWarning: some View {
        Label("Quick checks file sizes. It does not verify contents.", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
    }

    private var preservationNote: some View {
        Text("Changes apply to future transfers. Backups, project details and saved transfers stay as they are.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

#if os(macOS)
private struct TransferSettingsReviewHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
#endif

private struct TransferSettingsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        // Import uses the bounded URL reader, rather than loading an arbitrary
        // FileWrapper into memory through this export-only document.
        throw TransferSettingsImportError.invalidFile
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
