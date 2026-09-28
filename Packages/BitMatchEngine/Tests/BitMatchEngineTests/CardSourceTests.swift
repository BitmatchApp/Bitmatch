import XCTest
@testable import BitMatchEngine

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
