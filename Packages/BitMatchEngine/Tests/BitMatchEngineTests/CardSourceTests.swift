import XCTest
@testable import BitMatchEngine
#if canImport(Darwin)
import Darwin
#endif

final class CardSourceTests: XCTestCase {
    func testMissingRootThrowsInsteadOfReturningEmptyManifest() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-manifest-\(UUID().uuidString)")
        XCTAssertThrowsError(try CardSource.enumerateRegularFiles(base: missing))
    }

    func testValidEmptyRootReturnsEmptyManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(try CardSource.enumerateRegularFiles(base: root).isEmpty)
    }

    func testDatalessFilesFailTheManifestBeforeAnySourceRead() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dataless-manifest-\(UUID().uuidString)", isDirectory: true)
        let local = root.appendingPathComponent("DCIM/local.mov")
        let firstCloud = root.appendingPathComponent("DCIM/cloud-a.mov")
        let secondCloud = root.appendingPathComponent("DCIM/cloud-b.mov")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("local".utf8).write(to: local)
        try Data("stub".utf8).write(to: firstCloud)
        try Data("stub".utf8).write(to: secondCloud)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try CardSource.enumerateRegularFiles(base: root, isDataless: { url in
            url.lastPathComponent == firstCloud.lastPathComponent
                || url.lastPathComponent == secondCloud.lastPathComponent
        })) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "2 files on this source are stored in the cloud, not on this disk. Download them first. First file: DCIM/cloud-a.mov."
            )
        }
    }

    func testCloudManagedSourceIsRefusedBeforeEnumeration() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-source-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent(
            "Library/CloudStorage/Provider/Card-001",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        XCTAssertThrowsError(try CardSource.enumerateRegularFiles(base: root)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "This source is in a cloud-managed location. Choose a source on a local disk."
            )
        }
    }

    func testPreCancelledTaskThrowsForValidEmptyRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled-empty-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CardSource.enumerateRegularFiles(base: root)
        }

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    /// Cards carry macOS volume metadata folders (.Spotlight-V100, .fseventsd, ...) that are
    /// unreadable without Full Disk Access. They are never user data and must be skipped,
    /// not treated as a fatal traversal error.
    func testSkipsUnreadableVolumeMetadataDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("metadata-manifest-\(UUID().uuidString)", isDirectory: true)
        let spotlight = root.appendingPathComponent(".Spotlight-V100", isDirectory: true)
        let dcim = root.appendingPathComponent("DCIM", isDirectory: true)
        try fm.createDirectory(at: spotlight, withIntermediateDirectories: true)
        try fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: dcim.appendingPathComponent("A001.MOV"))
        try Data("index".utf8).write(to: spotlight.appendingPathComponent("store.db"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: spotlight.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spotlight.path)
            try? fm.removeItem(at: root)
        }

        let entries = try CardSource.enumerateRegularFiles(base: root)
        // The temp root is /var/..., which the enumerator reports as /private/var/...;
        // nested structure must survive that alias instead of collapsing to "A001.MOV".
        XCTAssertEqual(entries.map(\.relativePath), ["DCIM/A001.MOV"])
    }

    /// Only the volume root's metadata folders are skipped; a user folder that shares
    /// one of those names deeper in the tree is real data and must be kept.
    func testNestedFolderNamedLikeVolumeMetadataIsKept() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("nested-metadata-name-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("DCIM/.Trashes", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: nested.appendingPathComponent("A002.MOV"))
        defer { try? fm.removeItem(at: root) }

        let entries = try CardSource.enumerateRegularFiles(base: root)
        XCTAssertEqual(entries.map(\.relativePath), ["DCIM/.Trashes/A002.MOV"])
    }

    func testRootRegularFileNamedLikeVolumeMetadataIsKept() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("metadata-file-name-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("user data".utf8).write(to: root.appendingPathComponent(".Trashes"))
        defer { try? fm.removeItem(at: root) }

        let entries = try CardSource.enumerateRegularFiles(base: root)
        XCTAssertEqual(entries.map(\.relativePath), [".Trashes"])
        XCTAssertNoThrow(try SafetyValidator.validateSourceTreeForCopy(source: root))
    }

#if canImport(Darwin)
    func testRootFSEventsDirectoryAppearingAndDisappearingDuringEnumeration() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("fsevents-churn-\(UUID().uuidString)", isDirectory: true)
        let rootMetadata = root.appendingPathComponent(".fseventsd", isDirectory: true)
        let nestedMetadata = root.appendingPathComponent("DCIM/.fseventsd", isDirectory: true)
        try fm.createDirectory(at: nestedMetadata, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: root.appendingPathComponent("DCIM/A.MOV"))
        try Data("user data".utf8).write(to: nestedMetadata.appendingPathComponent("notes.txt"))
        defer { try? fm.removeItem(at: root) }

        let expected = ["DCIM/.fseventsd/notes.txt", "DCIM/A.MOV"]
        let baseline = try CardSource.enumerateRegularFiles(base: root)
        XCTAssertEqual(baseline.map(\.relativePath), expected)
        let baselineFingerprint = SourceFingerprint.make(baseline)

        var created = false
        let withAppearance = try enumerateTree(base: root) { _ in
            guard !created else { return }
            try fm.createDirectory(at: rootMetadata, withIntermediateDirectories: true)
            try Data("system log".utf8).write(to: rootMetadata.appendingPathComponent("00000001"))
            created = true
        }
        XCTAssertTrue(created, "The metadata directory must appear after enumeration begins")
        XCTAssertEqual(regularPaths(in: withAppearance), expected)
        XCTAssertEqual(SourceFingerprint.make(files(in: withAppearance)), baselineFingerprint)

        var removed = false
        let withDisappearance = try enumerateTree(base: root) { name in
            guard name == ".fseventsd" else { return }
            try fm.removeItem(at: rootMetadata)
            removed = true
        }
        XCTAssertTrue(removed, "The walker must encounter metadata before the test removes it")
        XCTAssertEqual(regularPaths(in: withDisappearance), expected)
        XCTAssertEqual(SourceFingerprint.make(files(in: withDisappearance)), baselineFingerprint)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("DCIM/A.MOV")), Data("clip".utf8))
        XCTAssertEqual(
            try Data(contentsOf: nestedMetadata.appendingPathComponent("notes.txt")),
            Data("user data".utf8)
        )
    }

    func testDisappearingOrdinaryRootFileStillFailsEnumeration() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("source-file-churn-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("A.MOV")
        try Data("clip".utf8).write(to: media)
        defer { try? fm.removeItem(at: root) }

        var removed = false
        XCTAssertThrowsError(try enumerateTree(base: root) { name in
            guard name == "A.MOV" else { return }
            try fm.removeItem(at: media)
            removed = true
        }) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
        XCTAssertTrue(removed)
    }

    func testDisappearingRegularFileNamedFSEventsStillFailsEnumeration() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("fsevents-user-file-churn-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let userFile = root.appendingPathComponent(".fseventsd")
        try Data("user data".utf8).write(to: userFile)
        defer { try? fm.removeItem(at: root) }

        XCTAssertEqual(
            try CardSource.enumerateRegularFiles(base: root).map(\.relativePath),
            [".fseventsd"]
        )

        var removed = false
        XCTAssertThrowsError(try enumerateTree(base: root) { name in
            guard name == ".fseventsd" else { return }
            try fm.removeItem(at: userFile)
            removed = true
        }) { error in
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
        XCTAssertTrue(removed)
    }

    private func enumerateTree(
        base: URL,
        onRootEntryRead: @escaping (String) throws -> Void
    ) throws -> [CardSource.TreeEntry] {
        let root = base.standardizedFileURL.resolvingSymlinksKeepingCase()
        let fd = root.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(fd) }
        return try CardSource.enumerateTree(
            directoryFD: fd,
            root: root,
            onRootEntryRead: onRootEntryRead
        )
    }

    private func regularPaths(in tree: [CardSource.TreeEntry]) -> [String] {
        tree.filter { $0.kind == .regularFile }.map(\.relativePath)
    }

    private func files(in tree: [CardSource.TreeEntry]) -> [FileEntry] {
        tree.filter { $0.kind == .regularFile }.map {
            FileEntry(
                url: $0.url,
                relativePath: $0.relativePath,
                size: $0.size,
                modificationDate: $0.modificationDate
            )
        }
    }
#endif

    /// An unreadable directory that is NOT known volume metadata must still fail loudly.
    func testUnreadableUserDirectoryStillThrows() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("unreadable-manifest-\(UUID().uuidString)", isDirectory: true)
        let locked = root.appendingPathComponent("PRIVATE", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }

        XCTAssertThrowsError(try CardSource.enumerateRegularFiles(base: root))
    }

    // MARK: - RelativePathResolver

    func testResolverPreservesNestingWhenAnAncestorIsASymlink() throws {
        let fm = FileManager.default
        let real = fm.temporaryDirectory
            .appendingPathComponent("resolver-real-\(UUID().uuidString)", isDirectory: true)
        let link = fm.temporaryDirectory
            .appendingPathComponent("resolver-link-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: real.appendingPathComponent("card/DCIM/100MEDIA"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real.appendingPathComponent("card/DCIM/100MEDIA/A.MOV"))
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? fm.removeItem(at: link); try? fm.removeItem(at: real) }

        // The selected folder is real, but it is reached through a symlinked parent.
        let entries = try CardSource.enumerateRegularFiles(base: link.appendingPathComponent("card"))
        XCTAssertEqual(entries.map(\.relativePath), ["DCIM/100MEDIA/A.MOV"])
    }

    func testResolverAcceptsTrailingSlashAndPrivateAlias() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("resolver-alias-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("DCIM/A.ARW")
        try Data("x".utf8).write(to: file)
        defer { try? fm.removeItem(at: root) }

        // Temp roots live under /var, which macOS reports as /private/var.
        let resolver = RelativePathResolver(base: URL(fileURLWithPath: root.path + "/", isDirectory: true))
        XCTAssertEqual(try resolver.resolve(file), "DCIM/A.ARW")
        XCTAssertEqual(try resolver.resolve(URL(fileURLWithPath: "/private" + file.path)), "DCIM/A.ARW")
    }

    func testResolverThrowsForItemsOutsideTheBase() {
        let resolver = RelativePathResolver(base: URL(fileURLWithPath: "/Volumes/CARD"))
        XCTAssertThrowsError(try resolver.resolve(URL(fileURLWithPath: "/Volumes/CARD2/DCIM/A.ARW")))
        XCTAssertThrowsError(try resolver.resolve(URL(fileURLWithPath: "/Volumes/OTHER/A.ARW")))
    }
}
