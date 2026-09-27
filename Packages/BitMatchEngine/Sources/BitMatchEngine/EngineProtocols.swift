// EngineProtocols.swift - What the engine needs from the platform, and what it returns.
import Foundation

// MARK: - File Access (engine)

/// What the engine needs from the file system: access scopes, listing,
/// sizes, directory creation and free space. No pickers.
public protocol FileAccess: Sendable {
    func validateFileAccess(url: URL) async -> Bool
    func startAccessing(url: URL) -> Bool
    func stopAccessing(url: URL)
    func getFileList(from folderURL: URL) async throws -> [URL]
    // NOTE: copyFile removed - all copying now goes through DestinationWriter.copyAllSafely()
    // which provides atomic writes, resume support, and streaming enumeration
    nonisolated func getFileSize(for url: URL) throws -> Int64
    nonisolated func createDirectory(at url: URL) throws
    nonisolated func freeSpace(at url: URL) -> Int64
}

// MARK: - Checksum Service Protocol
public protocol ChecksumService: Sendable {
    typealias ProgressCallback = @Sendable (Double, String?) -> Void
    
    func generateChecksum(for fileURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> String
    func verifyFileIntegrity(sourceURL: URL, destinationURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> VerificationResult
    func performByteComparison(sourceURL: URL, destinationURL: URL, progressCallback: ProgressCallback?) async throws -> Bool
}

// MARK: - File Operations Service Protocol
public protocol FileOperationsService: Sendable {
    typealias ProgressCallback = @Sendable (OperationProgress) -> Void
    typealias FileResultCallback = @Sendable (FileOperationResult) async -> Void
    
    func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL], 
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation
    
    func cancelOperation()
    func pauseOperation() async
    func resumeOperation() async
}

// MARK: - Shared Result Types

public struct FileOperation: Sendable {
    public let id = UUID()
    public let sourceURL: URL
    public let destinationURLs: [URL]
    public let startTime: Date
    public var endTime: Date?
    public let results: [FileOperationResult]
    /// The fail-closed source manifest used by this run. Completion is never
    /// successful when this authoritative coverage is unavailable.
    public let sourceManifest: [URL]?
    /// Canonical path/size/modification-date fingerprint of the manifest.
    public let sourceFingerprint: String?
    public let verificationMode: VerificationMode
    public let settings: CameraLabelSettings
    public let estimatedTotalBytes: Int64? // For improved ETA calculation
    
    public var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    public init(sourceURL: URL, destinationURLs: [URL], startTime: Date, endTime: Date?, results: [FileOperationResult], sourceManifest: [URL]? = nil, sourceFingerprint: String? = nil, verificationMode: VerificationMode, settings: CameraLabelSettings, estimatedTotalBytes: Int64?) {
        self.sourceURL = sourceURL
        self.destinationURLs = destinationURLs
        self.startTime = startTime
        self.endTime = endTime
        self.results = results
        self.sourceManifest = sourceManifest
        self.sourceFingerprint = sourceFingerprint
        self.verificationMode = verificationMode
        self.settings = settings
        self.estimatedTotalBytes = estimatedTotalBytes
    }
}

public struct FileOperationResult: Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let success: Bool
    public let error: Error?
    public let fileSize: Int64
    public let verificationResult: VerificationResult?
    public let processingTime: TimeInterval
    /// Advisory only. A verified copy remains verified when its source clip
    /// appears incomplete, because the destination still matches the card.
    public let clipIntegrity: ClipIntegrityFinding?
    
    public var outcome: ResultOutcome {
        if let verification = verificationResult {
            return verification.isValid ? .verified : .checksumMismatch
        }
        return success ? .copiedUnverified : .failed
    }

    public var statusDescription: String { outcome.statusText }

    public init(sourceURL: URL, destinationURL: URL, success: Bool, error: Error?, fileSize: Int64, verificationResult: VerificationResult?, processingTime: TimeInterval, clipIntegrity: ClipIntegrityFinding? = nil) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.success = success
        self.error = error
        self.fileSize = fileSize
        self.verificationResult = verificationResult
        self.processingTime = processingTime
        self.clipIntegrity = clipIntegrity
    }
}
