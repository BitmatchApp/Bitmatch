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

    /// Marker for an import that has started but not yet committed. It holds
    /// the settings as they were when the import began, the proposal, and
    /// when it was written, so the next launch can tell an interrupted
    /// import from one the person has since overtaken by hand.
    ///
    /// This is a best-effort marker, not a durable transaction: UserDefaults
    /// is not forced to disk, so a termination before it reaches disk can
    /// leave part of an import applied with no record of it. Every commit
    /// step is idempotent, so importing the same file again is always safe.
    static var pendingTransferSettingsImportKey: String { "BitMatchPendingTransferSettingsImport.v2" }
    /// A record older than this is stale on arrival: it describes an intent
    /// from another day, not something the person is waiting on.
    static let pendingTransferSettingsImportMaximumAge: TimeInterval = 24 * 60 * 60

    struct PendingTransferSettingsImport: Codable, Equatable {
        let recordedAt: Date
        let current: PortableTransferSettings
        let proposed: PortableTransferSettings
    }

    static func pendingTransferSettingsImportRecord(
        current: PortableTransferSettings, proposed: PortableTransferSettings, recordedAt: Date = Date()
    ) throws -> Data {
        try JSONEncoder().encode(PendingTransferSettingsImport(recordedAt: recordedAt, current: current, proposed: proposed))
    }

    func applyTransferSettings(_ review: TransferSettingsReview) throws {
        // A transfer or queue can start while the preview is open. Recheck on
        // the main actor immediately before changing any preference.
        guard canImportTransferSettings else { throw TransferSettingsImportError.busy }
        let current: PortableTransferSettings
        if review.proposed.folderRecipes == nil { current = portableTransferSettings }
        else { current = try portableTransferSettingsForExport() }
        guard current == review.current else { throw TransferSettingsImportError.settingsChanged }
        let proposed = review.proposed
        // Record the intent before mutating anything.
        defaults.set(try Self.pendingTransferSettingsImportRecord(current: current, proposed: proposed),
                     forKey: Self.pendingTransferSettingsImportKey)
        do {
            try commitTransferSettings(proposed)
        } catch {
            // The failure is reported to the person right now. Nothing may
            // roll this intent forward later behind their back.
            defaults.removeObject(forKey: Self.pendingTransferSettingsImportKey)
            throw error
        }
        defaults.removeObject(forKey: Self.pendingTransferSettingsImportKey)
        pendingTransferSettingsImportWarning = nil
    }

    /// Rolls an interrupted import forward on launch, only when it is safe
    /// to: the record is fresh, nothing else is running, and the settings
    /// still lie between what the import started from and what it meant to
    /// apply. Anything else is discarded with a visible warning.
    func recoverPendingTransferSettingsImport() {
        guard let data = defaults.data(forKey: Self.pendingTransferSettingsImportKey) else { return }
        func discard(_ message: String, _ log: String) {
            defaults.removeObject(forKey: Self.pendingTransferSettingsImportKey)
            pendingTransferSettingsImportWarning = message
            SharedLogger.error(log, category: .error)
        }
        guard let record = try? JSONDecoder().decode(PendingTransferSettingsImport.self, from: data) else {
            discard("A settings import could not be finished because its saved record was damaged. Review your transfer settings.",
                    "Discarded an unreadable pending transfer-settings import.")
            return
        }
        guard Date().timeIntervalSince(record.recordedAt) <= Self.pendingTransferSettingsImportMaximumAge else {
            discard("A settings import from an earlier day was never finished and was not applied. Review your transfer settings.",
                    "Discarded an expired pending transfer-settings import.")
            return
        }
        let now = portableTransferSettings
        guard now.liesBetween(record.current, and: record.proposed) else {
            discard("Your transfer settings changed after an import was interrupted, so the import was not applied. Review your transfer settings.",
                    "Discarded a pending transfer-settings import that no longer matches the current settings.")
            return
        }
        guard canImportTransferSettings else {
            pendingTransferSettingsImportWarning =
                "A settings import has not finished yet. BitMatch will try again when it restarts; review your transfer settings."
            return
        }
        do {
            try commitTransferSettings(record.proposed)
            defaults.removeObject(forKey: Self.pendingTransferSettingsImportKey)
            pendingTransferSettingsImportWarning = nil
        } catch {
            pendingTransferSettingsImportWarning =
                "A settings import has not finished yet. BitMatch will try again when it restarts; review your transfer settings."
            SharedLogger.error("Pending transfer-settings import could not be finished: \(error.localizedDescription)", category: .error)
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
