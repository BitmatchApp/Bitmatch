import Foundation
import Combine
import Darwin
import BitMatchEngine

/// Bound reads before decoding: choosing a large report or media file must not
/// load it into memory just to find out it is not a settings file.
enum TransferSettingsFileReader {
    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw TransferSettingsImportError.invalidFile }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw TransferSettingsImportError.invalidFile
        }
        guard info.st_size <= PortableTransferSettings.maximumBytes else { throw TransferSettingsImportError.tooLarge }
        var data = Data()
        while data.count <= PortableTransferSettings.maximumBytes {
            try Task.checkCancellation()
            let next = try handle.read(upToCount: PortableTransferSettings.maximumBytes + 1 - data.count) ?? Data()
            if next.isEmpty { break }
            data.append(next)
        }
        try Task.checkCancellation()
        guard data.count <= PortableTransferSettings.maximumBytes else { throw TransferSettingsImportError.tooLarge }
        return data
    }
}

struct TransferSettingsReview: Identifiable, Sendable {
    let id = UUID()
    let current: PortableTransferSettings
    let proposed: PortableTransferSettings
    var changes: [PortableTransferSettings.Change] { proposed.changes(from: current) }
}

@MainActor
final class TransferSettingsImportModel: ObservableObject {
    @Published private(set) var review: TransferSettingsReview?

    func preview(_ data: Data, coordinator: SharedAppCoordinator) throws {
        review = nil
        guard coordinator.canImportTransferSettings else { throw TransferSettingsImportError.busy }
        let decoded = try PortableTransferSettings.decode(data)
        let current: PortableTransferSettings
        if decoded.folderRecipes == nil { current = coordinator.portableTransferSettings }
        else { current = try coordinator.portableTransferSettingsForExport() }
        review = TransferSettingsReview(current: current, proposed: decoded)
    }

    func cancel() { review = nil }

    func apply(to coordinator: SharedAppCoordinator) throws {
        guard let review else { throw TransferSettingsImportError.invalidFile }
        try coordinator.applyTransferSettings(review)
        self.review = nil
    }
}

@MainActor
extension SharedAppCoordinator {
    var canImportTransferSettings: Bool {
        !isOperationInProgress && !queueIsRunning && !isReplayingQueuedTransfer
            && !hasUnresolvedQueueRecords && editingSetupTransferID == nil && reviewedQueueRecordID == nil
            && !transferJournal.records.contains(where: { $0.state.showsInQueue })
            && !photographerJobViewModel.isPreparing && !photographerJobViewModel.hasPreparedIngestAwaitingStart
    }

    var portableTransferSettings: PortableTransferSettings {
        let naming = cameraLabels.settings
        return PortableTransferSettings(verificationMode: verificationMode, generateASCMHL: generateASCMHL,
            ignoreAppleDouble: appleDoubleSelection.enabled,
            reports: .init(makeReport: reportSettings.makeReport, includeThumbnails: reportSettings.includeThumbnails),
            naming: .init(position: naming.position, separator: naming.separator,
                autoNumber: naming.autoNumber, groupByCamera: naming.groupByCamera))
    }

    func portableTransferSettingsForExport() throws -> PortableTransferSettings {
        let current = portableTransferSettings
        let recipes = try photographerJobViewModel.validatedPortableFolderRecipes()
        return PortableTransferSettings(verificationMode: current.verificationMode,
            generateASCMHL: current.generateASCMHL, ignoreAppleDouble: current.ignoreAppleDouble,
            reports: current.reports, naming: current.naming,
            folderRecipes: recipes.isEmpty ? nil : recipes)
    }

    /// Durable marker for an import that has started but not yet committed.
    /// Written before any preset or preference changes and cleared only after
    /// every change has been applied, so a termination mid-import is known
    /// on the next launch instead of silently leaving a half-import.
    static var pendingTransferSettingsImportKey: String { "BitMatchPendingTransferSettingsImport.v1" }

    func applyTransferSettings(_ review: TransferSettingsReview) throws {
        // A transfer or queue can start while the preview is open. Recheck on
        // the main actor immediately before changing any preference.
        guard canImportTransferSettings else { throw TransferSettingsImportError.busy }
        let current: PortableTransferSettings
        if review.proposed.folderRecipes == nil { current = portableTransferSettings }
        else { current = try portableTransferSettingsForExport() }
        guard current == review.current else { throw TransferSettingsImportError.settingsChanged }
        let proposed = review.proposed
        // Record the intent before mutating anything. Every step of
        // `commitTransferSettings` is idempotent (recipe import skips recipes
        // already saved), so rolling the recorded import forward on the next
        // launch converges to the same state as an uninterrupted import.
        defaults.set(try proposed.encoded(), forKey: Self.pendingTransferSettingsImportKey)
        try commitTransferSettings(proposed)
        defaults.removeObject(forKey: Self.pendingTransferSettingsImportKey)
    }

    /// Rolls a recorded but uncommitted import forward. Called once during
    /// coordinator startup, before readiness is assessed. A record that can
    /// no longer be decoded is discarded; a commit that still fails keeps
    /// its record so the next launch retries instead of forgetting it.
    func recoverPendingTransferSettingsImport() {
        guard let data = defaults.data(forKey: Self.pendingTransferSettingsImportKey) else { return }
        guard let proposed = try? PortableTransferSettings.decode(data) else {
            defaults.removeObject(forKey: Self.pendingTransferSettingsImportKey)
            return
        }
        do {
            try commitTransferSettings(proposed)
            defaults.removeObject(forKey: Self.pendingTransferSettingsImportKey)
        } catch {
            // Keep the pending record for the next launch.
        }
    }

    private func commitTransferSettings(_ proposed: PortableTransferSettings) throws {
        if let recipes = proposed.folderRecipes {
            try photographerJobViewModel.importPortableFolderRecipes(recipes)
        }
        verificationMode = proposed.verificationMode
        generateASCMHL = proposed.generateASCMHL
        var reports = reportSettings
        reports.makeReport = proposed.reports.makeReport
        reports.includeThumbnails = proposed.reports.includeThumbnails
        reportSettings = reports
        if proposed.naming != portableTransferSettings.naming {
            var naming = cameraLabels.settings
            naming.position = proposed.naming.position
            naming.separator = proposed.naming.separator
            naming.autoNumber = proposed.naming.autoNumber
            naming.groupByCamera = proposed.naming.groupByCamera
            // The aggregate cameraLabelSettings setter also changes selection.
            // Preserve its private label/path and use the naming model directly.
            cameraLabels.settings = naming
        }
        appleDoubleSelection.enabled = proposed.ignoreAppleDouble
    }
}
