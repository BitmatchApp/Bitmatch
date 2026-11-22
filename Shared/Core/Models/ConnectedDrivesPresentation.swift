import Foundation
import BitMatchEngine

nonisolated enum ConnectedDrivesPresentation {
    static let emptyTitle = "No other drives connected"

    struct Volume: Equatable, Sendable {
        let name: String
        let url: URL
        let totalBytes: Int64?
        let freeBytes: Int64?
        var isRemovable: Bool
        var isInternal: Bool
        var volumeID: String? = nil
        var cameraName: String? = nil
        var isHidden = false
        var isAppDiskImage = false
    }

    enum Role: Sendable { case card, backup, other }
    enum State: Sendable { case isSource, isBackup, none }

    struct Row: Identifiable, Equatable, Sendable {
        var id: URL { url }
        let url: URL
        let displayName: String
        let subtitle: String
        let role: Role
        let state: State
        let volumeID: String?
    }

    static func isVisible(_ volume: Volume) -> Bool {
        let path = volume.url.standardizedFileURL.path
        let name = volume.name.lowercased()
        let systemNames = ["macintosh hd", "macintosh hd - data", "system", "data", "recovery", "preboot", "vm", "update", "hardware", "xart", "xarts", "iscpreboot"]
        let systemName = systemNames.contains { base in
            name == base || (name.hasPrefix(base + " ") && Int(name.dropFirst(base.count + 1)) != nil)
        }
        return path != "/" && path != "/System" && !path.hasPrefix("/System/")
            && !volume.isHidden && !volume.name.hasPrefix(".")
            && !volume.url.lastPathComponent.hasPrefix(".") && !systemName && !volume.isAppDiskImage
    }

    static func make(volumes: [Volume], sourceURL: URL?, destinationURLs: [URL]) -> [Row] {
        let visible = volumes.filter(isVisible)
        // Two drives can share a name ("Untitled"); macOS mounts the second
        // as "Untitled 1", so show that to tell them apart.
        let nameCounts = Dictionary(grouping: visible, by: \.name).mapValues(\.count)
        return visible.map { volume in
            let camera = volume.cameraName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cameraName = camera.flatMap { $0.isEmpty ? nil : $0 }
            let state: State = contains(sourceURL, in: volume.url) ? .isSource
                : destinationURLs.contains(where: { contains($0, in: volume.url) }) ? .isBackup : .none
            let role: Role = cameraName != nil ? .card : volume.isInternal ? .other : .backup
            let total = volume.totalBytes.flatMap { $0 >= 0 ? ByteCountPresentation.capacity($0) : nil }
            let free = volume.freeBytes.flatMap { $0 >= 0 ? ByteCountPresentation.capacity($0) : nil }
            let capacity: String
            switch (free, total) {
            case let (free?, total?): capacity = "\(free) free of \(total)"
            case let (free?, nil): capacity = "\(free) free"
            case let (nil, total?): capacity = "Available space unknown · \(total) total"
            case (nil, nil): capacity = "Capacity unknown"
            }
            return Row(
                url: volume.url,
                displayName: nameCounts[volume.name, default: 0] > 1 ? volume.url.lastPathComponent : volume.name,
                subtitle: cameraName.map { "\($0) card · \(total ?? "Capacity unknown")" } ?? capacity,
                role: role,
                state: state,
                volumeID: volume.volumeID
            )
        }.sorted { lhs, rhs in
            if (lhs.role == .card) != (rhs.role == .card) { return lhs.role == .card }
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
        }
    }

    /// Inputs are resolved by the caller; this decision never reads the disk.
    static func queueCandidates(
        volumes: [Volume], sourceURL: URL, destinationURLs: [URL], queuedSourceURLs: [URL]
    ) -> [Row] {
        // Only a root-anchored card layout earns the card role. Removability
        // alone also describes ordinary shuttle and backup drives.
        let cardURLs = Set(volumes.filter { $0.cameraName != nil }.map(\.url))
        return make(volumes: volumes, sourceURL: sourceURL, destinationURLs: destinationURLs).filter { row in
            cardURLs.contains(row.url) && row.state == .none
                && !queuedSourceURLs.contains { contains($0, in: row.url) }
        }
    }

    private static func contains(_ selection: URL?, in volume: URL) -> Bool {
        guard let selection else { return false }
        let path = volume.standardizedFileURL.path
        let selected = selection.standardizedFileURL.path
        return selected == path || selected.hasPrefix(path + "/")
    }
}

enum SetupConnectedMenuPolicy {
    static func hasPotentialCapacity(_ availableBytes: Int64?, isSelected: Bool) -> Bool {
        guard !isSelected else { return true }
        guard let availableBytes, availableBytes >= 0 else { return true }
        return availableBytes > 0
    }

    static func destinationRows(
        _ rows: [ConnectedDrivesPresentation.Row],
        sourceURL: URL?,
        selectedURLs: [URL]
    ) -> [ConnectedDrivesPresentation.Row] {
        rows.filter { row in
            if case .card = row.role { return false }
            let rowPath = BackupTargetPolicy.canonicalPath(row.url)
            if selectedURLs.contains(where: { BackupTargetPolicy.canonicalPath($0) == rowPath }) { return true }
            guard let sourceURL else { return true }
            let sourcePath = BackupTargetPolicy.canonicalPath(sourceURL)
            return sourcePath != rowPath && !sourcePath.hasPrefix(rowPath + "/")
        }
    }
}
