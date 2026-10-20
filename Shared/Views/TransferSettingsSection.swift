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

    var body: some View {
        NavigationStack {
            Form {
                if review.changes.isEmpty {
                    Section { Text("These transfer settings already match.") }
                } else {
                    Section("Changes") {
                        ForEach(review.changes) { change in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(change.title)
                                Text("\(change.before) → \(change.after)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if review.proposed.verificationMode == .quick {
                    Section {
                        Label("Quick checks file sizes. It does not verify contents.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                Section {
                    Text("Changes apply to future transfers. Backups, project details and saved transfers stay as they are.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            #if os(iOS)
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            #else
            .navigationTitle("Import settings")
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply).disabled(review.changes.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
    }
}

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
