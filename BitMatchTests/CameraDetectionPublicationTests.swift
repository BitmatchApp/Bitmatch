import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// Shared camera detection publishes only the newest request. Comparing the
/// URL alone is not enough: choosing A, then B, then A again must not let
/// the first A detection publish over the later one.
@MainActor
struct CameraDetectionPublicationTests {
    @Test func olderDetectionOfTheSameURLNeverPublishes() async throws {
        let detection = GatedCameraDetection()
        let coordinator = SharedAppCoordinator(
            platformManager: GatedPlatformManager(cameraDetection: detection),
            defaults: .isolatedWorkflowDefaults()
        )
        let a = URL(fileURLWithPath: "/Volumes/CARD_A")
        let b = URL(fileURLWithPath: "/Volumes/CARD_B")

        coordinator.sourceURL = a
        #expect(await detection.waitForCalls(1))
        coordinator.sourceURL = b
        #expect(await detection.waitForCalls(2))
        coordinator.sourceURL = a
        #expect(await detection.waitForCalls(3))

        // The stale first-A result arrives first.
        detection.resume(call: 0, name: "STALE")
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.detectedCamera == nil)
        #expect(coordinator.cameraDetectionInProgress)

        detection.resume(call: 1, name: "B")
        detection.resume(call: 2, name: "LATEST")
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.detectedCamera?.name == "LATEST")
        #expect(!coordinator.cameraDetectionInProgress)
    }
}

private final class GatedCameraDetection: CameraDetectionService, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<String, Never>] = []

    func waitForCalls(_ count: Int, timeout: TimeInterval = 4) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let current = lock.withLock { continuations.count }
            if current >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func resume(call index: Int, name: String) {
        let continuation = lock.withLock { continuations[index] }
        continuation.resume(returning: name)
    }

    func detectCamera(from folderURL: URL) async -> CameraDetectionResult {
        let name = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            lock.withLock { continuations.append(continuation) }
        }
        return CameraDetectionResult(
            cameraCard: CameraCard(name: name, manufacturer: "Test", model: nil, fileCount: 0, totalSize: 0,
                                   detectionConfidence: 1, metadata: [:], volumeURL: folderURL,
                                   cameraType: .generic, mediaPath: folderURL),
            confidence: 1, metadata: [:], detectionMethod: "gated", processingTime: 0)
    }
    func analyzeFolderStructure(at url: URL) async throws -> [String: Any] { [:] }
    func extractVideoMetadata(from fileURL: URL) async throws -> [String: Any] { [:] }
    func parseXMLMetadata(from fileURL: URL) async throws -> [String: Any] { [:] }
}

private final class GatedPlatformManager: PlatformManager {
    nonisolated let fileSystem: FileSystemService = InertFileSystem()
    nonisolated let checksum: ChecksumService = InertChecksum()
    nonisolated let fileOperations: FileOperationsService = InertFileOperations()
    nonisolated let cameraDetection: CameraDetectionService
    nonisolated let supportsDragAndDrop = false
    init(cameraDetection: CameraDetectionService) { self.cameraDetection = cameraDetection }
    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}

private struct InertFileSystem: FileSystemService {
    func selectSourceFolder() async -> URL? { nil }
    func selectDestinationFolders() async -> [URL] { [] }
    func selectLeftFolder() async -> URL? { nil }
    func selectRightFolder() async -> URL? { nil }
    func validateFileAccess(url: URL) async -> Bool { true }
    func startAccessing(url: URL) -> Bool { false }
    func stopAccessing(url: URL) {}
    func getFileList(from folderURL: URL) async throws -> [URL] { [] }
    nonisolated func getFileSize(for url: URL) throws -> Int64 { 0 }
    nonisolated func createDirectory(at url: URL) throws {}
    nonisolated func freeSpace(at url: URL) -> Int64 { 0 }
}

private final class InertChecksum: ChecksumService {
    func generateChecksum(for fileURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> String { "" }
    func verifyFileIntegrity(sourceURL: URL, destinationURL: URL, type: ChecksumAlgorithm, progressCallback: ProgressCallback?) async throws -> VerificationResult {
        VerificationResult(sourceChecksum: "h", destinationChecksum: "h", matches: true, checksumType: type, processingTime: 0, fileSize: 0)
    }
    func performByteComparison(sourceURL: URL, destinationURL: URL, progressCallback: ProgressCallback?) async throws -> Bool { true }
}

private final class InertFileOperations: FileOperationsService {
    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode, settings: CameraLabelSettings,
                              estimatedTotalBytes: Int64?, progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?) async throws -> FileOperation {
        FileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs, startTime: Date(), endTime: Date(), results: [],
                      verificationMode: verificationMode, settings: settings, estimatedTotalBytes: estimatedTotalBytes)
    }
    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}
