// Results.swift - One row per file per backup, and how it ended.
import Foundation

/// How one file on one backup ended. The engine writes `statusText` into
/// `ResultRow.status`, and `ResultRow.isSuccessStatus` reads it back through
/// `init(statusText:)`, so the text and the rule that judges it cannot drift.
public enum ResultOutcome: CaseIterable, Equatable, Sendable {
    /// Copied and confirmed by checksum or byte comparison.
    case verified
    /// Copied without verification (Quick mode). A success, never "verified".
    case copiedUnverified
    /// Intentionally omitted by the reviewed selection; never a success.
    case excludedAppleDouble
    /// A Finder view file (`.DS_Store`) the classifier proved holds only
    /// window and icon layout, skipped by the user's setting; never a success.
    case skippedFinderMetadata
    case checksumMismatch
    case failed

    public var statusText: String {
        switch self {
        case .verified: "✅ Verified"
        case .copiedUnverified: "✅ Copied"
        case .excludedAppleDouble: "⏭ Excluded AppleDouble (selected by user)"
        case .skippedFinderMetadata: "⏭ Skipped Finder view file (.DS_Store)"
        case .checksumMismatch: "⚠️ Checksum Mismatch"
        case .failed: "❌ Failed"
        }
    }

    public var isSuccess: Bool { self == .verified || self == .copiedUnverified }
    public var isVerified: Bool { self == .verified }

    public init?(statusText: String) {
        guard let match = Self.allCases.first(where: { $0.statusText == statusText }) else { return nil }
        self = match
    }
}

// MARK: - Failure Reason
/// Why a copy or verification failed, bounded to tokens the app can word.
public enum ResultFailureReason: String, Sendable, CaseIterable {
    case outOfSpace
    case companionConflict
    case sourceUnstable
    case sourceReadFailed
    /// The attempt never read the card: it was not connected when the
    /// queue reached it.
    case sourceNotConnected
    /// The attempt never started: a backup was refused by policy.
    case backupRefused
    /// The card holds an entry BitMatch does not copy: a symbolic link,
    /// named pipe, socket, device or whiteout. Never opened or followed.
    case unsupportedSourceEntry
    /// The backup's file had a different identity (inode, size,
    /// modification or change time) at the end of the run than when BitMatch checked it: something
    /// else wrote to it, for example Finder saving a `.DS_Store`.
    case destinationChangedAfterCheck
    /// The backup's file was gone at the end of the run, after BitMatch had checked it.
    case destinationMissingAfterCheck
    /// The backup's file had a different size at the end of the run than when BitMatch checked it.
    case destinationSizeChangedAfterCheck
    /// A different file already sat at the final name on the backup; BitMatch
    /// never overwrites it. (`._*` names use `companionConflict`.)
    case existingDestinationConflict
    /// A file of the same size already sat at the final name on the backup,
    /// and its bytes or checksum differ from what BitMatch read from the
    /// card. Either something rewrote the backup or the card returned
    /// different bytes; nothing tells which, so the card is not proven
    /// (`leavesCardUnproven`).
    case existingDestinationContentDiffers
    /// The end-of-run checks of a backup could not be completed: its files
    /// could not be listed, its folder moved, its transfer status could not be
    /// saved, or a fresh empty-file proof failed.
    case destinationCheckFailed
    case destinationReadbackFailed
    /// NSError userInfo key the writer sets on the errors it classifies.
    public static let userInfoKey = "BitMatchFailureReason"

    public var rowNote: String {
        switch self {
        case .outOfSpace: "backup out of space"
        case .companionConflict: "the backup keeps its own hidden companion file"
        case .sourceUnstable: "the card changed or could not be read consistently"
        case .sourceReadFailed: "the card could not be read"
        case .sourceNotConnected: "the card was not connected"
        case .backupRefused: "a backup was refused before copying started"
        case .unsupportedSourceEntry: "the card holds an item BitMatch does not copy (a link, pipe, socket or device)"
        case .destinationChangedAfterCheck: "the backup's copy changed after BitMatch checked it; something else wrote to it, for example Finder"
        case .destinationMissingAfterCheck: "the backup's copy was gone when BitMatch checked it again"
        case .destinationSizeChangedAfterCheck: "the backup's copy changed size after BitMatch checked it"
        case .existingDestinationConflict: "a different file was already at that name on the backup; it was not overwritten"
        case .existingDestinationContentDiffers: "a file already at that name on the backup has different contents; it was not overwritten, and the card is not proven"
        case .destinationCheckFailed: "the backup could not be checked at the end of the run"
        case .destinationReadbackFailed: "the backup file could not be read during verification"
        }
    }

    /// Reasons that say something went wrong reading the card itself.
    public var isSourceFault: Bool { self == .sourceUnstable || self == .sourceReadFailed }

    /// A classified failure that still says nothing reliable about the
    /// card. Retry lineage treats it like an unexplained failure, so a later
    /// verified attempt cannot make the card safe to erase on its strength.
    public var leavesCardUnproven: Bool { self == .existingDestinationContentDiffers }
}

// MARK: - Result Row
public struct ResultRow: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let status: String
    public let size: Int64
    public let checksum: String?
    public let destination: String?
    public let destinationPath: String?
    public let clipIntegrity: ClipIntegrityFinding?
    public let wasReused: Bool
    /// Failed-readback marking outcome for this row, when marking applied:
    /// `marked`, `nameOccupied`, `fileChanged`, `fileMissing`, `nameTooLong`
    /// or `swapped`. Nil when no marking was attempted.
    public let failedOutputMarking: String?
    /// One-time re-copy outcome after a failed readback (`recovered` or
    /// `stillFailed`); nil when no re-copy ran.
    public let recopyOutcome: String?
    /// Canonical `ResultFailureReason` token for a failed file, when the
    /// engine could classify the failure; nil otherwise. Never error text.
    public let failureReason: String?
    /// Specific error context recorded at the failing phase.
    public let failureDetail: String?
    /// The readback checksum this file had on this backup before an
    /// end-of-run check failed it (it changed, vanished or changed size after
    /// it verified). Evidence of what was verified, never a verified checksum:
    /// `checksum` stays nil on such a row. Nil on every other row.
    public let recordedChecksumBeforeFailure: String?

    public init(id: UUID = UUID(),
         path: String,
         status: String,
         size: Int64,
         checksum: String?,
         destination: String?,
         destinationPath: String? = nil,
         clipIntegrity: ClipIntegrityFinding? = nil,
         wasReused: Bool = false,
         failedOutputMarking: String? = nil,
         recopyOutcome: String? = nil,
         failureReason: String? = nil,
         failureDetail: String? = nil,
         recordedChecksumBeforeFailure: String? = nil) {
        self.id = id
        self.path = path
        self.status = status
        self.size = size
        self.checksum = checksum
        self.destination = destination
        self.destinationPath = destinationPath
        self.clipIntegrity = clipIntegrity
        self.wasReused = wasReused
        self.failedOutputMarking = failedOutputMarking
        self.recopyOutcome = recopyOutcome
        self.failureReason = failureReason
        self.failureDetail = failureDetail
        self.recordedChecksumBeforeFailure = recordedChecksumBeforeFailure
    }

    /// Canonical History/report suffix for the marking outcome, shared by
    /// every surface so the words cannot drift.
    public var markingNote: String? {
        switch failedOutputMarking {
        case "marked": "failed file renamed with .bitmatch-failed suffix"
        case "nameOccupied": "failed file could not be renamed (marked name already in use), still at original name"
        case "fileChanged": "failed file could not be renamed (file changed after checking), still at original name"
        case "fileMissing": "failed file could not be renamed (file no longer there)"
        case "nameTooLong": "failed file could not be renamed (marked name too long), still at original name"
        case "swapped": "failed file could not be renamed (file changed during renaming), still at original name"
        case "swappedNotRestored": "failed file was moved to the .bitmatch-failed name after changing during renaming; check that file before trusting it"
        case nil: nil
        default: "failed file could not be renamed, still at original name"
        }
    }

    public var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    public var formattedSize: String {
        guard size > 0 else { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var isSuccessStatus: Bool {
        Self.isSuccessStatus(status)
    }

    /// A card entry BitMatch does not copy (link, pipe, socket, device). It
    /// is a failure for the verdict, and it is not a selected file.
    public var isUnsupportedSourceEntry: Bool {
        failureReason == ResultFailureReason.unsupportedSourceEntry.rawValue
    }

    /// A Finder view file (`.DS_Store`) skipped by the user's setting. Not a
    /// success, not a failure, and not a selected file.
    public var isSkippedFinderMetadata: Bool {
        ResultOutcome(statusText: status) == .skippedFinderMetadata
    }

    /// Rows the saved selected-file plan counts: not a reviewed AppleDouble
    /// exclusion, not a skipped Finder view file and not an entry that could
    /// never be copied. All stay in History as evidence; none makes a
    /// complete plan look long or short.
    public var isInSelectedPlan: Bool {
        !isOmittedBySelection && !isUnsupportedSourceEntry
    }

    /// A file BitMatch deliberately did not copy: a reviewed AppleDouble
    /// exclusion or a skipped Finder view file. Neither is listed in a
    /// checksum manifest; an unproven skip can count as an issue. Not a success either: the
    /// verdict decides what each means (an exclusion is never safe to erase;
    /// a skip only when `TransferCompletion.finderMetadataSkipsProven`).
    public var isOmittedBySelection: Bool {
        ResultOutcome(statusText: status) == .excludedAppleDouble || isSkippedFinderMetadata
    }

    /// Single source of truth for whether a result row represents a verified
    /// success. Fail-safe: a status must positively signal success ("✅") and
    /// carry no failure marker; anything unrecognized counts as an issue.
    /// Substring checks like `lowercased().contains("match")` are forbidden
    /// here — "Checksum Mismatch" contains "match".
    public static func isSuccessStatus(_ status: String) -> Bool {
        if let outcome = ResultOutcome(statusText: status) {
            return outcome.isSuccess
        }
        // Older wording (saved history, compare descriptions): fail-safe rule.
        guard status.contains("✅") else { return false }
        let lowercased = status.lowercased()
        let failureMarkers = ["❌", "⚠️", "mismatch", "fail", "error", "missing"]
        return !failureMarkers.contains { lowercased.contains($0) }
    }

    public var isVerifiedStatus: Bool {
        Self.isVerifiedStatus(status)
    }

    /// Whether a row counts as verified, not just copied (Promise 2): only
    /// `.verified`, or older text that is a success and says "verified" or
    /// "match" without "unverified" / "not verified".
    public static func isVerifiedStatus(_ status: String) -> Bool {
        guard isSuccessStatus(status) else { return false }
        if let outcome = ResultOutcome(statusText: status) {
            return outcome.isVerified
        }
        let lowercased = status.lowercased()
        let saysVerified = lowercased.contains("verified") || lowercased.contains("match")
        let deniesVerified = lowercased.contains("unverified") || lowercased.contains("not verified")
        return saysVerified && !deniesVerified
    }
}

// MARK: - Report Preferences  
public struct ReportPrefs: Codable, Sendable {
    /// Actual copy mode; nil preserves legacy folder-comparison preferences.
    public var verificationMode: VerificationMode? = nil
    public var includeThumbnails: Bool = false
    public var clientName: String = ""
    public var projectName: String = ""
    public var production: String = ""
    public var company: String = ""
    public var operatorName: String = ""
    public var notes: String = ""
    public var makeReport: Bool = true
    public var verifyWithChecksum: Bool = true
    public var enableAutoCameraDetection: Bool = true
    public var autoPopulateSource: Bool = true
    public var showCameraDetectionNotifications: Bool = true
    public var checksumAlgorithm: ChecksumAlgorithm = .sha256
    /// Run-only, like the per-run `verificationMode`: the run's Skip Finder
    /// view files setting, for the report's verification scope. Not in
    /// `CodingKeys`, so saved preferences never carry it.
    public var skipFinderViewFiles: Bool? = nil

    public init(verificationMode: VerificationMode? = nil, includeThumbnails: Bool = false, clientName: String = "", projectName: String = "", production: String = "", company: String = "", notes: String = "", makeReport: Bool = true, verifyWithChecksum: Bool = true, enableAutoCameraDetection: Bool = true, autoPopulateSource: Bool = true, showCameraDetectionNotifications: Bool = true, checksumAlgorithm: ChecksumAlgorithm = .sha256, operatorName: String = "") {
        self.verificationMode = verificationMode
        self.includeThumbnails = includeThumbnails
        self.clientName = clientName
        self.projectName = projectName
        self.production = production
        self.company = company
        self.operatorName = operatorName
        self.notes = notes
        self.makeReport = makeReport
        self.verifyWithChecksum = verifyWithChecksum
        self.enableAutoCameraDetection = enableAutoCameraDetection
        self.autoPopulateSource = autoPopulateSource
        self.showCameraDetectionNotifications = showCameraDetectionNotifications
        self.checksumAlgorithm = checksumAlgorithm
    }

    private enum CodingKeys: String, CodingKey {
        case verificationMode, includeThumbnails, clientName, projectName, production, company
        case operatorName, notes, makeReport, verifyWithChecksum, enableAutoCameraDetection
        case autoPopulateSource, showCameraDetectionNotifications, checksumAlgorithm
    }

    /// New optional fields must not discard settings or queued records from older builds.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            verificationMode: try c.decodeIfPresent(VerificationMode.self, forKey: .verificationMode),
            includeThumbnails: try c.decodeIfPresent(Bool.self, forKey: .includeThumbnails) ?? false,
            clientName: try c.decodeIfPresent(String.self, forKey: .clientName) ?? "",
            projectName: try c.decodeIfPresent(String.self, forKey: .projectName) ?? "",
            production: try c.decodeIfPresent(String.self, forKey: .production) ?? "",
            company: try c.decodeIfPresent(String.self, forKey: .company) ?? "",
            notes: try c.decodeIfPresent(String.self, forKey: .notes) ?? "",
            makeReport: try c.decodeIfPresent(Bool.self, forKey: .makeReport) ?? true,
            verifyWithChecksum: try c.decodeIfPresent(Bool.self, forKey: .verifyWithChecksum) ?? true,
            enableAutoCameraDetection: try c.decodeIfPresent(Bool.self, forKey: .enableAutoCameraDetection) ?? true,
            autoPopulateSource: try c.decodeIfPresent(Bool.self, forKey: .autoPopulateSource) ?? true,
            showCameraDetectionNotifications: try c.decodeIfPresent(Bool.self, forKey: .showCameraDetectionNotifications) ?? true,
            checksumAlgorithm: try c.decodeIfPresent(ChecksumAlgorithm.self, forKey: .checksumAlgorithm) ?? .sha256,
            operatorName: try c.decodeIfPresent(String.self, forKey: .operatorName) ?? ""
        )
    }
}

extension ResultRow: Codable {
    public enum CodingKeys: String, CodingKey, Sendable {
        case id, path, status, size, checksum, destination, destinationPath, clipIntegrity, wasReused, failedOutputMarking, recopyOutcome, failureReason, failureDetail, recordedChecksumBeforeFailure
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id: UUID
        if let savedID = try container.decodeIfPresent(UUID.self, forKey: .id) {
            id = savedID
        } else {
            id = UUID()
            // A journal must persist newly assigned identities once, so later
            // launches, retries and exports keep referring to the same rows.
            (decoder.userInfo[JournalDecodingMigrations.userInfoKey] as? JournalDecodingMigrations)?
                .recordGeneratedResultID()
        }
        let path = try container.decode(String.self, forKey: .path)
        let status = try container.decode(String.self, forKey: .status)
        let size = try container.decode(Int64.self, forKey: .size)
        let checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
        let destination = try container.decodeIfPresent(String.self, forKey: .destination)
        let destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath)
        let clipIntegrity = try container.decodeIfPresent(ClipIntegrityFinding.self, forKey: .clipIntegrity)
        let wasReused = try container.decodeIfPresent(Bool.self, forKey: .wasReused) ?? false
        let failedOutputMarking = try container.decodeIfPresent(String.self, forKey: .failedOutputMarking)
        let recopyOutcome = try container.decodeIfPresent(String.self, forKey: .recopyOutcome)
        let failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        let failureDetail = try container.decodeIfPresent(String.self, forKey: .failureDetail)
        let recordedChecksumBeforeFailure = try container.decodeIfPresent(String.self, forKey: .recordedChecksumBeforeFailure)

        self.init(id: id, path: path, status: status, size: size, checksum: checksum, destination: destination, destinationPath: destinationPath, clipIntegrity: clipIntegrity, wasReused: wasReused, failedOutputMarking: failedOutputMarking, recopyOutcome: recopyOutcome, failureReason: failureReason, failureDetail: failureDetail, recordedChecksumBeforeFailure: recordedChecksumBeforeFailure)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(status, forKey: .status)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(checksum, forKey: .checksum)
        try container.encodeIfPresent(destination, forKey: .destination)
        try container.encodeIfPresent(destinationPath, forKey: .destinationPath)
        try container.encodeIfPresent(clipIntegrity, forKey: .clipIntegrity)
        if wasReused { try container.encode(true, forKey: .wasReused) }
        try container.encodeIfPresent(failedOutputMarking, forKey: .failedOutputMarking)
        try container.encodeIfPresent(recopyOutcome, forKey: .recopyOutcome)
        try container.encodeIfPresent(failureReason, forKey: .failureReason)
        try container.encodeIfPresent(failureDetail, forKey: .failureDetail)
        try container.encodeIfPresent(recordedChecksumBeforeFailure, forKey: .recordedChecksumBeforeFailure)
    }
}
