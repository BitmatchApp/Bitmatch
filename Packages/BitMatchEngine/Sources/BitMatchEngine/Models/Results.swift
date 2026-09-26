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
    case checksumMismatch
    case failed

    public var statusText: String {
        switch self {
        case .verified: "✅ Verified"
        case .copiedUnverified: "✅ Copied"
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

// MARK: - Result Row
public struct ResultRow: Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let status: String
    public let size: Int64
    public let checksum: String?
    public let destination: String?
    public let destinationPath: String?
    
    public init(id: UUID = UUID(),
         path: String,
         status: String,
         size: Int64,
         checksum: String?,
         destination: String?,
         destinationPath: String? = nil) {
        self.id = id
        self.path = path
        self.status = status
        self.size = size
        self.checksum = checksum
        self.destination = destination
        self.destinationPath = destinationPath
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
    public var notes: String = ""
    public var makeReport: Bool = true
    public var verifyWithChecksum: Bool = true
    public var enableAutoCameraDetection: Bool = true
    public var autoPopulateSource: Bool = false
    public var showCameraDetectionNotifications: Bool = true
    public var checksumAlgorithm: ChecksumAlgorithm = .sha256

    public init(verificationMode: VerificationMode? = nil, includeThumbnails: Bool = false, clientName: String = "", projectName: String = "", production: String = "", company: String = "", notes: String = "", makeReport: Bool = true, verifyWithChecksum: Bool = true, enableAutoCameraDetection: Bool = true, autoPopulateSource: Bool = false, showCameraDetectionNotifications: Bool = true, checksumAlgorithm: ChecksumAlgorithm = .sha256) {
        self.verificationMode = verificationMode
        self.includeThumbnails = includeThumbnails
        self.clientName = clientName
        self.projectName = projectName
        self.production = production
        self.company = company
        self.notes = notes
        self.makeReport = makeReport
        self.verifyWithChecksum = verifyWithChecksum
        self.enableAutoCameraDetection = enableAutoCameraDetection
        self.autoPopulateSource = autoPopulateSource
        self.showCameraDetectionNotifications = showCameraDetectionNotifications
        self.checksumAlgorithm = checksumAlgorithm
    }
}

extension ResultRow: Codable {
    public enum CodingKeys: String, CodingKey, Sendable {
        case id, path, status, size, checksum, destination, destinationPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let path = try container.decode(String.self, forKey: .path)
        let status = try container.decode(String.self, forKey: .status)
        let size = try container.decode(Int64.self, forKey: .size)
        let checksum = try container.decodeIfPresent(String.self, forKey: .checksum)
        let destination = try container.decodeIfPresent(String.self, forKey: .destination)
        let destinationPath = try container.decodeIfPresent(String.self, forKey: .destinationPath)

        self.init(id: id, path: path, status: status, size: size, checksum: checksum, destination: destination, destinationPath: destinationPath)
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
    }
}
