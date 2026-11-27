import Foundation
import Synchronization
import Testing
@testable import BitMatchEngine

@Suite struct FinderMetadataSelectionTests {
    private func skipped(_ root: URL) throws -> [String] {
        try FinderMetadataSelection.skipped(in: CardSource.enumerateRegularFiles(base: root)).map(\.relativePath)
    }

    @Test func aFinderViewFileAtTheRootAndNestedIsSkipped() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("A/B")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FinderMetadataFixtures.bud1(size: 6148).write(to: root.appendingPathComponent(".DS_Store"))
        try FinderMetadataFixtures.bud1(size: 6148).write(to: nested.appendingPathComponent(".DS_Store"))
        try Data("media".utf8).write(to: root.appendingPathComponent("clip.mov"))
        #expect(try skipped(root) == [".DS_Store", "A/B/.DS_Store"])
    }

    @Test func randomBytesEmptyAndShortFilesAreOrdinary() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["random", "empty", "short"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var generator = SystemRandomNumberGenerator()
        let random = Data((0..<6148).map { _ in UInt8.random(in: 0...255, using: &generator) })
        try random.write(to: root.appendingPathComponent("random/.DS_Store"))
        try Data().write(to: root.appendingPathComponent("empty/.DS_Store"))
        try FinderMetadataFixtures.bud1(size: 20).write(to: root.appendingPathComponent("short/.DS_Store"))
        #expect(try skipped(root).isEmpty)
    }

    @Test func inconsistentOffsetsOrOversizeAreOrdinary() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, Data)] = [
            ("offsets", FinderMetadataFixtures.bud1(size: 6148, offset: 0x800, repeatedOffset: 0x900)),
            ("beyond", FinderMetadataFixtures.bud1(size: 6148, offset: 0x1000, rootSize: 0x1000)),
            ("zero", FinderMetadataFixtures.bud1(size: 6148, rootSize: 0)),
            // A consistent header whose root block lacks the DSDB entry.
            ("no-dsdb", FinderMetadataFixtures.bud1(size: 6148, rootMarker: false)),
            // The smallest header-only file: offsets fit, root block is zeros.
            ("header-only", FinderMetadataFixtures.bud1(size: 36, offset: 16, rootSize: 16)),
            ("oversize", FinderMetadataFixtures.bud1(size: Int(FinderMetadataSelection.maximumSize) + 1))
        ]
        for (name, data) in cases {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("\(name)/.DS_Store"))
        }
        #expect(try skipped(root).isEmpty)
    }

    @Test func malformedRootDirectoryAndHardLinksAreOrdinary() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = 4 + 0x800 + 8 + 256 * 4
        for (name, index, value) in [("count", directory + 3, UInt8(2)),
                                     ("length", directory + 4, UInt8(3)),
                                     ("block", directory + 12, UInt8(1))] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var data = FinderMetadataFixtures.bud1(size: 6148)
            data[index] = value
            try data.write(to: folder.appendingPathComponent(".DS_Store"))
        }
        let folder = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = folder.appendingPathComponent("clip.mov")
        try FinderMetadataFixtures.bud1(size: 6148).write(to: clip)
        try FileManager.default.linkItem(at: clip, to: folder.appendingPathComponent(".DS_Store"))
        #expect(try skipped(root).isEmpty)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/.DS_Store").path)))
    func realDesktopFinderFileClassifiesWhenPresent() throws {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/.DS_Store")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var info = stat()
        #expect(fstat(fd, &info) == 0)
        #expect(try FinderMetadataSelection.isFinderViewFile(fd: fd, size: Int64(info.st_size)))
    }

    @Test func otherSpellingsAreOrdinary() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = [".ds_store", ".DS_Store ", "x.DS_Store", ".DS_Store\u{0301}", ".DS_Store".decomposedStringWithCanonicalMapping + "\u{200B}"]
        for (index, name) in names.enumerated() {
            let dir = root.appendingPathComponent("d\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FinderMetadataFixtures.bud1(size: 6148).write(to: dir.appendingPathComponent(name))
        }
        #expect(try skipped(root).isEmpty)
    }

    @Test func aDirectoryNamedDSStoreIsNotClassifiedAndItsFileIsOrdinary() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(".DS_Store")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("x.txt"))
        #expect(try skipped(root).isEmpty)
    }

    @Test func anAppleDoubleFileIsUntouched() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        var bytes = [UInt8](repeating: 0, count: 42)
        func put(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
        }
        put(0x00051607, 0); put(0x00020000, 4)
        bytes[25] = 1
        put(2, 26); put(38, 30); put(4, 34)
        try Data("media".utf8).write(to: root.appendingPathComponent("clip.mov"))
        try Data(bytes).write(to: root.appendingPathComponent("._clip.mov"))
        #expect(try skipped(root).isEmpty)
    }

    @Test func aFileThatChangesWhileReadingThrows() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".DS_Store")
        try FinderMetadataFixtures.bud1(size: 6148).write(to: file)
        let path = file.path
        let entry = try #require(try CardSource.enumerateRegularFiles(base: root).first)
        let calls = Mutex(0)
        #expect(throws: FinderMetadataSelection.MetadataChanged.self) {
            try FinderMetadataSelection.skipped(in: [entry], checkCancellation: {
                // Call 1 is the filter's own check; call 2 is the first read,
                // after the parser has taken its opening fstat.
                if calls.withLock({ $0 += 1; return $0 }) == 2 { truncate(path, 5000) }
            })
        }
    }

    /// Start's tolerant form: an entry that cannot be classified (gone,
    /// resized or unreadable since the scan) is ordinary data, reported to
    /// the caller, and the others still classify.
    @Test func anEntryThatCannotBeClassifiedIsOrdinaryAndReported() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer {
            chmod(root.appendingPathComponent("unreadable/.DS_Store").path, 0o644)
            try? FileManager.default.removeItem(at: root)
        }
        for name in ["gone", "resized", "unreadable", "good"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FinderMetadataFixtures.bud1(size: 6148).write(to: folder.appendingPathComponent(".DS_Store"))
        }
        let entries = try CardSource.enumerateRegularFiles(base: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone/.DS_Store"))
        try FinderMetadataFixtures.bud1(size: 8192).write(to: root.appendingPathComponent("resized/.DS_Store"))
        #expect(chmod(root.appendingPathComponent("unreadable/.DS_Store").path, 0) == 0)

        let reported = Mutex<[String]>([])
        let skipped = try FinderMetadataSelection.skipped(in: entries, onUnclassified: { entry, _ in
            reported.withLock { $0.append(entry.relativePath) }
        })
        #expect(skipped.map(\.relativePath) == ["good/.DS_Store"])
        #expect(reported.withLock { $0.sorted() } == ["gone/.DS_Store", "resized/.DS_Store", "unreadable/.DS_Store"])
        // Without the handler the first failure still throws.
        #expect(throws: (any Error).self) { try FinderMetadataSelection.skipped(in: entries) }
    }

    /// Cancellation is never swallowed by the tolerant form.
    @Test func cancellationStillThrowsFromTheTolerantForm() throws {
        let root = try FinderMetadataFixtures.makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        try FinderMetadataFixtures.bud1(size: 6148).write(to: root.appendingPathComponent(".DS_Store"))
        let entries = try CardSource.enumerateRegularFiles(base: root)
        let calls = Mutex(0)
        #expect(throws: CancellationError.self) {
            try FinderMetadataSelection.skipped(in: entries, checkCancellation: {
                if calls.withLock({ $0 += 1; return $0 }) >= 2 { throw CancellationError() }
            }, onUnclassified: { _, _ in })
        }
    }
}
