// SafetyValidatorTests.swift
import XCTest
@testable import BitMatch
import BitMatchEngine

final class SafetyValidatorTests: XCTestCase {

    /// The same folder written as /private/var/... and /var/... is one
    /// folder. Standardizing dropped "/private" only when the rest of the
    /// path existed, so a backup inside the source could go unnoticed.
    /// Plant: in `SafetyValidator.pathIsWithin`, compare
    /// `URL(fileURLWithPath:).standardizedFileURL.pathComponents` directly again.
    func testBackupInsideSourceIsFoundAcrossPrivateAlias() {
        let base = "var/folders/bitmatch_alias_\(UUID().uuidString)/CARD"
        let source = URL(fileURLWithPath: "/private/" + base, isDirectory: true)
        let inside = URL(fileURLWithPath: "/" + base + "/Backup", isDirectory: true)
        XCTAssertEqual(SafetyValidator.destinationSafetyIssue(source: source, destination: inside),
                       "Destination is inside the source folder")
        XCTAssertTrue(SafetyValidator.isProtectedSystemPath(URL(fileURLWithPath: "/private/etc", isDirectory: true)))
    }

    func testAvailableSpaceFallsBackWhenImportantUsageCapacityIsUnavailable() {
        XCTAssertEqual(
            SafetyValidator.resolvedAvailableSpace(
                importantUsage: nil,
                standardCapacity: 2_000_000_000
            ),
            2_000_000_000
        )
        XCTAssertEqual(
            SafetyValidator.resolvedAvailableSpace(
                importantUsage: 1_500_000_000,
                standardCapacity: 2_000_000_000
            ),
            1_500_000_000
        )
    }

    /// exFAT/FAT volumes report `volumeAvailableCapacityForImportantUsage` as 0 (not nil),
    /// so a zero must fall back to the standard capacity. See GitHub issue: "Insufficient space: 0.0GB available".
    func testAvailableSpaceFallsBackWhenImportantUsageCapacityIsZero() {
        XCTAssertEqual(
            SafetyValidator.resolvedAvailableSpace(
                importantUsage: 0,
                standardCapacity: 2_000_000_000
            ),
            2_000_000_000
        )
    }

    // MARK: - System Directory Rejection

    func testRejectsSystemDirectories() {
        let systemPaths = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/var"]
        for path in systemPaths {
            let url = URL(fileURLWithPath: path)
            XCTAssertTrue(SafetyValidator.isProtectedSystemPath(url), "Should reject system path: \(path)")
        }
    }

    func testRejectsSystemSubdirectories() {
        let url = URL(fileURLWithPath: "/System/Library/Frameworks")
        XCTAssertTrue(SafetyValidator.isProtectedSystemPath(url))
    }

    func testAllowsUserDirectories() {
        // Not "/tmp/test": /tmp is /private/tmp, a system folder; only the
        // app's own temporary folder is exempt.
        let safePaths = ["/Users/test", "/Volumes/External"]
        for path in safePaths {
            let url = URL(fileURLWithPath: path)
            XCTAssertFalse(SafetyValidator.isProtectedSystemPath(url), "Should allow path: \(path)")
        }
    }

    // MARK: - Path Traversal

    func testRejectsPathTraversal() {
        let maliciousPaths = [
            "/Users/test/../../../etc/passwd",
            "/Volumes/Card/../../System",
            "/tmp/safe/../../private"
        ]
        for path in maliciousPaths {
            XCTAssertTrue(
                SafetyValidator.isProtectedSystemPath(URL(fileURLWithPath: path)),
                "Path traversal should be caught: \(path)"
            )
        }
    }

    // MARK: - Symlink Loop Detection

    func testComparisonRejectsSymlinkCycle() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let real = tmp.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let a = tmp.appendingPathComponent("a")
        let b = tmp.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)

        do {
            try await SafetyValidator.performComparisonChecks(left: a, right: real)
            XCTFail("expected a symlinkLoop error for a symlink cycle")
        } catch {
            XCTAssertTrue(error is FileOperationError, "unexpected error: \(error)")
        }
    }

    func testFirstSymlinkComponentFindsAncestorLink() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let real = tmp.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertEqual(SafetyValidator.firstSymlinkComponent(in: link), link.path)
        XCTAssertEqual(
            SafetyValidator.firstSymlinkComponent(in: link.appendingPathComponent("nested.txt")),
            link.path
        )
        XCTAssertNil(SafetyValidator.firstSymlinkComponent(in: real))
        // Fixed /private aliases (/tmp, /var, /etc) are tolerated.
        XCTAssertNil(SafetyValidator.firstSymlinkComponent(in: tmp))
        XCTAssertNil(
            SafetyValidator.firstSymlinkComponent(in: URL(fileURLWithPath: "/tmp/bitmatch-nonexistent-\(UUID().uuidString)"))
        )
    }

    func testComparisonAllowsAcyclicSymlinks() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let real = tmp.appendingPathComponent("real")
        let other = tmp.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try await SafetyValidator.performComparisonChecks(left: link, right: other)
    }

    // MARK: - Symlink Handling

    func testSymlinkResolution() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let target = tempDir.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // Symlink to safe directory should be allowed
        let resolved = link.resolvingSymlinksInPath()
        XCTAssertFalse(SafetyValidator.isProtectedSystemPath(resolved))
    }

    // MARK: - Transfer Safety

    func testSafetyChecksRejectDestinationInsideSource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let destination = source.appendingPathComponent("Backup")

        await assertThrowsFileOperationError(expectedMessage: "Destination is inside the source folder") {
            try await SafetyValidator.performSafetyChecks(
                source: source,
                destinations: [destination],
                sourceSizeBytes: 0
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSafetyChecksRejectDestinationContainingSource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        await assertThrowsFileOperationError(expectedMessage: "Destination contains the source folder") {
            try await SafetyValidator.performSafetyChecks(
                source: source,
                destinations: [root],
                sourceSizeBytes: 0
            )
        }
    }

    func testSafetyChecksRejectDuplicateDestinations() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await assertThrowsFileOperationError(expectedMessage: "Destination folders must be unique") {
            try await SafetyValidator.performSafetyChecks(
                source: source,
                destinations: [destination, destination],
                sourceSizeBytes: 0
            )
        }
    }

    func testSafetyChecksUseSuppliedSourceSizeInsteadOfEnumeratingBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("tiny".utf8).write(to: source.appendingPathComponent("tiny.txt"))

        let suppliedSourceBytes: Int64 = 1_000_000_000_000_000
        do {
            try await SafetyValidator.performSafetyChecks(
                source: source,
                destinations: [destination],
                sourceSizeBytes: suppliedSourceBytes
            )
            XCTFail("Expected supplied source size to exceed available space")
        } catch FileOperationError.insufficientSpace(_, _, let requiredGB) {
            XCTAssertGreaterThan(requiredGB, Double(suppliedSourceBytes) / 1_000_000_000)
        } catch {
            XCTFail("Expected FileOperationError.insufficientSpace, got \(error)")
        }
    }

    func testSafetyChecksHeadroomOverflowThrowsTypedError() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Source")
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        await assertThrowsFileOperationError(expectedMessage: "Source size exceeds the supported range") {
            try await SafetyValidator.performSafetyChecks(
                source: source,
                destinations: [destination],
                sourceSizeBytes: .max
            )
        }
    }

    func testPortableRelativePathValidationRejectsCaseOnlyCollisions() {
        XCTAssertThrowsError(try SafetyValidator.validatePortableRelativePaths([
            "A001/clip.mov",
            "a001/CLIP.mov"
        ])) { error in
            guard case FileOperationError.unsafeOperation(let message) = error else {
                return XCTFail("Expected unsafeOperation, got \(error)")
            }
            XCTAssertTrue(message.contains("differ only by case or Unicode form"))
        }
    }

    func testPortableRelativePathValidationRejectsUnsafeComponents() {
        XCTAssertThrowsError(try SafetyValidator.validatePortableRelativePaths([
            "A001/../clip.mov"
        ])) { error in
            guard case FileOperationError.unsafeOperation(let message) = error else {
                return XCTFail("Expected unsafeOperation, got \(error)")
            }
            XCTAssertTrue(message.contains("unsafe relative path"))
        }
    }

    // MARK: - Preflight/Manifest Alignment

    /// Preflight must validate the same file set the copy manifest uses. Root-level
    /// volume metadata is skipped by both, so unreadable or oddly named metadata
    /// can no longer abort a transfer the copy would have completed.
    func testSourceTreeValidationSkipsRootVolumeMetadataLikeCopyManifest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let source = root.appendingPathComponent("Card")
        try fm.createDirectory(at: source.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: source.appendingPathComponent("DCIM/clip.mov"))

        // Root metadata with a case-only collision the copy manifest never sees.
        // (On a case-insensitive volume the pair merges and the no-throw half is
        // trivial; the manifest-exclusion half below holds everywhere.)
        let metadata = source.appendingPathComponent(".Spotlight-V100")
        try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: metadata.appendingPathComponent("A.MOV"))
        try Data("x".utf8).write(to: metadata.appendingPathComponent("a.mov"))

        XCTAssertNoThrow(try SafetyValidator.validateSourceTreeForCopy(source: source))
        let manifest = try CardSource.enumerateRegularFiles(base: source)
        XCTAssertEqual(manifest.map(\.relativePath), ["DCIM/clip.mov"])
    }

    /// The metadata skip is root-only: a same-named folder deeper in the tree is
    /// real data, kept in the manifest, and still validated by preflight.
    func testSourceTreeValidationStillChecksNestedMetadataNames() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let source = root.appendingPathComponent("Card")
        let nested = source.appendingPathComponent("Nested/.Spotlight-V100")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("B.MOV"))
        try Data("x".utf8).write(to: nested.appendingPathComponent("b.mov"))
        let stored = try fm.contentsOfDirectory(atPath: nested.path)

        // Nested metadata is real data on both paths, regardless of filesystem.
        let manifest = try CardSource.enumerateRegularFiles(base: source)
        XCTAssertEqual(Set(manifest.map(\.relativePath)), Set(stored.map { "Nested/.Spotlight-V100/\($0)" }))

        // A case-only collision needs a filesystem that keeps both names; the
        // default macOS volume merges them into one file.
        guard stored.count == 2 else {
            throw XCTSkip("Requires a case-sensitive filesystem to hold a case-only collision")
        }
        XCTAssertThrowsError(try SafetyValidator.validateSourceTreeForCopy(source: source)) { error in
            guard case FileOperationError.unsafeOperation(let message) = error else {
                return XCTFail("Expected unsafeOperation, got \(error)")
            }
            XCTAssertTrue(message.contains("collide on case-insensitive filesystems"))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assertThrowsFileOperationError(
        expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected FileOperationError.unsafeOperation", file: file, line: line)
        } catch FileOperationError.unsafeOperation(let message) {
            XCTAssertEqual(message, expectedMessage, file: file, line: line)
        } catch {
            XCTFail("Expected FileOperationError.unsafeOperation, got \(error)", file: file, line: line)
        }
    }
}
