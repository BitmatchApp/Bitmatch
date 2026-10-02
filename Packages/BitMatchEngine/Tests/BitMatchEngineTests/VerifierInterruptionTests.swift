#if os(macOS)
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

final class VerifierInterruptionTests: XCTestCase {
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
