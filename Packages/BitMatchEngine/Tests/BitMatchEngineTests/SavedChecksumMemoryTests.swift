import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

final class SavedChecksumMemoryTests: XCTestCase {
    /// Opt-in footprint test for the XXH64 branch of Check. Other checksum
    /// algorithms use ChecksumEngine, whose read loops have their own pools.
    /// Plant: the XXH64 pass retained nearly a whole large file's read buffers.
    func testXXH64CheckKeepsMemoryBounded() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_CHECK_MEMORY_TEST"] == "1" else {
            throw XCTSkip("Set BITMATCH_CHECK_MEMORY_TEST=1 for the isolated footprint test")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-xxh64-memory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let media = root.appendingPathComponent("clip.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: media.path, contents: nil))
        let size = UInt64(512 * 1_024 * 1_024)
        let writer = try FileHandle(forWritingTo: media)
        try writer.truncate(atOffset: size)
        try writer.close()

        // Parsed-evidence construction enters the real Check hashing path;
        // evidence parsing and XXH64 interoperability are covered elsewhere.
        let record = SavedChecksumCheck.Record(
            url: root.appendingPathComponent("ascmhl/reference.mhl"), date: Date(), kind: .ascMHL)
        let expected = SavedChecksumCheck.ExpectedFile(
            relativePath: "clip.bin", checksum: "0000000000000000", algorithm: .xxh64, record: record)
        let discovery = SavedChecksumCheck.Discovery(
            root: root, expectedFiles: ["clip.bin": expected], records: [record])
        let sampler = CheckFootprintSamples()
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let result = try await checker.check(discovery) { update in
            sampler.observe(update)
        }

        XCTAssertEqual(result.changedPaths, ["clip.bin"])
        let measured = sampler.snapshot()
        XCTAssertGreaterThan(measured.initial, 0)
        XCTAssertGreaterThan(measured.completed, 0)
        XCTAssertLessThan(measured.completed - measured.initial, 128,
                          "XXH64 Check grew by \(measured.completed - measured.initial) MiB for a 512 MiB file")
        print("XXH64 Check memory initialMiB=\(measured.initial) completedMiB=\(measured.completed) sizeMiB=512")
    }
}

private final class CheckFootprintSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var initial = 0
    private var completed = 0

    func observe(_ update: OperationProgress) {
        let footprint = TransferDiagnosticStore.physicalFootprintMB() ?? 0
        lock.withLock {
            if update.filesProcessed == 0 { initial = footprint }
            if update.filesProcessed == 1 { completed = footprint }
        }
    }

    func snapshot() -> (initial: Int, completed: Int) {
        lock.withLock { (initial, completed) }
    }
}
