import Foundation

/// What the user may choose as the source or a backup, checked the moment
/// they choose it (UI plan step 4.5, §4.3). The rules were the Mac's drop
/// validation; now the Files picker on iPad and iPhone runs them too, so a
/// bad pick is refused at once, with its reason, on every platform.
///
/// Backups, in order:
/// 1. Only a folder (not a file, not a macOS system folder).
/// 2. Not the same folder twice, compared by resolved path.
/// 3. Not the source, inside it, or containing it.
/// 4. Whatever `BackupTargetPolicy` refuses for a user's own pick.
///
/// The actual add still goes through `BackupTargetPolicy` (the caller's
/// `add`, which is `SharedAppCoordinator.addDestination` underneath), so
/// this rule can only refuse more, never let more in.
///
/// Source: only a folder, and not overlapping a chosen backup.
public enum DestinationSelectionPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case accept
        case reject(String)

        public var reason: String? {
            if case .reject(let reason) = self { return reason }
            return nil
        }
    }

    /// What a chosen location is on disk.
    public enum ItemKind: Equatable, Sendable {
        case folder
        case file
        /// Not there, or not visible to the app.
        case missing
    }

    public static let foldersOnlyReason = "Only folders can be used here"
    public static let systemFolderReason = "System directories cannot be used"

    // MARK: - Decisions

    /// Whether `url` may become a backup, given what is already chosen.
    /// `replacing` is the index of the backup a drop replaces; that backup
    /// does not count as a duplicate.
    public static func evaluateBackup(
        _ url: URL,
        source: URL?,
        existing: [URL],
        replacing: Int? = nil,
        kind: (URL) -> ItemKind = itemKind,
        isSystemFolder: (URL) -> Bool = isMacSystemFolder,
        backupRefusal: (URL, URL?) -> String? = userChoiceRefusal
    ) -> Decision {
        if let reason = folderRefusal(url, kind: kind, isSystemFolder: isSystemFolder) {
            return .reject(reason)
        }

        let others = existing.enumerated()
            .filter { $0.offset != replacing }
            .map(\.element)
        let path = resolvedPath(url)
        if others.contains(where: { resolvedPath($0) == path }) {
            return .reject("\(url.lastPathComponent) is already selected")
        }

        if let source, let issue = SafetyValidator.destinationSafetyIssue(source: source, destination: url) {
            return .reject(issue)
        }

        if let refusal = backupRefusal(url, source) {
            return .reject(refusal)
        }
        return .accept
    }

    /// Whether `url` may become the source, given the chosen backups.
    public static func evaluateSource(
        _ url: URL,
        backups: [URL],
        kind: (URL) -> ItemKind = itemKind,
        isSystemFolder: (URL) -> Bool = isMacSystemFolder
    ) -> Decision {
        if let reason = folderRefusal(url, kind: kind, isSystemFolder: isSystemFolder) {
            return .reject(reason)
        }
        if let conflict = backups.first(where: {
            SafetyValidator.destinationSafetyIssue(source: url, destination: $0) != nil
        }) {
            return .reject("Source conflicts with destination \(conflict.lastPathComponent)")
        }
        return .accept
    }

    // MARK: - Applying a pick

    /// Checks each picked or dropped folder in turn and hands the accepted
    /// ones to `add`, which must apply `BackupTargetPolicy` (the Mac's
    /// `MacVolumeAccessModel.addDestination`, or
    /// `SharedAppCoordinator.addDestination`). `existing` is read again
    /// before each one, so a batch with the same folder twice refuses the
    /// second. Returns every refusal, in order, to show the user.
    public static func addBackups(
        _ urls: [URL],
        source: URL?,
        existing: () -> [URL],
        kind: (URL) -> ItemKind = itemKind,
        isSystemFolder: (URL) -> Bool = isMacSystemFolder,
        backupRefusal: (URL, URL?) -> String? = userChoiceRefusal,
        add: (URL) -> String?
    ) -> [String] {
        var refusals: [String] = []
        for url in urls {
            let decision = evaluateBackup(
                url,
                source: source,
                existing: existing(),
                kind: kind,
                isSystemFolder: isSystemFolder,
                backupRefusal: backupRefusal
            )
            if let reason = decision.reason {
                refusals.append(reason)
            } else if let refusal = add(url) {
                refusals.append(refusal)
            }
        }
        return refusals
    }

    // MARK: - Defaults

    /// Reads the file system, holding a security scope for the check (a
    /// Files-picker folder on iOS is not visible without one).
    public static func itemKind(_ url: URL) -> ItemKind {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .folder : .file
    }

    /// macOS system folders (`SafetyValidator.isProtectedSystemPath`). Not
    /// applied on iOS: every Files location there lives under
    /// `/private/var/mobile`, which that rule would refuse.
    public static func isMacSystemFolder(_ url: URL) -> Bool {
        #if os(macOS)
        return SafetyValidator.isProtectedSystemPath(url)
        #else
        return false
        #endif
    }

    /// `BackupTargetPolicy` for a user's own pick, with real volume facts.
    public static func userChoiceRefusal(_ url: URL, source: URL?) -> String? {
        BackupTargetPolicy.refusal(for: url, origin: .userChoice, source: source)
    }

    // MARK: - Helpers

    private static func folderRefusal(
        _ url: URL,
        kind: (URL) -> ItemKind,
        isSystemFolder: (URL) -> Bool
    ) -> String? {
        if isSystemFolder(url) {
            return systemFolderReason
        }
        switch kind(url) {
        case .folder:
            return nil
        case .file:
            return foldersOnlyReason
        case .missing:
            return "\(url.lastPathComponent) cannot be opened"
        }
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksKeepingCase().path
    }
}
