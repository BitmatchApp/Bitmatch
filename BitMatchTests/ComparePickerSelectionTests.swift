// ComparePickerSelectionTests.swift
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// Cancelling a compare-folder picker returns nil from the platform
/// service. That must preserve an existing selection, not clear it.
struct ComparePickerSelectionTests {

    @Test
    func testCancelLeftPickerPreservesExistingSelection() async throws {
        #if os(macOS)
        let fileSystem = FakeFileSystemService()
        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: PickerTestPlatformManager(fileSystem: fileSystem),
                defaults: .isolatedWorkflowDefaults()
            )
        }
        let existing = URL(fileURLWithPath: "/previously/left")
        await MainActor.run { coordinator.leftURL = existing }

        fileSystem.leftResult = nil
        await coordinator.selectLeftFolder()

        let actual = await MainActor.run { coordinator.leftURL }
        #expect(actual == existing)
        #else
        #expect(true)
        #endif
    }

    @Test
    func testCancelRightPickerPreservesExistingSelection() async throws {
        #if os(macOS)
        let fileSystem = FakeFileSystemService()
        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: PickerTestPlatformManager(fileSystem: fileSystem),
                defaults: .isolatedWorkflowDefaults()
            )
        }
        let existing = URL(fileURLWithPath: "/previously/right")
        await MainActor.run { coordinator.rightURL = existing }

        fileSystem.rightResult = nil
        await coordinator.selectRightFolder()

        let actual = await MainActor.run { coordinator.rightURL }
        #expect(actual == existing)
        #else
        #expect(true)
        #endif
    }

    @Test
    func testCancelSourcePickerPreservesExistingSelection() async throws {
        #if os(macOS)
        let fileSystem = FakeFileSystemService()
        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: PickerTestPlatformManager(fileSystem: fileSystem),
                defaults: .isolatedWorkflowDefaults()
            )
        }
        let existing = URL(fileURLWithPath: "/previously/source")
        await MainActor.run { coordinator.sourceURL = existing }

        fileSystem.sourceResult = nil
        await coordinator.selectSourceFolder()

        let actual = await MainActor.run { coordinator.sourceURL }
        #expect(actual == existing)
        #else
        #expect(true)
        #endif
    }

    @Test
    func testPickSourceFolderSetsSelection() async throws {
        #if os(macOS)
        let fileSystem = FakeFileSystemService()
        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: PickerTestPlatformManager(fileSystem: fileSystem),
                defaults: .isolatedWorkflowDefaults()
            )
        }
        let picked = URL(fileURLWithPath: "/picked/source")
        fileSystem.sourceResult = picked
        await coordinator.selectSourceFolder()

        let actual = await MainActor.run { coordinator.sourceURL }
        #expect(actual == picked)
        #else
        #expect(true)
        #endif
    }

    @Test
    func testPickLeftFolderSetsSelection() async throws {
        #if os(macOS)
        let fileSystem = FakeFileSystemService()
        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: PickerTestPlatformManager(fileSystem: fileSystem),
                defaults: .isolatedWorkflowDefaults()
            )
        }
        let picked = URL(fileURLWithPath: "/picked/left")
        fileSystem.leftResult = picked
        await coordinator.selectLeftFolder()

        let actual = await MainActor.run { coordinator.leftURL }
        #expect(actual == picked)
        #else
        #expect(true)
        #endif
    }
}

private final class PickerTestPlatformManager: PlatformManager {
    nonisolated let fileSystem: FileSystemService
    nonisolated let checksum: ChecksumService = PickerTestChecksumService()
    nonisolated let fileOperations: FileOperationsService = PickerTestFileOperationsService()
    nonisolated let cameraDetection: CameraDetectionService = PickerTestCameraDetectionService()
    nonisolated let supportsDragAndDrop = false

    init(fileSystem: FileSystemService) {
        self.fileSystem = fileSystem
    }

    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}

private final class PickerTestChecksumService: ChecksumService {
    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String { "" }
    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        VerificationResult(
            sourceChecksum: "hash",
            destinationChecksum: "hash",
            matches: true,
            checksumType: type,
            processingTime: 0,
            fileSize: 0
        )
    }
    func performByteComparison(
        sourceURL: URL,
        destinationURL: URL,
        progressCallback: ProgressCallback?
    ) async throws -> Bool { true }
}

private final class PickerTestFileOperationsService: FileOperationsService {
    func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        FileOperation(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            startTime: Date(),
            endTime: Date(),
            results: [],
            verificationMode: verificationMode,
            settings: settings,
            estimatedTotalBytes: estimatedTotalBytes
        )
    }
    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}

private final class PickerTestCameraDetectionService: CameraDetectionService {
    func detectCamera(from folderURL: URL) async -> CameraDetectionResult {
        CameraDetectionResult(
            cameraCard: nil,
            confidence: 0,
            metadata: [:],
            detectionMethod: "test",
            processingTime: 0
        )
    }
    func analyzeFolderStructure(at url: URL) async throws -> [String: Any] { [:] }
    func extractVideoMetadata(from fileURL: URL) async throws -> [String: Any] { [:] }
    func parseXMLMetadata(from fileURL: URL) async throws -> [String: Any] { [:] }
}
