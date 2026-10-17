import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

#if os(macOS)
final class StreamingMemoryProbeTests: XCTestCase {
    /// Opt in and run this test alone: process-footprint measurements are
    /// meaningless when another test is allocating in the same process.
    /// The source is sparse, but the real fan-out writer copies every byte to
    /// one and then two disposable destinations. No verification or report
    /// pass runs, so the samples isolate copy-phase memory.
    func testSparse512MiBCopyKeepsMemoryBoundedWithOneAndTwoDestinations() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_COPY_MEMORY_TEST"] == "1" else {
            throw XCTSkip("Set BITMATCH_COPY_MEMORY_TEST=1 and run this test in isolation")
        }
        let size = Int64(512 * 1_024 * 1_024)
        let available = (try FileManager.default.attributesOfFileSystem(
            forPath: FileManager.default.temporaryDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available > size * 2 + 2 * 1_024 * 1_024 * 1_024 else {
            throw XCTSkip("Not enough free space for disposable copy outputs")
        }

        for destinationCount in [1, 2] {
            try await measureCopy(destinationCount: destinationCount)
        }
    }

    /// This separate opt-in probe exercises the byte-comparison loop used by
    /// Paranoid folder Compare. The pinned Paranoid transfer verifier uses a
    /// different loop. Sparse inputs make a full 4 MiB-at-a-time pass without
    /// consuming 1 GiB of disk.
    func testSparse512MiBByteComparisonKeepsMemoryBounded() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_COMPARE_MEMORY_TEST"] == "1" else {
            throw XCTSkip("Set BITMATCH_COMPARE_MEMORY_TEST=1 and run this test in isolation")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-compare-memory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let size = UInt64(512 * 1_024 * 1_024)
        let source = root.appendingPathComponent("source.bin")
        let destination = root.appendingPathComponent("destination.bin")
        for file in [source, destination] {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: size)
            try handle.close()
        }

        let samples = ComparisonFootprintSamples()
        samples.started()
        let match = try await ChecksumEngine.shared.performByteComparison(
            sourceURL: source, destinationURL: destination,
            progressCallback: { _, _ in samples.sample() }
        )
        let measured = samples.snapshot()
        XCTAssertTrue(match)
        XCTAssertGreaterThanOrEqual(measured.chunks, 128)
        XCTAssertGreaterThan(measured.initialMiB, 0)
        XCTAssertEqual(measured.missingSamples, 0, "Could not measure physical footprint")
        print("compare memory initialMiB=\(measured.initialMiB) peakMiB=\(measured.peakMiB) finalMiB=\(measured.finalMiB) chunks=\(measured.chunks)")
        XCTAssertLessThan(measured.peakMiB - measured.initialMiB, 128,
                          "Byte comparison footprint grew with two 512 MiB files")
    }

    private func measureCopy(destinationCount: Int) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-copy-memory-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let size = Int64(512 * 1_024 * 1_024)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let clip = source.appendingPathComponent("clip.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: clip.path, contents: nil))
        let writer = try FileHandle(forWritingTo: clip)
        try writer.truncate(atOffset: UInt64(size))
        try writer.close()

        let destinations = try (0..<destinationCount).map { index -> DestinationWriter.FanOutDestination in
            let url = root.appendingPathComponent("backup-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return .init(index: index, root: try PinnedDestinationDirectory.open(destination: url, rootComponents: []))
        }
        let samples = CopyFootprintSamples(expectedSize: size)
        let hooks = DestinationWriter.FanOutHooks(sourceDidOpen: { _ in samples.opened() })

        try await DestinationWriter.copyAllSafelyFanOut(
            from: source,
            toPinnedRoots: destinations,
            verificationMode: .standard,
            workers: 1,
            checksumService: ChecksumEngine.shared,
            preEnumeratedFiles: [clip],
            hooks: hooks,
            onIOBytes: { index, phase, count, _, _ in
                switch phase {
                case .writing: samples.wrote(index: index, count: count)
                case .readingBack: break
                }
            },
            onProgress: { index, _, byteCount, wasReused in
                samples.completed(index: index, byteCount: byteCount, wasReused: wasReused)
            },
            onError: { _, _, error in samples.failed(error) }
        )

        let measured = samples.snapshot()
        XCTAssertTrue(measured.errors.isEmpty, "Copy failed: \(measured.errors)")
        XCTAssertGreaterThan(measured.initialMiB, 0)
        XCTAssertEqual(measured.missingSamples, 0, "Could not measure physical footprint")
        XCTAssertEqual(measured.completedIndexes, Set(0..<destinationCount))
        XCTAssertEqual(measured.writtenBytes.count, destinationCount)
        for destination in destinations {
            XCTAssertEqual(measured.writtenBytes[destination.index], size)
            let copied = destination.root.logicalRootURL.appendingPathComponent("clip.bin")
            let copiedSize = (try FileManager.default.attributesOfItem(atPath: copied.path)[.size] as? NSNumber)?.int64Value
            XCTAssertEqual(copiedSize, size)
        }
        let sourceSize = (try FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? NSNumber)?.int64Value
        XCTAssertEqual(sourceSize, size)
        print("copy memory destinations=\(destinationCount) initialMiB=\(measured.initialMiB) peakMiB=\(measured.peakMiB) finalMiB=\(measured.finalMiB) writtenBytes=\(measured.writtenBytes)")
        XCTAssertLessThan(measured.peakMiB - measured.initialMiB, 128,
                          "Copy footprint grew with a 512 MiB source")
    }
}

private final class CopyFootprintSamples: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedSize: Int64
    private var initialMiB = 0
    private var peakMiB = 0
    private var writtenBytes: [Int: Int64] = [:]
    private var completedIndexes: Set<Int> = []
    private var errors: [String] = []
    private var missingSamples = 0

    init(expectedSize: Int64) { self.expectedSize = expectedSize }

    func opened() {
        lock.withLock {
            if let footprint = TransferDiagnosticStore.physicalFootprintMB() {
                initialMiB = footprint
                peakMiB = footprint
            } else {
                missingSamples += 1
            }
        }
    }

    func wrote(index: Int, count: Int) {
        lock.withLock {
            writtenBytes[index, default: 0] += Int64(count)
            if let footprint = TransferDiagnosticStore.physicalFootprintMB() {
                peakMiB = max(peakMiB, footprint)
            } else {
                missingSamples += 1
            }
        }
    }

    func completed(index: Int, byteCount: Int64, wasReused: Bool) {
        lock.withLock {
            if wasReused { errors.append("Unexpected reuse at destination \(index)") }
            if byteCount != expectedSize { errors.append("Unexpected progress size at destination \(index)") }
            completedIndexes.insert(index)
        }
    }

    func failed(_ error: Error) {
        lock.withLock { errors.append(error.localizedDescription) }
    }

    func snapshot() -> (initialMiB: Int, peakMiB: Int, finalMiB: Int,
                        writtenBytes: [Int: Int64], completedIndexes: Set<Int>,
                        errors: [String], missingSamples: Int) {
        lock.withLock {
            let finalMiB = TransferDiagnosticStore.physicalFootprintMB()
            if finalMiB == nil { missingSamples += 1 }
            return (initialMiB, peakMiB, finalMiB ?? 0,
                    writtenBytes, completedIndexes, errors, missingSamples)
        }
    }
}

private final class ComparisonFootprintSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var initialMiB = 0
    private var peakMiB = 0
    private var chunks = 0
    private var missingSamples = 0

    func started() {
        lock.withLock {
            if let footprint = TransferDiagnosticStore.physicalFootprintMB() {
                initialMiB = footprint
                peakMiB = footprint
            } else {
                missingSamples += 1
            }
        }
    }

    func sample() {
        lock.withLock {
            chunks += 1
            if let footprint = TransferDiagnosticStore.physicalFootprintMB() {
                peakMiB = max(peakMiB, footprint)
            } else {
                missingSamples += 1
            }
        }
    }

    func snapshot() -> (initialMiB: Int, peakMiB: Int, finalMiB: Int,
                        chunks: Int, missingSamples: Int) {
        lock.withLock {
            let finalMiB = TransferDiagnosticStore.physicalFootprintMB()
            if finalMiB == nil { missingSamples += 1 }
            return (initialMiB, peakMiB, finalMiB ?? 0, chunks, missingSamples)
        }
    }
}
#endif
