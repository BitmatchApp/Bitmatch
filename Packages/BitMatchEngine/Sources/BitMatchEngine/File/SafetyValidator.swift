// Shared/Core/Services/File/SafetyValidator.swift
// Moved to Shared module to enable iOS safety validation
import Foundation

/// Validates file operations for safety before execution
/// Used by both macOS and iOS to prevent dangerous operations
public final class SafetyValidator {
    /// Free space a backup needs beyond the source size. The copy refuses to
    /// start without it, and the preflight uses the same number.
    public static let requiredHeadroomBytes: Int64 = 1_000_000_000


    // MARK: - Pre-Operation Safety Checks

    public static func performSafetyChecks(
        source: URL,
        destinations: [URL],
        sourceSizeBytes: Int64
    ) async throws {
        // Validate source exists and is accessible
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FileOperationError.sourceNotFound(source.path)
        }

        // Check source is a directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FileOperationError.sourceNotDirectory(source.path)
        }

        try validateSourceTreeForCopy(source: source)

        let uniqueDestinationPaths = Set(destinations.map { PathContainment.comparablePath(canonicalPath($0)) })
        guard uniqueDestinationPaths.count == destinations.count else {
            throw FileOperationError.unsafeOperation("Destination folders must be unique")
        }

        // Check each destination
        for destination in destinations {
            try await validateDestination(destination, source: source)
        }

        // Check for sufficient space
        try await validateAvailableSpace(sourceSizeBytes: sourceSizeBytes, destinations: destinations)

        SharedLogger.info("Safety checks passed for \(destinations.count) destinations", category: .transfer)
    }

    public static func performComparisonChecks(left: URL, right: URL) async throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: left.path) else {
            throw FileOperationError.sourceNotFound(left.path)
        }

        guard fm.fileExists(atPath: right.path) else {
            throw FileOperationError.sourceNotFound(right.path)
        }

        guard !detectSymlinkLoop(at: left) else {
            throw FileOperationError.symlinkLoop(left.path)
        }
        guard !detectSymlinkLoop(at: right) else {
            throw FileOperationError.symlinkLoop(right.path)
        }

        SharedLogger.info("Comparison safety checks passed", category: .transfer)
    }

    private static func validateDestination(_ destination: URL, source: URL) async throws {
        let fm = FileManager.default

        if isProtectedSystemPath(destination) {
            throw FileOperationError.unsafeOperation("System folders cannot be used as destinations")
        }

        // The same rule every add path uses, as the engine's last word.
        if let refusal = BackupTargetPolicy.refusal(for: destination, origin: .userChoice, source: source) {
            throw FileOperationError.unsafeOperation(refusal)
        }

        if let safetyIssue = destinationSafetyIssue(source: source, destination: destination) {
            throw FileOperationError.unsafeOperation(safetyIssue)
        }

        // The destination is a user-selected existing folder. Requiring it to
        // exist prevents path-based creation before the later descriptor pin.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileOperationError.destinationNotWritable(destination.path)
        }

        // Verify it's accessible
        guard fm.isWritableFile(atPath: destination.path) else {
            throw FileOperationError.destinationNotWritable(destination.path)
        }

        // Check for symlink loops on both ends. A symlinked destination
        // would redirect writes if it ever bypassed the descriptor-pinned
        // open, so it is rejected here too.
        guard !detectSymlinkLoop(at: source) else {
            throw FileOperationError.symlinkLoop(source.path)
        }
        guard !detectSymlinkLoop(at: destination) else {
            throw FileOperationError.symlinkLoop(destination.path)
        }

        // Ancestor walk: no component of the destination path itself may be
        // a symlink (outside the fixed /private system aliases), even when
        // it forms no loop.
        if let offender = firstSymlinkComponent(in: destination) {
            throw FileOperationError.unsafeOperation("Destination contains a symbolic link: \(offender)")
        }

        // Network drive warning
        if isNetworkVolume(destination) {
            SharedLogger.warning("Network destination detected: \(destination.lastPathComponent) - may be slower", category: .transfer)
        }
    }

    private static func validateAvailableSpace(sourceSizeBytes: Int64, destinations: [URL]) async throws {
        let requiredSpace = try checkedRequiredSpace(
            sourceBytes: sourceSizeBytes,
            headroomBytes: requiredHeadroomBytes
        )

        for destination in destinations {
            let availableSpace = getAvailableSpace(at: destination)

            guard availableSpace > requiredSpace else {
                let availableGB = Double(availableSpace) / 1_000_000_000
                let requiredGB = Double(requiredSpace) / 1_000_000_000
                throw FileOperationError.insufficientSpace(
                    destination.path,
                    available: availableGB,
                    required: requiredGB
                )
            }
        }
    }

    // MARK: - Network Drive Detection

    public static func isNetworkVolume(_ url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey])
            return !(resourceValues.volumeIsLocal ?? true)
        } catch {
            return false
        }
    }

    // MARK: - Symlink Component Detection

    /// Fixed macOS system aliases beneath /private. Mirrors the pinned
    /// destination traversal: only these top-level components may resolve
    /// through a symlink; every other symlink component is rejected.
    private static let systemAliasFirstComponents: Set<String> = ["var", "tmp", "etc"]

    /// Ancestor-by-ancestor readlink walk. Returns the first path whose own
    /// component is a symlink, or nil when every prefix is a real directory.
    /// Unlike the loop check below this also catches a plain symlinked
    /// ancestor (which the descriptor-pinned open would reject later).
    public static func firstSymlinkComponent(in url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        var prefix = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.dropFirst().enumerated() {
            let candidate = prefix.appendingPathComponent(component)
            let isSystemAlias = index == 0 && systemAliasFirstComponents.contains(component)
            if !isSystemAlias,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) != nil {
                return candidate.path
            }
            prefix = candidate
        }
        return nil
    }

    // MARK: - Symlink Loop Detection

    private static func detectSymlinkLoop(at url: URL, visited: Set<String> = []) -> Bool {
        // readlink-based walk: destinationOfSymbolicLink resolves real
        // symlinks. resolvingAliasFileAt targets Finder aliases and is the
        // wrong API here. A repeat or an over-deep chain fails closed.
        var current = url.standardized.path
        var seen = visited
        for _ in 0..<100 {
            guard seen.insert(current).inserted else { return true }
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else {
                return false
            }
            if destination.hasPrefix("/") {
                current = URL(fileURLWithPath: destination).standardized.path
            } else {
                current = URL(fileURLWithPath: current).deletingLastPathComponent()
                    .appendingPathComponent(destination).standardized.path
            }
        }
        return true
    }

    // MARK: - Path Safety

    /// How two folders overlap on disk, after resolving symlinks.
    public enum FolderOverlap: Equatable, Sendable {
        /// Both URLs name the same folder.
        case same
        /// `second` is inside `first`.
        case secondInsideFirst
        /// `first` is inside `second`.
        case firstInsideSecond
    }

    /// The one path-overlap rule behind copy destinations and Compare.
    public static func folderOverlap(_ first: URL, _ second: URL) -> FolderOverlap? {
        let firstPath = canonicalPath(first)
        let secondPath = canonicalPath(second)
        if PathContainment.isSamePath(firstPath, secondPath) { return .same }
        if PathContainment.isWithin(secondPath, root: firstPath) { return .secondInsideFirst }
        if PathContainment.isWithin(firstPath, root: secondPath) { return .firstInsideSecond }
        return nil
    }

    public static func destinationSafetyIssue(source: URL, destination: URL) -> String? {
        switch folderOverlap(source, destination) {
        case .same:
            // Don't copy to self
            return "Destination is the source folder"
        case .secondInsideFirst:
            // Don't copy into the source tree. This can recursively grow the transfer.
            return "Destination is inside the source folder"
        case .firstInsideSecond:
            // Don't use a parent of the source as the destination root. BitMatch writes
            // into destination/sourceName, which can collide with the original source.
            return "Destination contains the source folder"
        case nil:
            return nil
        }
    }

    public static func resolvedDestinationRoot(source: URL, destination: URL, settings: CameraLabelSettings) -> URL {
        return destinationRootComponents(source: source, settings: settings).reduce(destination) { root, component in
            root.appendingPathComponent(component)
        }
    }

    /// The exact relative layout used below every selected destination. Keeping
    /// this separate from URL resolution lets descriptor-pinned writes preserve
    /// legacy camera-grouping behavior without re-resolving a pathname later.
    public static func destinationRootComponents(source: URL, settings: CameraLabelSettings) -> [String] {
        if let components = settings.destinationPathComponents {
            return components.map(CameraLabelSettings.sanitizePathComponent)
        }

        let cardName = source.lastPathComponent
        if settings.groupByCamera {
            let raw = settings.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let group = raw.isEmpty ? "Camera" : CameraLabelSettings.sanitizePathComponent(raw)
            return [group, cardName]
        }

        let labeledCardName = settings.formattedFolderName(for: cardName)
        return [labeledCardName.isEmpty ? cardName : labeledCardName]
    }

    public static func resolvedDestinationRootChecked(
        source: URL,
        destination: URL,
        settings: CameraLabelSettings
    ) throws -> URL {
        guard let components = settings.destinationPathComponents else {
            return resolvedDestinationRoot(source: source, destination: destination, settings: settings)
        }

        guard !components.isEmpty else {
            throw FileOperationError.unsafeOperation("Destination path components cannot be empty")
        }

        var root = destination
        var firstSymbolicLink: URL?
        for (index, component) in components.enumerated() {
            guard !containsTraversalComponent(component) else {
                throw FileOperationError.unsafeOperation(
                    "Invalid destination path component at index \(index)"
                )
            }

            let sanitized = CameraLabelSettings.sanitizePathComponent(component)
            guard sanitized != "untitled" || component == "untitled" else {
                throw FileOperationError.unsafeOperation(
                    "Invalid destination path component at index \(index)"
                )
            }

            let nextRoot = root.appendingPathComponent(sanitized)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: nextRoot.path)) != nil,
               firstSymbolicLink == nil {
                firstSymbolicLink = nextRoot
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: nextRoot.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                throw FileOperationError.unsafeOperation(
                    "\(nextRoot.lastPathComponent) already exists and is not a folder"
                )
            }
            root = nextRoot
        }

        guard destinationRootIsContained(root, within: destination) else {
            throw FileOperationError.unsafeOperation("Resolved destination root escapes destination root")
        }
        if let firstSymbolicLink {
            throw FileOperationError.unsafeOperation(
                "\(firstSymbolicLink.lastPathComponent) is a symbolic link"
            )
        }
        return root
    }

    private static func containsTraversalComponent(_ component: String) -> Bool {
        var decoded = component
        var iterations = 0
        while let next = decoded.removingPercentEncoding,
              next != decoded,
              iterations < 5 {
            decoded = next
            iterations += 1
        }

        return decoded
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains { segment in
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed == "." || trimmed == ".."
            }
    }

    private static func destinationRootIsContained(_ root: URL, within destination: URL) -> Bool {
        let standardizedRoot = root.standardizedFileURL.path
        let standardizedDestination = destination.standardizedFileURL.path
        guard PathContainment.isStrictlyWithin(standardizedRoot, root: standardizedDestination) else {
            return false
        }

        let canonicalRoot = canonicalPathResolvingExistingPrefixes(root)
        let canonicalDestination = canonicalPathResolvingExistingPrefixes(destination)
        return PathContainment.isStrictlyWithin(canonicalRoot, root: canonicalDestination)
    }

    private static func canonicalPathResolvingExistingPrefixes(_ url: URL) -> String {
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)

        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            let candidate = resolved.appendingPathComponent(component)
            guard let linkDestination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: candidate.path
            ) else {
                resolved = candidate
                continue
            }

            let target: URL
            if linkDestination.hasPrefix("/") {
                target = URL(fileURLWithPath: linkDestination)
            } else {
                target = candidate.deletingLastPathComponent().appendingPathComponent(linkDestination)
            }
            resolved = target.standardizedFileURL.resolvingSymlinksKeepingCase()
        }

        return resolved.standardizedFileURL.path
    }

    public static func validateResolvedDestinationRoots(source: URL, destinations: [URL], settings: CameraLabelSettings) throws {
        let roots = try destinations.map {
            try resolvedDestinationRootChecked(source: source, destination: $0, settings: settings)
        }
        let rootPaths = roots.map { canonicalPath($0) }

        guard Set(rootPaths).count == rootPaths.count else {
            throw FileOperationError.unsafeOperation("Resolved destination folders must be unique")
        }

        for root in roots {
            if let issue = destinationSafetyIssue(source: source, destination: root) {
                throw FileOperationError.unsafeOperation("\(root.lastPathComponent): \(issue)")
            }

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw FileOperationError.unsafeOperation("\(root.lastPathComponent) already exists and is not a folder")
            }

            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw FileOperationError.unsafeOperation("\(root.lastPathComponent) is a symbolic link")
            }
        }

        for (index, path) in rootPaths.enumerated() {
            for (otherIndex, otherPath) in rootPaths.enumerated() where index != otherIndex {
                if PathContainment.isWithin(path, root: otherPath) {
                    throw FileOperationError.unsafeOperation("Resolved destination folders cannot be nested inside each other")
                }
            }
        }
    }

    public static func validateSourceTreeForCopy(source: URL) throws {
        try validatePortableRelativePaths(
            CardSource.enumerateTree(base: source).map(\.relativePath)
        )
    }

    public static func validatePortableRelativePaths(_ relativePaths: [String]) throws {
        let locale = Locale(identifier: "en_US_POSIX")
        var seen: [String: String] = [:]

        for relativePath in relativePaths {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
            if components.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) {
                throw FileOperationError.unsafeOperation("Source contains an unsafe relative path: \(relativePath)")
            }

            let portableKey = relativePath
                .precomposedStringWithCanonicalMapping
                .lowercased(with: locale)

            if let original = seen[portableKey], original != relativePath {
                throw FileOperationError.unsafeOperation(
                    "Source contains paths that collide on case-insensitive filesystems: \(original) and \(relativePath)"
                )
            }
            seen[portableKey] = relativePath
        }
    }

    // MARK: - Utility Functions

    private static func getAvailableSpace(at url: URL) -> Int64 {
        do {
            let resourceValues = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            return resolvedAvailableSpace(
                importantUsage: resourceValues.volumeAvailableCapacityForImportantUsage,
                standardCapacity: resourceValues.volumeAvailableCapacity
            )
        } catch {
            return 0
        }
    }

    /// `volumeAvailableCapacityForImportantUsage` is only meaningful on APFS. On exFAT/FAT
    /// (typical external SSDs and camera cards) macOS reports it as 0, not nil, so a
    /// non-positive value must fall back to the standard capacity.
    public static func resolvedAvailableSpace(
        importantUsage: Int64?,
        standardCapacity: Int?
    ) -> Int64 {
        if let importantUsage, importantUsage > 0 {
            return importantUsage
        }
        return Int64(standardCapacity ?? 0)
    }

    public static func checkedRequiredSpace(sourceBytes: Int64, headroomBytes: Int64) throws -> Int64 {
        guard sourceBytes >= 0, headroomBytes >= 0 else {
            throw FileOperationError.unsafeOperation("Source size exceeds the supported range")
        }
        let (requiredSpace, overflow) = sourceBytes.addingReportingOverflow(headroomBytes)
        guard !overflow else {
            throw FileOperationError.unsafeOperation("Source size exceeds the supported range")
        }
        return requiredSpace
    }

    /// Resolving symlinks strips a leading "/private" ("/private/etc" becomes
    /// "/etc"), so the resolved forms are listed too.
    private static let protectedSystemPrefixes: [String] = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/var", "/etc"
    ]

    /// On iPhone and iPad, everything the Files picker returns (On My iPad,
    /// iCloud Drive, external drives under LiveFiles) is the mobile user's
    /// storage below /private/var/mobile, not a system folder.
    private static let iOSUserStorageRoots: [String] = ["/var/mobile", "/private/var/mobile"]

    public static func isProtectedSystemPath(_ url: URL) -> Bool {
        let path = canonicalPath(url)
        let temporaryPath = canonicalPath(FileManager.default.temporaryDirectory)
        if PathContainment.isWithin(path, root: temporaryPath) {
            return false
        }
        #if os(iOS)
        if iOSUserStorageRoots.contains(where: { PathContainment.isWithin(path, root: $0) }) {
            return false
        }
        #endif
        return protectedSystemPrefixes.contains { path == $0 || PathContainment.isWithin(path, root: $0) }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksKeepingCase().path
    }
}

// MARK: - Error Types

public enum FileOperationError: LocalizedError, Equatable, Sendable {
    case operationAlreadyInProgress
    case sourceNotFound(String)
    case sourceNotDirectory(String)
    case destinationNotWritable(String)
    case unsafeOperation(String)
    case symlinkLoop(String)
    case insufficientSpace(String, available: Double, required: Double)

    public var errorDescription: String? {
        switch self {
        case .operationAlreadyInProgress:
            return "Another file operation is already active or cancelling."
        case .sourceNotFound(_):
            return "Source folder not found"
        case .sourceNotDirectory(_):
            return "Source is not a directory"
        case .destinationNotWritable(_):
            return "Cannot write to destination"
        case .unsafeOperation(let message):
            return "Unsafe operation: \(message)"
        case .symlinkLoop(_):
            return "Symlink loop detected"
        case .insufficientSpace(_, let available, let required):
            return "Insufficient space: \(String(format: "%.1f", available))GB available, \(String(format: "%.1f", required))GB required"
        }
    }
}
