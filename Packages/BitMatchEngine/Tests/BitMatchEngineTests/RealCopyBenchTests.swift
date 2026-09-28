import XCTest
import Foundation
@testable import BitMatchEngine

/// Opt-in real-drive transfer benchmark. Not part of normal runs.
/// BITMATCH_REALBENCH=1 BITMATCH_REALBENCH_SRC=/path BITMATCH_REALBENCH_DESTS=/a:/b BITMATCH_REALBENCH_MODE=standard
final class RealCopyBenchTests: XCTestCase {
    func testRealCopy() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BITMATCH_REALBENCH"] == "1",
              let src = env["BITMATCH_REALBENCH_SRC"],
              let dests = env["BITMATCH_REALBENCH_DESTS"] else {
            throw XCTSkip("Set BITMATCH_REALBENCH=1 and paths to run.")
        }
        let mode: VerificationMode = env["BITMATCH_REALBENCH_MODE"] == "thorough" ? .thorough : .standard
        let destinationURLs = dests.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let start = ContinuousClock.now
        let operation = try await pipeline.performFileOperation(
            sourceURL: URL(fileURLWithPath: src, isDirectory: true),
            destinationURLs: destinationURLs,
            verificationMode: mode,
            settings: CameraLabelSettings(),
            progressCallback: { _ in },
            onFileResult: nil
        )
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let failures = operation.results.filter { !$0.success }.count
        print("REALBENCH mode=\(mode) dests=\(destinationURLs.count) rows=\(operation.results.count) failures=\(failures) seconds=\(String(format: "%.1f", seconds))")
        XCTAssertEqual(failures, 0)
    }
}
