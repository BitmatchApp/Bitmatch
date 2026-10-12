import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

final class ASCMHLMemoryTests: XCTestCase {
    /// Opt in to keep physical-footprint measurements in an isolated test host.
    /// Plant: the MHL reread used to retain almost every 4 MiB Foundation
    /// buffer while hashing one large file, even though verification was bounded.
    func testLargeDestinationRereadKeepsMemoryBounded() throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_MHL_MEMORY_TEST"] == "1" else {
            throw XCTSkip("Set BITMATCH_MHL_MEMORY_TEST=1 for the isolated footprint test")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-mhl-memory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let media = root.appendingPathComponent("clip.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: media.path, contents: nil))
        let size = UInt64(512 * 1_024 * 1_024)
        let writer = try FileHandle(forWritingTo: media)
        try writer.truncate(atOffset: size)
        try writer.close()

        var sha = SHA256()
        for _ in 0..<128 {
            autoreleasepool { sha.update(data: Data(repeating: 0, count: 4 * 1_024 * 1_024)) }
        }
        let expected = sha.finalize().map { String(format: "%02x", $0) }.joined()
        let samples = MHLFootprintSamples()

        let manifest = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [.init(relativePath: "clip.bin", size: Int64(size), expectedSHA256: expected)],
            startTime: Date(), toolVersion: "memory-test",
            readHooks: .init(
                didOpenForRead: { _ in samples.opened() },
                didRead: { _, count in samples.read(count) },
                fileSystemType: { "exfat" }
            )
        )

        let measured = samples.snapshot()
        XCTAssertEqual(measured.chunks, 128)
        XCTAssertEqual(measured.bytes, Int64(size))
        XCTAssertGreaterThan(measured.initial, 0)
        XCTAssertLessThan(measured.peak - measured.initial, 128,
                          "MHL read grew by \(measured.peak - measured.initial) MiB for a 512 MiB file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            manifest.deletingLastPathComponent().appendingPathComponent("ascmhl_chain.xml").path))
        print("MHL memory initialMiB=\(measured.initial) peakMiB=\(measured.peak) bytes=\(measured.bytes) chunks=\(measured.chunks)")
    }
}

private final class MHLFootprintSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var initial = 0
    private var peak = 0
    private var bytes: Int64 = 0
    private var chunks = 0

    func opened() {
        lock.withLock {
            initial = TransferDiagnosticStore.physicalFootprintMB() ?? 0
            peak = initial
        }
    }

    func read(_ count: Int) {
        lock.withLock {
            bytes += Int64(count)
            chunks += 1
            peak = max(peak, TransferDiagnosticStore.physicalFootprintMB() ?? 0)
        }
    }

    func snapshot() -> (initial: Int, peak: Int, bytes: Int64, chunks: Int) {
        lock.withLock { (initial, peak, bytes, chunks) }
    }
}
