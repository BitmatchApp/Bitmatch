import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

final class ASCMHLGeneratorTests: XCTestCase {
    func testC4MatchesOfficialReferenceEmptyDataVector() {
        XCTAssertEqual(ASCMHLGenerator.c4(Data()), "c459dsjfscH38cYeXXYogktxf4Cd9ibshE3BHUo6a58hBXmRQdZrAkZzsWcbWtDg5oQstpDuni4Hirj75GEmTc1sFT")
    }

    func testEmptyInventoryDoesNotPublishHistory() throws {
        let (root, _) = try fixture()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [], startTime: Date(), toolVersion: "test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testSourceOverlapAndAncestorSymlinkCannotPublish() throws {
        let (root, file) = try fixture()
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for source in [root, root.deletingLastPathComponent(), nested] {
            XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), sourceURL: source, toolVersion: "test")) { error in
                guard case ASCMHLGenerator.GenerationError.sourceOverlap = error else {
                    return XCTFail("Expected source overlap, got \(error)")
                }
            }
        }
        let alias = root.deletingLastPathComponent().appendingPathComponent("ascmhl-alias-\(UUID())")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: alias.appendingPathComponent("nested"), files: [file], startTime: Date(), sourceURL: root, toolVersion: "test")) { error in
            guard case ASCMHLGenerator.GenerationError.sourceOverlap = error else {
                return XCTFail("Expected source overlap through alias, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent("ascmhl").path))
    }

    private func fixture() throws -> (URL, ASCMHLGenerator.VerifiedFile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let data = Data("verified media".utf8)
        try data.write(to: root.appendingPathComponent("clip.txt"))
        return (root, .init(relativePath: "clip.txt", size: Int64(data.count), expectedSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    func testChangedDestinationDoesNotPublishHistory() throws {
        let (root, file) = try fixture()
        try Data("corrupt media!".utf8).write(to: root.appendingPathComponent("clip.txt"))
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), toolVersion: "test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testExistingHistoryIsByteForBytePreserved() throws {
        let (root, file) = try fixture()
        let manifest = try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), toolVersion: "test")
        let chain = manifest.deletingLastPathComponent().appendingPathComponent("ascmhl_chain.xml")
        let original = try Data(contentsOf: manifest)
        let originalChain = try Data(contentsOf: chain)
        XCTAssertTrue(String(decoding: original, as: UTF8.self).contains(#"<tool version="test">BitMatch</tool>"#),
                      "the manifest names the app version it was given")
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), toolVersion: "test"))
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        XCTAssertEqual(try Data(contentsOf: chain), originalChain)
    }

    func testNestedHistoryAndUnsafePathsAreRejected() throws {
        let (root, file) = try fixture()
        for path in ["../clip.txt", "/clip.txt", "a/../clip.txt", "ascmhl/clip.txt", "a\\clip.txt"] {
            XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [.init(relativePath: path, size: file.size, expectedSHA256: file.expectedSHA256)], startTime: Date(), toolVersion: "test"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/ascmhl"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), toolVersion: "test"))
    }

    func testSymlinkAndDuplicatePathsAreRejected() throws {
        let (root, file) = try fixture()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file, file], startTime: Date(), toolVersion: "test"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias.txt").path, withDestinationPath: "clip.txt")
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [.init(relativePath: "alias.txt", size: file.size, expectedSHA256: file.expectedSHA256)], startTime: Date(), toolVersion: "test"))
    }

    func testVerifiedReadbackDigestsAvoidMHLDataRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-reuse-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let data = Data((0..<8193).map { UInt8($0 % 251) })
        let source = sourceRoot.appendingPathComponent("clip.bin")
        try data.write(to: source)
        try data.write(to: root.appendingPathComponent("clip.bin"))
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )
        let roundTripped = try JSONDecoder().decode(
            VerificationResult.self,
            from: JSONEncoder().encode(verification)
        )
        XCTAssertNil(roundTripped.destinationDigests)
        XCTAssertNil(roundTripped.destinationReadIdentity)
        let reads = MHLReadProbe()
        let manifest = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [.init(
                relativePath: "clip.bin",
                size: Int64(data.count),
                expectedSHA256: verification.sourceDigests?.sha256 ?? "",
                verifiedSHA256: verification.destinationDigests?.sha256,
                verifiedMD5: verification.destinationDigests?.md5,
                destinationReadIdentity: verification.destinationReadIdentity
            )],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init(
                didOpenForRead: { _ in reads.didOpen() },
                didRead: { _, count in reads.didRead(count) },
                fileSystemType: { "apfs" }
            )
        )
        XCTAssertEqual(reads.opens, 0)
        XCTAssertEqual(reads.bytes, 0)
        let xml = try String(contentsOf: manifest, encoding: .utf8)
        let expectedMD5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(xml.contains(expectedMD5))
    }

    func testReadbackDigestsAreNotReusedWithoutRealChangeTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-exfat-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-exfat-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let data = Data((0..<8193).map { UInt8($0 % 251) })
        let source = sourceRoot.appendingPathComponent("clip.bin")
        try data.write(to: source)
        try data.write(to: root.appendingPathComponent("clip.bin"))
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )
        let reads = MHLReadProbe()

        _ = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [.init(
                relativePath: "clip.bin",
                size: Int64(data.count),
                expectedSHA256: verification.sourceDigests?.sha256 ?? "",
                verifiedSHA256: verification.destinationDigests?.sha256,
                verifiedMD5: verification.destinationDigests?.md5,
                destinationReadIdentity: verification.destinationReadIdentity
            )],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init(
                didOpenForRead: { _ in reads.didOpen() },
                didRead: { _, count in reads.didRead(count) },
                fileSystemType: { "exfat" }
            )
        )

        XCTAssertEqual(reads.opens, 1)
        XCTAssertEqual(reads.bytes, data.count)
    }

    func testMissingReadbackDigestFallsBackToDiskAndTamperStillFails() async throws {
        let (root, file) = try fixture()
        let reads = MHLReadProbe()
        _ = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [file],
            startTime: Date(),
            toolVersion: "test",
            readHooks: .init(
                didOpenForRead: { _ in reads.didOpen() },
                didRead: { _, count in reads.didRead(count) }
            )
        )
        XCTAssertEqual(reads.opens, 1)
        XCTAssertEqual(reads.bytes, Int(file.size))

        let (tamperedRoot, tamperedFile) = try fixture()
        try Data("corrupt media!".utf8).write(to: tamperedRoot.appendingPathComponent("clip.txt"))
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: tamperedRoot,
            files: [tamperedFile],
            startTime: Date(),
            toolVersion: "test",
            readHooks: .init()
        ))
    }

    func testTamperAfterVerificationInvalidatesDigestReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-tamper-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-tamper-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let original = Data("verified bytes".utf8)
        let source = sourceRoot.appendingPathComponent("clip.bin")
        let destination = root.appendingPathComponent("clip.bin")
        try original.write(to: source)
        try original.write(to: destination)
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )
        var corrupted = original
        corrupted[0] ^= 0xff
        try corrupted.write(to: destination)
        let file = ASCMHLGenerator.VerifiedFile(
            relativePath: "clip.bin",
            size: Int64(original.count),
            expectedSHA256: verification.sourceDigests?.sha256 ?? "",
            verifiedSHA256: verification.destinationDigests?.sha256,
            verifiedMD5: verification.destinationDigests?.md5,
            destinationReadIdentity: verification.destinationReadIdentity
        )
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [file],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init()
        )) { error in
            guard case ASCMHLGenerator.GenerationError.changedFile = error else {
                return XCTFail("Expected changedFile, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testReadbackSHA256MustIndependentlyMatchExpectedSHA256() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-independent-sha-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-independent-sha-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let data = Data("verified bytes".utf8)
        let source = sourceRoot.appendingPathComponent("clip.bin")
        try data.write(to: source)
        try data.write(to: root.appendingPathComponent("clip.bin"))
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )
        let file = ASCMHLGenerator.VerifiedFile(
            relativePath: "clip.bin",
            size: Int64(data.count),
            expectedSHA256: String(repeating: "0", count: 64),
            verifiedSHA256: verification.destinationDigests?.sha256,
            verifiedMD5: verification.destinationDigests?.md5,
            destinationReadIdentity: verification.destinationReadIdentity
        )

        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [file],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init()
        )) { error in
            guard case ASCMHLGenerator.GenerationError.changedFile = error else {
                return XCTFail("Expected changedFile, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testTamperWithRestoredModificationTimeCannotReuseDigests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-restored-mtime-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-restored-mtime-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let original = Data("verified bytes".utf8)
        let source = sourceRoot.appendingPathComponent("clip.bin")
        let destination = root.appendingPathComponent("clip.bin")
        try original.write(to: source)
        try original.write(to: destination)
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )

        var before = stat()
        XCTAssertEqual(lstat(destination.path, &before), 0)
        var corrupted = original
        corrupted[0] ^= 0xff
        try corrupted.write(to: destination)
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, destination.path, &times, 0), 0)
        var after = stat()
        XCTAssertEqual(lstat(destination.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        XCTAssertTrue(
            after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
                || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec
        )

        let file = ASCMHLGenerator.VerifiedFile(
            relativePath: "clip.bin",
            size: Int64(original.count),
            expectedSHA256: verification.sourceDigests?.sha256 ?? "",
            verifiedSHA256: verification.destinationDigests?.sha256,
            verifiedMD5: verification.destinationDigests?.md5,
            destinationReadIdentity: verification.destinationReadIdentity
        )
        let reads = MHLReadProbe()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [file],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init(
                didOpenForRead: { _ in reads.didOpen() },
                didRead: { _, count in reads.didRead(count) }
            )
        )) { error in
            guard case ASCMHLGenerator.GenerationError.changedFile = error else {
                return XCTFail("Expected changedFile, got \(error)")
            }
        }
        XCTAssertEqual(reads.opens, 1)
        XCTAssertEqual(reads.bytes, original.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }
}

private final class MHLReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var openCount = 0
    private var byteCount = 0

    var opens: Int { lock.withLock { openCount } }
    var bytes: Int { lock.withLock { byteCount } }
    func didOpen() { lock.withLock { openCount += 1 } }
    func didRead(_ count: Int) { lock.withLock { byteCount += count } }
}
