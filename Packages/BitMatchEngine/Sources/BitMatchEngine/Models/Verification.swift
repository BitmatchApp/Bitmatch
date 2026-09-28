// Verification.swift - What BitMatch checks, and the errors and results it reports.
import Foundation

// MARK: - Checksum Algorithm
public enum ChecksumAlgorithm: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case sha256 = "SHA-256"
    case sha1 = "SHA-1"
    case md5 = "MD5"

    public var id: String { self.rawValue }

    public var description: String {
        switch self {
        case .sha256: return "SHA-256 (Recommended)"
        case .sha1: return "SHA-1"
        case .md5: return "MD5 (Legacy)"
        }
    }

    /// Security 9: MD5 and SHA-1 are cryptographically broken; kept only for MHL compatibility
    public var isDeprecated: Bool {
        switch self {
        case .sha256: return false
        case .sha1, .md5: return true
        }
    }
}

/// Digests produced together from one stable read of a file.  Destination
/// values are evidence only when `destinationReadIdentity` is also present:
/// that identity proves which pinned on-disk file supplied these bytes.
public struct VerifiedDigests: Codable, Equatable, Sendable {
    public let sha256: String?
    public let sha1: String?
    public let md5: String?

    public init(sha256: String? = nil, sha1: String? = nil, md5: String? = nil) {
        self.sha256 = sha256
        self.sha1 = sha1
        self.md5 = md5
    }

    public subscript(_ algorithm: ChecksumAlgorithm) -> String? {
        switch algorithm {
        case .sha256: return sha256
        case .sha1: return sha1
        case .md5: return md5
        }
    }
}

/// Descriptor identity captured before and after destination readback.
/// On filesystems with a real change time, ASC MHL may reuse readback digests
/// while identity, size, modification time, and change time still match. exFAT
/// does not provide that guarantee, so ASC MHL re-reads the destination there.
public struct VerifiedFileIdentity: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public let changeSeconds: Int64
    public let changeNanoseconds: Int64

    public init(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }
}

// MARK: - BitMatch Error Types
public enum BitMatchError: LocalizedError, Sendable {
    case fileAccessDenied(URL)
    case fileNotFound(URL)
    case checksumMismatch(String, String)
    case operationCancelled
    case insufficientStorage(Int64, Int64) // required, available
    case networkError(String)
    case unknownError(String)
    
    public var errorDescription: String? {
        switch self {
        case .fileAccessDenied(let url):
            return "Access denied to file: \(url.lastPathComponent)"
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch - Expected: \(expected), Got: \(actual)"
        case .operationCancelled:
            return "Operation was cancelled"
        case .insufficientStorage(let required, let available):
            let requiredText = required > 0 ? ByteCountFormatter().string(fromByteCount: required) : "Empty"
            let availableText = available > 0 ? ByteCountFormatter().string(fromByteCount: available) : "No space"
            return "Insufficient storage - Need: \(requiredText), Available: \(availableText)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .unknownError(let message):
            return "Unknown error: \(message)"
        }
    }
}

// MARK: - Verification Result
public struct VerificationResult: Codable, Sendable {
    public let sourceChecksum: String
    public let destinationChecksum: String
    public let matches: Bool
    public let checksumType: ChecksumAlgorithm
    public let processingTime: TimeInterval
    public let fileSize: Int64
    /// All source digests available from the stable copy read (or fallback).
    public let sourceDigests: VerifiedDigests?
    /// All digests computed together from the pinned destination readback.
    public let destinationDigests: VerifiedDigests?
    /// Identity of the pinned destination supplying `destinationDigests`.
    public let destinationReadIdentity: VerifiedFileIdentity?
    
    public var isValid: Bool { matches }
    
    public var description: String {
        if matches {
            return "✅ Files match - \(checksumType.rawValue) verified"
        } else {
            return "❌ Files differ - \(checksumType.rawValue) mismatch"
        }
    }

    public init(
        sourceChecksum: String,
        destinationChecksum: String,
        matches: Bool,
        checksumType: ChecksumAlgorithm,
        processingTime: TimeInterval,
        fileSize: Int64
    ) {
        self.init(
            sourceChecksum: sourceChecksum,
            destinationChecksum: destinationChecksum,
            matches: matches,
            checksumType: checksumType,
            processingTime: processingTime,
            fileSize: fileSize,
            sourceDigests: nil,
            destinationDigests: nil,
            destinationReadIdentity: nil
        )
    }

    init(
        sourceChecksum: String,
        destinationChecksum: String,
        matches: Bool,
        checksumType: ChecksumAlgorithm,
        processingTime: TimeInterval,
        fileSize: Int64,
        sourceDigests: VerifiedDigests?,
        destinationDigests: VerifiedDigests?,
        destinationReadIdentity: VerifiedFileIdentity?
    ) {
        self.sourceChecksum = sourceChecksum
        self.destinationChecksum = destinationChecksum
        self.matches = matches
        self.checksumType = checksumType
        self.processingTime = processingTime
        self.fileSize = fileSize
        self.sourceDigests = sourceDigests
        self.destinationDigests = destinationDigests
        self.destinationReadIdentity = destinationReadIdentity
    }

    // Readback evidence is intentionally run-local. Persisted or caller-made
    // results must fall back to reading the destination again before MHL.
    private enum CodingKeys: String, CodingKey {
        case sourceChecksum, destinationChecksum, matches, checksumType, processingTime, fileSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sourceChecksum: try container.decode(String.self, forKey: .sourceChecksum),
            destinationChecksum: try container.decode(String.self, forKey: .destinationChecksum),
            matches: try container.decode(Bool.self, forKey: .matches),
            checksumType: try container.decode(ChecksumAlgorithm.self, forKey: .checksumType),
            processingTime: try container.decode(TimeInterval.self, forKey: .processingTime),
            fileSize: try container.decode(Int64.self, forKey: .fileSize)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceChecksum, forKey: .sourceChecksum)
        try container.encode(destinationChecksum, forKey: .destinationChecksum)
        try container.encode(matches, forKey: .matches)
        try container.encode(checksumType, forKey: .checksumType)
        try container.encode(processingTime, forKey: .processingTime)
        try container.encode(fileSize, forKey: .fileSize)
    }
}

// MARK: - Verification Mode
public enum VerificationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case quick = "Quick"
    case standard = "Standard"
    case thorough = "Thorough" 
    case paranoid = "Paranoid"
    
    public var id: String { self.rawValue }
    
    public var description: String {
        switch self {
        case .quick: return "Quick checks file sizes only; file contents are not checksum-verified."
        case .standard: return "Standard reads the card once and checks every drive."
        case .thorough: return "Thorough also re-reads the card for verification."
        case .paranoid: return "Paranoid also compares every byte."
        }
    }
    
    public var requiresMHL: Bool {
        switch self {
        case .quick, .standard: return false
        case .thorough, .paranoid: return true
        }
    }
    
    public var useChecksum: Bool {
        switch self {
        case .quick: return false
        case .standard, .thorough, .paranoid: return true
        }
    }
    
    /// Checksums computed for this mode. Paranoid adds a byte-by-byte
    /// comparison on top of SHA-256; it does not add MD5 or SHA-1.
    public var checksumTypes: [ChecksumAlgorithm] {
        switch self {
        case .quick: return []
        case .standard: return [.sha256]
        case .thorough: return [.sha256, .md5]
        case .paranoid: return [.sha256]
        }
    }
}
