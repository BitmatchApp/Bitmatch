import CryptoKit
import Darwin
import Foundation
import XCTest

/// Opt-in storage benchmark. Run with:
/// `BITMATCH_BENCH=1 swift test --filter BufferSizeBenchTests`
final class BufferSizeBenchTests: XCTestCase {
    private let totalBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    private let fileBytes: Int64 = 256 * 1_024 * 1_024
    private let bufferSizes = [64, 256, 1_024, 4_096, 8_192].map { $0 * 1_024 }
    private let runs = 5

    func testFNoCacheHashAndCopyThroughput() throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_BENCH"] == "1" else {
            throw XCTSkip("Set BITMATCH_BENCH=1 to run the 2 GB buffer benchmark.")
        }

        let environment = ProcessInfo.processInfo.environment
        let base = environment["BITMATCH_BENCH_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("bitmatch-buf-bench-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let keepFiles = environment["BITMATCH_BENCH_KEEP"] == "1"
        defer { if !keepFiles { try? FileManager.default.removeItem(at: root) } }

        let files = try generateFileSet(at: source)
        var rows: [(buffer: Int, hash: Summary, copy: Summary)] = []
        var referenceDigest: String?

        for bufferSize in bufferSizes {
            var hashRates: [Double] = []
            var copyRates: [Double] = []
            for run in 0..<runs {
                let hashStart = ContinuousClock.now
                let digest = try hash(files: files, bufferSize: bufferSize)
                let hashSeconds = seconds(since: hashStart)
                hashRates.append(megabytesPerSecond(bytes: totalBytes, seconds: hashSeconds))
                if let referenceDigest {
                    XCTAssertEqual(digest, referenceDigest)
                } else {
                    referenceDigest = digest
                }

                let destination = root.appendingPathComponent("copy-\(bufferSize)-\(run)", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let copyStart = ContinuousClock.now
                try copy(files: files, to: destination, bufferSize: bufferSize)
                let copySeconds = seconds(since: copyStart)
                copyRates.append(megabytesPerSecond(bytes: totalBytes, seconds: copySeconds))
                try FileManager.default.removeItem(at: destination)
            }
            rows.append((bufferSize, summary(hashRates), summary(copyRates)))
        }

        print("\nF_NOCACHE buffer benchmark — 2 GiB in 8 × 256 MiB files, \(runs) runs")
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

    private func generateFileSet(at directory: URL) throws -> [URL] {
        let count = Int(totalBytes / fileBytes)
        var block = [UInt8](repeating: 0, count: 8 * 1_024 * 1_024)
        var state: UInt64 = 0x6a09e667f3bcc909
        for index in block.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            block[index] = UInt8(truncatingIfNeeded: state)
        }

        return try (0..<count).map { index in
            let url = directory.appendingPathComponent(String(format: "bench-%02d.bin", index))
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            try requireDescriptor(descriptor, operation: "create", path: url.path)
            defer { Darwin.close(descriptor) }
            var remaining = fileBytes
            while remaining > 0 {
                let count = min(Int64(block.count), remaining)
                try writeAll(descriptor: descriptor, bytes: block, count: Int(count), path: url.path)
                remaining -= count
            }
            guard Darwin.fsync(descriptor) == 0 else { throw posixError("fsync", url.path) }
            return url
        }
    }

    private func hash(files: [URL], bufferSize: Int) throws -> String {
        var hasher = SHA256()
        for file in files {
            let descriptor = Darwin.open(file.path, O_RDONLY)
            try requireDescriptor(descriptor, operation: "open", path: file.path)
            guard Darwin.fcntl(descriptor, F_NOCACHE, 1) != -1 else {
                Darwin.close(descriptor)
                throw posixError("F_NOCACHE", file.path)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: bufferSize), !data.isEmpty {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copy(files: [URL], to directory: URL, bufferSize: Int) throws {
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        for source in files {
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
            guard Darwin.fcntl(output, F_FULLFSYNC) != -1 else {
                throw posixError("F_FULLFSYNC", destination.path)
            }
        }
    }

    private func writeAll(descriptor: Int32, bytes: [UInt8], count: Int, path: String) throws {
        var written = 0
        while written < count {
            let result = bytes.withUnsafeBytes { storage in
                Darwin.write(descriptor, storage.baseAddress?.advanced(by: written), count - written)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw posixError("write", path)
            }
            written += result
        }
    }

    private func requireDescriptor(_ descriptor: Int32, operation: String, path: String) throws {
        guard descriptor >= 0 else { throw posixError(operation, path) }
    }

    private func posixError(_ operation: String, _ path: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed for \(path): \(String(cString: strerror(errno)))"]
        )
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
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
