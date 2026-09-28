import Foundation
import Darwin
import Testing
@testable import BitMatchEngine

/// Verification must read the backup drive, not memory. With the system cache
/// on, a file the engine just wrote is 100% resident, so hashing it "back"
/// never touches the drive (measured 2026-09-26: 15.8 GB/s read-back). The
/// copy writes with F_NOCACHE, so nothing of it is left in memory.
struct ReadBackFromDiskTests {

    /// Plant: in `PinnedDestinationDirectory.createTemporaryFile`, delete the
    /// `fcntl(fd, F_NOCACHE, 1)` guard. The copy is then fully resident.
    @Test func copiedFileIsNotLeftInMemory() async throws {
        let fixture = try Fixture(files: ["A001C001.MXF": 32 * 1024 * 1024 + 123])
        defer { fixture.remove() }
        try await fixture.copy()

        let copied = fixture.destinationFile("A001C001.MXF")
        // Allow the unaligned last page and a little readahead.
        #expect(try Self.residentFraction(of: copied) < 0.02)
    }

    /// Byte-exact copies at page and chunk boundaries, where cache-bypassing
    /// writes of unaligned lengths could go wrong.
    @Test func boundarySizesCopyExactly() async throws {
        let sizes = [0, 1, 4095, 4096, 4097, 4 * 1024 * 1024 - 1, 4 * 1024 * 1024, 4 * 1024 * 1024 + 1]
        var files: [String: Int] = [:]
        for size in sizes { files["clip_\(size).bin"] = size }
        let fixture = try Fixture(files: files)
        defer { fixture.remove() }
        try await fixture.copy()

        for name in files.keys {
            let original = try Data(contentsOf: fixture.source.appendingPathComponent(name))
            let copied = try Data(contentsOf: fixture.destinationFile(name))
            #expect(copied == original, "\(name) was not copied exactly")
        }
    }

    /// The fraction of a file's pages resident in memory (mincore on a
    /// read-only mapping; mapping does not fault pages in).
    static func residentFraction(of url: URL) throws -> Double {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.ENOENT) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return 0 }
        let size = Int(info.st_size)
        guard let mapping = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), mapping != MAP_FAILED else {
            throw POSIXError(.EIO)
        }
        defer { munmap(mapping, size) }
        let pageSize = Int(getpagesize())
        var pages = [CChar](repeating: 0, count: (size + pageSize - 1) / pageSize)
        guard mincore(mapping, size, &pages) == 0 else { throw POSIXError(.EIO) }
        return Double(pages.filter { $0 & 1 != 0 }.count) / Double(pages.count)
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL

        init(files: [String: Int]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("bitmatch_readback_\(UUID().uuidString)")
            source = root.appendingPathComponent("CARD")
            destination = root.appendingPathComponent("BACKUP")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for (name, size) in files {
                var bytes = [UInt8](repeating: 0, count: size)
                for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index &* 31 &+ size) }
                try Data(bytes).write(to: source.appendingPathComponent(name))
            }
        }

        func destinationFile(_ name: String) -> URL {
            destination.appendingPathComponent("CARD").appendingPathComponent(name)
        }

        func copy() async throws {
            let pinnedRoot = try PinnedDestinationDirectory.open(destination: destination, rootComponents: ["CARD"])
            let errors = ErrorCollector()
            try await DestinationWriter.copyAllSafely(
                from: source,
                toPinnedRoot: pinnedRoot,
                verificationMode: .standard,
                workers: 1,
                checksumService: ChecksumEngine.shared,
                preEnumeratedFiles: try CardSource.enumerateRegularFiles(base: source).map(\.url),
                onProgress: { _, _, _ in },
                onError: { path, error in await errors.record("\(path): \(error.localizedDescription)") }
            )
            let recorded = await errors.errors
            #expect(recorded.isEmpty, "copy errors: \(recorded)")
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private actor ErrorCollector {
        var errors: [String] = []
        func record(_ error: String) { errors.append(error) }
    }
}
