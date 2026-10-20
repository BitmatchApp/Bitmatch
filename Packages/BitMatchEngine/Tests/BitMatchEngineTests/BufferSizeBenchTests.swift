import CryptoKit
import Darwin
import Foundation
import XCTest

/// Opt-in storage benchmark. Run with:
/// `BITMATCH_BENCH=1 swift test --filter BufferSizeBenchTests`
/// Source writes and timed reads request F_NOCACHE, including the first run.
/// This requests a cache bypass but cannot prove a physical-device read;
/// confirm that separately with the selected drive's I/O counters.
/// Cancellation is checked between chunks; synchronous filesystem calls may
/// still wait. Phase timestamps use monotonic uptime, without file paths.
final class BufferSizeBenchTests: XCTestCase {
    private let totalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private let fileBytes: Int64 = 256 * 1_024 * 1_024
    private let bufferSizes = [64, 256, 1_024, 4_096, 8_192].map { $0 * 1_024 }
    private let runs = 5

    func testFNoCacheHashAndCopyThroughput() throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_BENCH"] == "1" else {
            throw XCTSkip("Set BITMATCH_BENCH=1 to run the 2 GB buffer benchmark.")
        }
        try Task.checkCancellation()

        let environment = ProcessInfo.processInfo.environment
        let base = environment["BITMATCH_BENCH_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("bitmatch-buf-bench-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let keepFiles = environment["BITMATCH_BENCH_KEEP"] == "1"
        defer {
            if !keepFiles {
                try? Self.measured(phase: "cleanup", buffer: 0, run: 0, logicalBytes: 0) {
                    try FileManager.default.removeItem(at: root)
                }
            }
        }

        let (files, _) = try Self.measured(phase: "sourceCreation", buffer: 8 * 1_024 * 1_024,
                                            run: 0, logicalBytes: totalBytes) {
            try Self.generateFileSet(at: source, totalBytes: totalBytes, fileBytes: fileBytes)
        }
        var rows: [(buffer: Int, hash: Summary, copy: Summary)] = []
        var referenceDigest: String?

        for bufferSize in bufferSizes {
            try Task.checkCancellation()
            var hashRates: [Double] = []
            var copyRates: [Double] = []
            for run in 0..<runs {
                try Task.checkCancellation()
                let (digest, hashSeconds) = try Self.measured(phase: "hash", buffer: bufferSize,
                                                               run: run + 1, logicalBytes: totalBytes) {
                    try Self.hash(files: files, bufferSize: bufferSize)
                }
                hashRates.append(megabytesPerSecond(bytes: totalBytes, seconds: hashSeconds))
                if let referenceDigest {
                    XCTAssertEqual(digest, referenceDigest)
                } else {
                    referenceDigest = digest
                }

                let destination = root.appendingPathComponent("copy-\(bufferSize)-\(run)", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let (_, copySeconds) = try Self.measured(phase: "rawCopy", buffer: bufferSize,
                                                           run: run + 1, logicalBytes: totalBytes) {
                    try Self.copy(files: files, to: destination, bufferSize: bufferSize)
                }
                copyRates.append(megabytesPerSecond(bytes: totalBytes, seconds: copySeconds))
                _ = try Self.measured(phase: "copyCleanup", buffer: bufferSize,
                                         run: run + 1, logicalBytes: 0) {
                    try FileManager.default.removeItem(at: destination)
                }
            }
            rows.append((bufferSize, summary(hashRates), summary(copyRates)))
        }

        print("\nF_NOCACHE buffer benchmark — 2 GiB in 8 × 256 MiB files, \(runs) runs")
        print("Cache bypass requested for source creation, hash reads, and copy I/O; physical-device reads are not independently confirmed. Check drive read counters before using these numbers for a storage decision.")
        print("Buffer | Hash MB/s median (IQR) | Copy MB/s median (IQR)")
        print("------ | ---------------------- | ----------------------")
        for row in rows {
            let label = bufferLabel(row.buffer).padding(toLength: 6, withPad: " ", startingAt: 0)
            print(String(
                format: "%@ | %8.1f (%6.1f)       | %8.1f (%6.1f)",
                label,
                row.hash.median,
                row.hash.iqr,
                row.copy.median,
                row.copy.iqr
            ))
        }
        if keepFiles { print("Benchmark files kept at \(root.path)") }
    }

    func testSmallFixtureHashAndRawCopyPreserveEveryByte() throws {
        let root = try smallFixture()
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = try Self.generateFileSet(at: source, totalBytes: 256 * 1_024,
                                              fileBytes: 128 * 1_024, blockBytes: 8 * 1_024)
        XCTAssertEqual(files.count, 2)
        let original = try files.map { try Data(contentsOf: $0) }
        var expected = SHA256()
        for data in original { expected.update(data: data) }
        let expectedDigest = expected.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try Self.hash(files: files, bufferSize: 4 * 1_024), expectedDigest)
        try Self.copy(files: files, to: destination, bufferSize: 7 * 1_024)
        let copies = files.map { destination.appendingPathComponent($0.lastPathComponent) }
        XCTAssertEqual(try copies.map { try Data(contentsOf: $0) }, original)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, original)
        XCTAssertEqual(try Self.hash(files: copies, bufferSize: 3 * 1_024), expectedDigest)
    }

    func testCancelledWorkersStopBeforeFixtureIO() async throws {
        let root = try smallFixture()
        let missing = root.appendingPathComponent("not-created")
        let cancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            // Small parameters keep this regression safe even if a guard is
            // removed; wrong errors (such as ENOENT/EBADF) do not count as cancel.
            return [
                Self.throwsCancellation {
                    _ = try Self.generateFileSet(at: root, totalBytes: 256, fileBytes: 256, blockBytes: 64)
                },
                Self.throwsCancellation { _ = try Self.hash(files: [missing], bufferSize: 64) },
                Self.throwsCancellation { try Self.copy(files: [missing], to: root, bufferSize: 64) },
                Self.throwsCancellation { try Self.writeAll(descriptor: -1, bytes: [1], count: 1, path: missing.path) }
            ]
        }.value
        XCTAssertEqual(cancelled, [true, true, true, true])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCancelledPhaseHasMonotonicEndWithoutPrivateFields() throws {
        var breadcrumbs: [PhaseBreadcrumb] = []
        XCTAssertThrowsError(try Self.measured(phase: "hash", buffer: 4_096, run: 3, logicalBytes: 16_384,
                                                emit: { breadcrumbs.append($0) }) {
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(breadcrumbs.map(\.event), ["start", "end"])
        XCTAssertEqual(breadcrumbs.last?.outcome, "cancelled")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(breadcrumbs.last?.monotonicNanoseconds),
                                    try XCTUnwrap(breadcrumbs.first?.monotonicNanoseconds))
        let encoded = try JSONEncoder().encode(try XCTUnwrap(breadcrumbs.last))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["event", "phase", "monotonicNanoseconds", "bufferBytes", "run", "logicalBytes", "outcome"])
        XCTAssertEqual(fields["bufferBytes"] as? Int, 4_096)
        XCTAssertEqual(fields["run"] as? Int, 3)
        XCTAssertEqual(fields["logicalBytes"] as? Int, 16_384)
    }

    private func smallFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-buffer-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private static func throwsCancellation(_ body: () throws -> Void) -> Bool {
        do { try body(); return false }
        catch is CancellationError { return true }
        catch { return false }
    }

    private static func generateFileSet(at directory: URL, totalBytes: Int64, fileBytes: Int64,
                                        blockBytes: Int = 8 * 1_024 * 1_024) throws -> [URL] {
        try Task.checkCancellation()
        let count = Int(totalBytes / fileBytes)
        var block = [UInt8](repeating: 0, count: blockBytes)
        var state: UInt64 = 0x6a09e667f3bcc909
        for index in block.indices {
            if index % (64 * 1_024) == 0 { try Task.checkCancellation() }
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            block[index] = UInt8(truncatingIfNeeded: state)
        }

        return try (0..<count).map { index in
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(String(format: "bench-%02d.bin", index))
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            try requireDescriptor(descriptor, operation: "create", path: url.path)
            defer { Darwin.close(descriptor) }
            // fsync alone flushes the file; it does not evict the data just written.
            // Avoid warming the source in the filesystem cache before the first
            // timed read, just as the timed source reads avoid that cache.
            guard Darwin.fcntl(descriptor, F_NOCACHE, 1) != -1 else {
                throw posixError("F_NOCACHE", url.path)
            }
            var remaining = fileBytes
            while remaining > 0 {
                try Task.checkCancellation()
                let count = min(Int64(block.count), remaining)
                try writeAll(descriptor: descriptor, bytes: block, count: Int(count), path: url.path)
                remaining -= count
            }
            try Task.checkCancellation()
            guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync", url.path) }
            try Task.checkCancellation()
            return url
        }
    }

    private static func hash(files: [URL], bufferSize: Int) throws -> String {
        try Task.checkCancellation()
        var hasher = SHA256()
        for file in files {
            try Task.checkCancellation()
            let descriptor = Darwin.open(file.path, O_RDONLY)
            try requireDescriptor(descriptor, operation: "open", path: file.path)
            guard Darwin.fcntl(descriptor, F_NOCACHE, 1) != -1 else {
                Darwin.close(descriptor)
                throw posixError("F_NOCACHE", file.path)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            while true {
                try Task.checkCancellation()
                // The read itself must be inside the pool; pooling only the
                // hasher update leaves Foundation's read buffers undrained.
                let readData = try autoreleasepool {
                    guard let data = try handle.read(upToCount: bufferSize), !data.isEmpty else { return false }
                    hasher.update(data: data)
                    return true
                }
                if !readData { break }
            }
        }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func copy(files: [URL], to directory: URL, bufferSize: Int) throws {
        try Task.checkCancellation()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        for source in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            let input = Darwin.open(source.path, O_RDONLY)
            try requireDescriptor(input, operation: "open", path: source.path)
            defer { Darwin.close(input) }
            let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            try requireDescriptor(output, operation: "create", path: destination.path)
            defer { Darwin.close(output) }
            guard Darwin.fcntl(input, F_NOCACHE, 1) != -1 else { throw posixError("F_NOCACHE", source.path) }
            guard Darwin.fcntl(output, F_NOCACHE, 1) != -1 else { throw posixError("F_NOCACHE", destination.path) }

            while true {
                try Task.checkCancellation()
                let bytesRead = buffer.withUnsafeMutableBytes { storage in
                    Darwin.read(input, storage.baseAddress, storage.count)
                }
                if bytesRead == 0 { break }
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    throw posixError("read", source.path)
                }
                try writeAll(descriptor: output, bytes: buffer, count: bytesRead, path: destination.path)
            }
            try Task.checkCancellation()
            guard Darwin.fcntl(output, F_FULLFSYNC) != -1 else {
                throw posixError("F_FULLFSYNC", destination.path)
            }
            try Task.checkCancellation()
        }
    }

    private static func writeAll(descriptor: Int32, bytes: [UInt8], count: Int, path: String) throws {
        try Task.checkCancellation()
        var written = 0
        while written < count {
            try Task.checkCancellation()
            let result = bytes.withUnsafeBytes { storage in
                Darwin.write(descriptor, storage.baseAddress?.advanced(by: written), count - written)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw posixError("write", path)
            }
            guard result > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            written += result
        }
    }

    private static func requireDescriptor(_ descriptor: Int32, operation: String, path: String) throws {
        guard descriptor >= 0 else { throw posixError(operation, path) }
    }

    private static func posixError(_ operation: String, _ path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed for \(path): \(String(cString: strerror(errno)))"]
        )
    }

    private struct PhaseBreadcrumb: Encodable {
        let event: String
        let phase: String
        let monotonicNanoseconds: UInt64
        let bufferBytes: Int
        let run: Int
        /// Intended bytes for this phase; not a count of physical-device I/O.
        let logicalBytes: Int64
        let outcome: String?
    }

    private static func emit(_ breadcrumb: PhaseBreadcrumb) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(breadcrumb) {
            // Write immediately so an external counter observer can align the
            // first hash with creation/copy/cleanup without stdout buffering.
            try? FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
        }
    }

    private static func measured<T>(phase: String, buffer: Int, run: Int, logicalBytes: Int64,
                                     emit: (PhaseBreadcrumb) -> Void = BufferSizeBenchTests.emit,
                                     body: () throws -> T) throws -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        emit(PhaseBreadcrumb(event: "start", phase: phase, monotonicNanoseconds: start,
                             bufferBytes: buffer, run: run, logicalBytes: logicalBytes, outcome: nil))
        var outcome = "failed"
        defer {
            emit(PhaseBreadcrumb(event: "end", phase: phase,
                                 monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                 bufferBytes: buffer, run: run, logicalBytes: logicalBytes, outcome: outcome))
        }
        do {
            let value = try body()
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            outcome = "completed"
            return (value, seconds)
        } catch is CancellationError {
            outcome = "cancelled"
            throw CancellationError()
        }
    }

    private func megabytesPerSecond(bytes: Int64, seconds: Double) -> Double {
        Double(bytes) / 1_048_576 / max(seconds, 0.000_001)
    }

    private struct Summary {
        let median: Double
        let iqr: Double
    }

    private func summary(_ values: [Double]) -> Summary {
        let sorted = values.sorted()
        return Summary(
            median: sorted[sorted.count / 2],
            iqr: sorted[(sorted.count * 3) / 4] - sorted[sorted.count / 4]
        )
    }

    private func bufferLabel(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? "\(bytes / 1_048_576)M" : "\(bytes / 1_024)K"
    }
}
