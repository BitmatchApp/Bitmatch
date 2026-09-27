import Foundation
import XCTest
import BitMatchEngine
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatch

/// Promise 5, "one app everywhere": the same card transferred through the
/// shared engine produces the same per-file statuses and the same completion
/// verdict whichever platform manager drives it.
///
/// `IOSPlatformManager` and `IOSFileSystemService` import UIKit and cannot
/// load in this macOS test host. `IOSShapedPlatformManager` instead assembles
/// the engine the way `IOSPlatformManager` does (its own
/// `TransferPipeline` over its own file system), and
/// `IOSShapedFileSystem` mirrors `IOSFileSystemService`'s non-picker methods
/// without the security-scope calls. Physical iOS parity still needs a run in
/// the BitMatch-iPad test target.
@MainActor
final class PlatformVerdictParityTests: XCTestCase {
    func testMacAndIOSShapedManagersReachTheSameStatusesAndVerdict() async throws {
        try await FileOperationsTestLock.shared.run {
            let mac = try await runParityTransfer(platformManager: MacOSPlatformManager.shared)
            let iOSShapedManager = IOSShapedPlatformManager()
            let iOSShaped = try await runParityTransfer(platformManager: iOSShapedManager)

            XCTAssertEqual(mac.expectedRowCount, iOSShaped.expectedRowCount)
            XCTAssertEqual(mac.rows.count, mac.expectedRowCount, "Mac rows: \(mac.rows)")
            XCTAssertEqual(iOSShaped.rows, mac.rows)
            XCTAssertEqual(iOSShaped.completionSucceeded, mac.completionSucceeded)
            XCTAssertEqual(iOSShaped.verdict, mac.verdict)
            // Parity with a wrong answer is still wrong: a clean fixture must be green.
            XCTAssertEqual(mac.verdict, .success)
            // Step 4.7: the shared outcome screen shows the same thing for
            // both engines, and it is the green one. Destination IDs are the
            // run's temp paths, so backups compare by title and detail.
            XCTAssertEqual(iOSShaped.outcome.verdict, mac.outcome.verdict)
            XCTAssertEqual(iOSShaped.outcome.safetyState, mac.outcome.safetyState)
            XCTAssertEqual(iOSShaped.outcome.guidance, mac.outcome.guidance)
            XCTAssertEqual(iOSShaped.outcome.issueLines, mac.outcome.issueLines)
            XCTAssertEqual(iOSShaped.outcome.counts, mac.outcome.counts)
            XCTAssertEqual(iOSShaped.outcome.bytesVerified, mac.outcome.bytesVerified)
            XCTAssertEqual(iOSShaped.outcome.primaryAction, mac.outcome.primaryAction)
            XCTAssertEqual(iOSShaped.outcome.destinations.map { [$0.title, $0.detail] },
                           mac.outcome.destinations.map { [$0.title, $0.detail] })
            XCTAssertEqual(mac.outcome.safetyState, .safeToErase)
            XCTAssertTrue(mac.outcome.issueLines.isEmpty)
            XCTAssertEqual(iOSShapedManager.fakeFileSystem.totalActiveScopes, 0, "iOS-shaped scopes left open")
        }
    }
}

private struct ParityOutcome {
    let rows: [ParityRow]
    let expectedRowCount: Int
    let completionSucceeded: Bool?
    let verdict: CompletionVerdict
    let outcome: TransferOutcomePresentation
}

/// A result row with the run-specific parts (temp folder names, row IDs,
/// volume-derived destination labels) removed.
private struct ParityRow: Equatable, CustomStringConvertible {
    let sourcePath: String
    let destinationPath: String
    let status: String
    let size: Int64
    let checksum: String?

    var description: String { "\(destinationPath) [\(status)]" }
}

@MainActor
private func runParityTransfer(platformManager: PlatformManager) async throws -> ParityOutcome {
    let fixture = try DisposableTransferFixture(seed: 20_260_925, fileCount: 5, bytesPerFile: 32 * 1024)
    defer { fixture.cleanup() }
    let source = parityCanonicalDirectoryURL(fixture.source)
    let destinations = fixture.destinations.map(parityCanonicalDirectoryURL)
    let fixtureRoot = source.deletingLastPathComponent().path + "/"

    let errorService = ErrorReportingService()
    let executor = CopyVerifyExecutor(
        platformManager: platformManager,
        timingService: OperationTimingService(),
        errorService: errorService,
        stateService: OperationStateService(),
        backgroundTaskService: IOSBackgroundTaskService.shared
    )
    let config = CopyVerifyConfig(
        operationId: UUID(),
        sourceURL: source,
        destinationURLs: destinations,
        verificationMode: .standard,
        cameraLabelSettings: CameraLabelSettings(),
        reportSettings: ReportPrefs(makeReport: false),
        estimatedFiles: fixture.manifest.count,
        estimatedBytes: 0,
        currentMode: .copyAndVerify
    )

    var finalState: OperationState = .idle
    var authoritativeRows: [ResultRow] = []
    _ = try await executor.execute(
        config: config,
        callbacks: CopyVerifyCallbacks(
            onProgress: { _ in },
            onResult: { _ in },
            onStateChange: { finalState = $0 },
            onAuthoritativeResults: { authoritativeRows = $0 }
        )
    )

    let rows = authoritativeRows.map { row in
        ParityRow(
            sourcePath: parityRelativePath(row.path, under: source.path + "/"),
            destinationPath: parityRelativePath(row.destinationPath ?? "", under: fixtureRoot),
            status: row.status,
            size: row.size,
            checksum: row.checksum
        )
    }.sorted { $0.destinationPath < $1.destinationPath }

    var completionSucceeded: Bool?
    if case .completed(let info) = finalState {
        completionSucceeded = info.success
    }

    return ParityOutcome(
        rows: rows,
        expectedRowCount: fixture.manifest.count * destinations.count,
        completionSucceeded: completionSucceeded,
        verdict: CompletionVerdict.resolve(
            state: finalState,
            rows: authoritativeRows,
            // Same expressions as SharedAppCoordinator.hasErrors / hasCriticalErrors.
            hasErrors: !errorService.currentErrors.isEmpty,
            hasCriticalErrors: !errorService.getCriticalErrors().isEmpty
        ),
        // The same inputs `TransferOutcomePresentation.make(coordinator:)` reads.
        outcome: TransferOutcomePresentation.make(
            state: finalState,
            rows: authoritativeRows,
            destinations: destinations,
            hasErrors: !errorService.currentErrors.isEmpty,
            hasCriticalErrors: !errorService.getCriticalErrors().isEmpty,
            errorCount: errorService.currentErrors.filter { $0.category != .warning }.count,
            warningCount: errorService.currentErrors.filter { $0.category == .warning }.count,
            duration: nil,
            verificationMode: .standard,
            canRetry: false,
            canExport: true
        )
    )
}

private func parityRelativePath(_ path: String, under prefix: String) -> String {
    // The engine spells its roots through `standardizedFileURL`, which drops
    // a leading "/private" only when the path exists, while this test
    // canonicalizes with realpath: the same folder can arrive as "/var/..."
    // on one side and "/private/var/..." on the other. Compare with the
    // engine's alias-aware spelling so the check tests file identity, not
    // string identity.
    let comparable = ResultPathMatch.comparablePath(path)
    let comparablePrefix = ResultPathMatch.comparablePath(prefix)
    let rootedPrefix = comparablePrefix.hasSuffix("/") ? comparablePrefix : comparablePrefix + "/"
    guard comparable.hasPrefix(rootedPrefix) else { return comparable }
    return String(comparable.dropFirst(rootedPrefix.count))
}

private func parityCanonicalDirectoryURL(_ url: URL) -> URL {
    #if canImport(Darwin)
    guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    #else
    return url.resolvingSymlinksInPath().standardizedFileURL
    #endif
}

/// Composed the way `IOSPlatformManager` composes itself.
private final class IOSShapedPlatformManager: PlatformManager {
    let fakeFileSystem: IOSShapedFileSystem
    nonisolated let checksum: ChecksumService = ChecksumEngine.shared
    nonisolated let fileOperations: FileOperationsService
    nonisolated let cameraDetection: CameraDetectionService = SharedCameraDetectionService()
    nonisolated let supportsDragAndDrop = false

    nonisolated var fileSystem: FileSystemService { fakeFileSystem }

    init() {
        let fileSystem = IOSShapedFileSystem()
        fakeFileSystem = fileSystem
        fileOperations = TransferPipeline(
            fileSystem: fileSystem,
            checksum: ChecksumEngine.shared
        )
    }

    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}

/// `IOSFileSystemService`'s listing, sizing, directory creation, and free
/// space, minus security scopes (which the fake counts instead).
private final class IOSShapedFileSystem: FakeFileSystemService {
    override func getFileList(from folderURL: URL) async throws -> [URL] {
        try CardSource.enumerateRegularFiles(base: folderURL).map(\.url)
    }

    override nonisolated func getFileSize(for url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    override nonisolated func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    override nonisolated func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}
