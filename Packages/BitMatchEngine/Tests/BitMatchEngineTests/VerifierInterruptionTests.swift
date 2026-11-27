#if os(macOS)
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

final class VerifierInterruptionTests: XCTestCase {
    func testPipelinedVerifierFailureRetainsKnownSourceSize() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 20261127, fileCount: 1, bytesPerFile: 4096)
            defer { fixture.cleanup() }
            let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                pipelinedVerification: true,
                fanOutHooks: .init(beforeDestinationRead: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }))
            let rows = Mutex<[FileOperationResult]>([])
            _ = try await service.performFileOperation(sourceURL: fixture.source,
                destinationURLs: [fixture.destinations[0]], verificationMode: .standard,
                settings: CameraLabelSettings(), estimatedTotalBytes: nil,
                progressCallback: { _ in }, onFileResult: { row in rows.withLock { $0.append(row) } })
            let failure = rows.withLock { $0.last { $0.sourceURL.lastPathComponent == "MEDIA_0000.bin" && !$0.success } }
            XCTAssertEqual(failure?.fileSize, 4096)
        }
    }

    func testVerifierThrownCancellationPropagatesInBothExecutionPaths() async throws {
        try await FileOperationsTestLock.shared.run {
            for pipelined in [false, true] {
                for mode in [VerificationMode.standard, .thorough, .paranoid] {
                    let fixture = try DisposableTransferFixture(seed: 20261001, fileCount: 2, bytesPerFile: 4096)
                    defer { fixture.cleanup() }
                    let completed = Mutex(false)
                    let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                        pipelinedVerification: pipelined,
                        fanOutHooks: .init(beforeDestinationRead: { _, _ in throw CancellationError() }))
                    do {
                        _ = try await service.performFileOperation(sourceURL: fixture.source,
                            destinationURLs: fixture.destinations, verificationMode: mode,
                            settings: CameraLabelSettings(), estimatedTotalBytes: nil,
                            progressCallback: { if $0.currentStage == .completed { completed.withLock { $0 = true } } },
                            onFileResult: nil)
                        XCTFail("Verifier interruption returned an operation: \(mode), pipelined=\(pipelined)")
                    } catch is CancellationError { }
                    XCTAssertFalse(completed.withLock { $0 })
                    XCTAssertFalse(Task.isCancelled, "A verifier error must propagate without relying on parent cancellation")
                }
            }
        }
    }
}
#endif
