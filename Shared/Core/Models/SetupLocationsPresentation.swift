import Foundation
import BitMatchEngine

/// A destination is chosen as a folder, but people identify the physical
/// backup by its volume. Keep that identity consistent across Setup,
/// Progress, and the per-file list; never promote a temporary-folder path to
/// the primary label.
nonisolated enum DestinationIdentityPresentation {
    static func title(for url: URL) -> String {
        let components = url.standardizedFileURL.pathComponents
        if let volumes = components.firstIndex(of: "Volumes"), volumes + 1 < components.count {
            return components[volumes + 1]
        }
        let reportedName = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        return title(for: url, reportedVolumeName: reportedName)
    }

    static func title(for url: URL, reportedVolumeName: String?) -> String {
        let components = url.standardizedFileURL.pathComponents
        if let volumes = components.firstIndex(of: "Volumes"), volumes + 1 < components.count {
            return components[volumes + 1]
        }
        if let name = reportedVolumeName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        let fallback = url.lastPathComponent
        return fallback.isEmpty ? "Destination" : fallback
    }

    /// A compact secondary label for live progress. The complete path stays
    /// available as help text, without making `/var/folders/...` UI chrome.
    static func folderLabel(for url: URL, driveName: String) -> String {
        let folder = url.lastPathComponent
        guard !folder.isEmpty, folder != driveName else { return "Drive root" }
        return "Folder: \(folder)"
    }

    static func resultDriveName(for row: ResultRow, destinations: [URL]) -> String? {
        resultDriveName(for: row, destinationNames: nameMap(for: destinations))
    }

    static func nameMap(for destinations: [URL]) -> [String: String] {
        destinations.reduce(into: [:]) { names, destination in
            names[ResultPathMatch.comparablePath(destination.path)] = title(for: destination)
        }
    }

    static func resultDriveName(for row: ResultRow, destinationNames: [String: String]) -> String? {
        guard let destinationPath = row.destinationPath.map(ResultPathMatch.comparablePath) else {
            return row.destination
        }
        let matched = destinationNames.keys.filter { root in
            return destinationPath == root || destinationPath.hasPrefix(root + "/")
        }.max(by: { $0.count < $1.count })
        return matched.flatMap { destinationNames[$0] } ?? row.destination
    }
}

/// The source and backup boxes on Setup, on every platform: what each box
/// shows, which empty box glows, and whether they can be changed. Built from
/// values, so Mac, iPad and iPhone show the same boxes for the same
/// selection; only how a folder is picked differs (`SetupLocationsPlatform`).
struct SetupLocationsPresentation: Equatable {
    struct Capacity: Equatable, Sendable {
        let availableBytes: Int64
        let totalBytes: Int64?
    }

    struct Source: Equatable {
        let title: String
        let path: String
        /// "1,234 files · 12 GB", "Analyzing…", or nil before the scan.
        let detail: String?
        let cameraName: String?
    }

    struct StagedSource: Equatable, Identifiable {
        let id: UUID
        let title: String
        let path: String
        let detail: String
    }

    struct Backup: Equatable, Identifiable {
        var id: URL { url }
        let url: URL
        let title: String
        let path: String
        /// Capacity or the amount missing for this source, when available.
        let capacity: String?
    }

    let source: Source?
    let stagedSources: [StagedSource]
    let backups: [Backup]
    /// False while a transfer runs: no clearing, removing, adding or drops.
    let canEdit: Bool
    /// Once a card is staged, its backups are the shared route for this run.
    /// Remove the staged cards before changing that route.
    let canEditBackups: Bool
    /// The empty source box receives neutral next-step emphasis.
    let highlightsSource: Bool
    /// The empty backups box receives neutral next-step emphasis.
    let highlightsBackups: Bool
    /// Source and backups side by side, from the Setup screen's own width
    /// (toolbar and sidebar widths); stacked when compact.
    let sideBySide: Bool
    let showsAddAnotherCard: Bool
    let canAddAnotherCard: Bool
    let addAnotherCardDisabledReason: String?

    static func make(
        sourceURL: URL?,
        sourceFileCount: Int?,
        sourceBytes: Int64?,
        isAnalysingSource: Bool,
        cameraName: String?,
        stagedSources: [StagedSource] = [],
        destinationURLs: [URL],
        capacity: (URL) -> Capacity?,
        isOperationInProgress: Bool,
        showsAddAnotherCard: Bool = false,
        canAddAnotherCard: Bool? = nil,
        addAnotherCardDisabledReason: String? = nil,
        nextStep: TransferPlanPresentation.NextStep?,
        layout: AdaptiveNavigationPresentation
    ) -> Self {
        let source = sourceURL.map { url in
            Source(
                title: url.lastPathComponent,
                path: url.path,
                detail: sourceDetail(fileCount: sourceFileCount, bytes: sourceBytes, isAnalysing: isAnalysingSource),
                cameraName: cameraName.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return Self(
            source: source,
            stagedSources: stagedSources,
            backups: destinationURLs.map { url in
                Backup(
                    url: url,
                    title: DestinationIdentityPresentation.title(for: url),
                    path: url.path,
                    capacity: capacity(url).map { capacityLine($0, sourceBytes: sourceBytes) }
                )
            },
            canEdit: !isOperationInProgress,
            canEditBackups: !isOperationInProgress && stagedSources.isEmpty,
            highlightsSource: sourceURL == nil && nextStep == .chooseSource,
            highlightsBackups: destinationURLs.isEmpty && nextStep == .addBackup,
            sideBySide: layout != .compact,
            showsAddAnotherCard: showsAddAnotherCard,
            canAddAnotherCard: canAddAnotherCard
                ?? (!isOperationInProgress && sourceURL != nil && !destinationURLs.isEmpty),
            addAnotherCardDisabledReason: addAnotherCardDisabledReason
        )
    }

    /// Free space on the volume holding `url`, formatted. Holds a security
    /// scope for the read (a Files-picker folder on iOS).
    static func capacity(for url: URL) -> Capacity? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ]),
              values.volumeAvailableCapacityForImportantUsage != nil
                || values.volumeAvailableCapacity != nil else {
            return nil
        }
        let available = SafetyValidator.resolvedAvailableSpace(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            standardCapacity: values.volumeAvailableCapacity
        )
        return Capacity(
            availableBytes: available,
            totalBytes: values.volumeTotalCapacity.map(Int64.init)
        )
    }

    private static func sourceDetail(fileCount: Int?, bytes: Int64?, isAnalysing: Bool) -> String? {
        if isAnalysing { return "Analyzing…" }
        guard let fileCount, let bytes else { return nil }
        if fileCount == 0 { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: fileCount)) ?? "\(fileCount)"
        let files = fileCount == 1 ? "1 file" : "\(count) files"
        return "\(files) · \(ByteCountPresentation.fileSize(bytes))"
    }

    private static func capacityLine(_ capacity: Capacity, sourceBytes: Int64?) -> String {
        if let sourceBytes,
           let required = try? SafetyValidator.checkedRequiredSpace(
               sourceBytes: sourceBytes,
               headroomBytes: TransferReadiness.requiredHeadroomBytes
           ), capacity.availableBytes <= required {
            let missing = required - capacity.availableBytes + 1
            return "Needs \(ByteCountPresentation.fileSize(missing)) more"
        }
        let available = ByteCountPresentation.capacity(capacity.availableBytes)
        guard let total = capacity.totalBytes else { return "\(available) free" }
        return "\(available) free of \(ByteCountPresentation.capacity(total))"
    }
}
