import Foundation

/// Whether a copy may start, and why not: the one readiness rule on every
/// platform (UI plan step 4.5, §4.3). Pure: free space and writability are
/// injected, so it depends on no folder-info cache and no platform.
///
/// `SharedAppCoordinator.transferReadiness` builds it from the selection;
/// `OperationReadinessAssessment` (Start, ⌘R, the Setup screen) and
/// `TransferPlanPresentation` read it, so Mac, iPad and iPhone show the same
/// wording for the same selection.
///
/// Rules:
/// - A source, then a backup, must be chosen (`needsSource`,
///   `needsDestination`). Those are next steps, not blockers.
/// - Real findings block: duplicate backups, protected or unsafe backups
///   (`BackupTargetPolicy`, overlap with the source), resolved-folder
///   conflicts, a backup that exists but is not writable, and too little
///   free space. Every backup is checked for space, even one that already
///   has another finding.
/// - Space: a backup needs more than the source size plus
///   `requiredHeadroomBytes` free, exactly what the copy itself requires
///   (`SafetyValidator.validateAvailableSpace`), so "Ready" cannot fail at
///   start. A backup whose capacity cannot be read is left to the runtime.
/// - A source still being analysed waits (`analysing`), after any blocker.
/// - An analysed source with no files is blocked. A zero-byte file still
///   counts as a file and may be transferred.
/// - Warnings: Quick mode, and a source that needs more than 70% of a
///   backup's free space.
public struct TransferReadiness: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case needsSource
        case needsDestination
        case analysing
        case blocked
        case ready
    }

    public let status: Status
    /// Real findings, one wording for every platform.
    public let blockers: [String]
    public let warnings: [String]

    public var isReady: Bool { status == .ready }

    /// The runtime's margin, shared with the copy's own check.
    public static let requiredHeadroomBytes: Int64 = SafetyValidator.requiredHeadroomBytes

    public static let noSourceIssue = "No source folder selected"
    public static let noDestinationIssue = "No destination folders selected"
    public static let emptySourceIssue = "Source folder is empty"

    public static func assess(
        source: URL?,
        sourceFileCount: Int? = nil,
        sourceBytes: Int64?,
        isAnalysingSource: Bool,
        destinations: [URL],
        settings: CameraLabelSettings,
        verificationMode: VerificationMode,
        availableBytes: (URL) -> Int64?,
        isWritable: (URL) -> Bool
    ) -> TransferReadiness {
        guard let source else {
            return TransferReadiness(status: .needsSource, blockers: [], warnings: [])
        }

        var blockers: [String] = []
        var warnings: [String] = []

        if !isAnalysingSource, sourceFileCount == 0 {
            blockers.append(emptySourceIssue)
        }

        let uniqueDestinationPaths = Set(destinations.map { PathContainment.comparablePath($0.standardizedFileURL.resolvingSymlinksKeepingCase().path) })
        if uniqueDestinationPaths.count != destinations.count {
            blockers.append("Destination folders must be unique")
        }

        for destination in destinations {
            if SafetyValidator.isProtectedSystemPath(destination) {
                blockers.append("\(destination.lastPathComponent): System folders cannot be used as destinations")
            } else if let refusal = BackupTargetPolicy.refusal(for: destination, origin: .userChoice, source: source) {
                blockers.append(refusal)
            } else if let issue = SafetyValidator.destinationSafetyIssue(source: source, destination: destination) {
                blockers.append("\(destination.lastPathComponent): \(issue)")
            }
            // Checked alongside any finding above: the copy refuses an
            // unwritable backup too (`SafetyValidator.validateDestination`).
            if !isWritable(destination) {
                blockers.append("\(destination.lastPathComponent) is read-only. Choose a folder BitMatch can write to.")
            }
        }

        do {
            try SafetyValidator.validateResolvedDestinationRoots(
                source: source,
                destinations: destinations,
                settings: settings
            )
        } catch {
            blockers.append(error.localizedDescription)
        }

        if verificationMode == .quick {
            warnings.append("Quick mode only checks file size. Standard SHA-256 is safer for production transfers.")
        }

        if let sourceBytes {
            if let required = try? SafetyValidator.checkedRequiredSpace(sourceBytes: sourceBytes, headroomBytes: requiredHeadroomBytes) {
                for destination in destinations {
                    guard let available = availableBytes(destination) else { continue }
                    // The copy needs more than source + headroom free.
                    if available <= required {
                        blockers.append("Insufficient space on \(destination.lastPathComponent)")
                    } else if available > 0, Double(sourceBytes) / Double(available) > 0.7 {
                        warnings.append("Limited space on \(destination.lastPathComponent)")
                    }
                }
            } else {
                blockers.append("Source size exceeds the supported range")
            }
        }

        let status: Status
        if !blockers.isEmpty {
            status = .blocked
        } else if destinations.isEmpty {
            status = .needsDestination
        } else if isAnalysingSource {
            status = .analysing
        } else {
            status = .ready
        }
        return TransferReadiness(status: status, blockers: blockers, warnings: warnings)
    }

    /// Whether a backup folder can be written, as the copy will check it.
    /// A folder that cannot be seen (not there, or no access yet) counts as
    /// writable here and is left to the copy's own check, so the preflight
    /// never refuses what it cannot inspect. iOS holds a security scope for
    /// the check, as the copy does.
    public static func isWritableFolder(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return true
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    public init(status: Status, blockers: [String], warnings: [String]) {
        self.status = status
        self.blockers = blockers
        self.warnings = warnings
    }
}
