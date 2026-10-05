// ExFATDestinationTests.swift
// exFAT has no hard links and no RENAME_EXCL, so the linkat no-replace
// publish failed every file on exFAT backups (errno 45) in 0.1.4 through
// 0.1.6. These tests mount a real exFAT disk image: APFS cannot reproduce
// it, and macOS's exFAT driver also reports a temporary inode for a new
// file until it is fsynced.
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

final class ExFATDestinationTests: XCTestCase {
    private var image: URL!
    private var mountPoint: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch_exfat_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        image = root.appendingPathComponent("backup")
        mountPoint = root.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        guard hdiutil(["create", "-quiet", "-size", "3g", "-type", "SPARSE", "-fs", "ExFAT", "-volname", "BMEXFAT", "-o", image.path]) == 0,
              hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, image.path + ".sparseimage"]) == 0 else {
            throw XCTSkip("hdiutil could not create or mount an exFAT image")
        }
    }

    override func tearDown() {
        if let mountPoint { _ = hdiutil(["detach", "-quiet", "-force", mountPoint.path]) }
        if let image { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
    }

    private func hdiutil(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return fd
    }

    private func writeTemporary(_ contents: String, named name: String, in parentFD: Int32) throws {
        let fd = try PinnedDestinationDirectory.createTemporaryFile(named: name, relativeTo: parentFD)
        defer { _ = Darwin.close(fd) }
        let data = Array(contents.utf8)
        XCTAssertEqual(Darwin.write(fd, data, data.count), data.count)
        XCTAssertEqual(fsync(fd), 0)
    }

    /// Fails if `PinnedDestinationDirectory.publishTemporaryFile` loses its fallback for filesystems
    /// without hard links (only `linkat`, as in 0.1.4-0.1.6).
    func testPublishOnExFATGivesTheFileItsName() throws {
        let parentFD = try openDirectory(mountPoint)
        defer { _ = Darwin.close(parentFD) }
        try writeTemporary("clip", named: ".bitmatch.tmp.a", in: parentFD)

        try PinnedDestinationDirectory.publishTemporaryFile(named: ".bitmatch.tmp.a", as: "A001C001.MXF", relativeTo: parentFD)

        let published = mountPoint.appendingPathComponent("A001C001.MXF")
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "clip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent(".bitmatch.tmp.a").path))
    }

    /// Promise 1: the fallback must still never replace an existing file.
    /// Fails if the fallback renames over the name without claiming it
    /// exclusively first.
    func testPublishOnExFATRefusesToReplaceAnExistingFile() throws {
        let parentFD = try openDirectory(mountPoint)
        defer { _ = Darwin.close(parentFD) }
        let existing = mountPoint.appendingPathComponent("A001C001.MXF")
        try Data("someone else's".utf8).write(to: existing)
        try writeTemporary("clip", named: ".bitmatch.tmp.b", in: parentFD)

        XCTAssertThrowsError(try PinnedDestinationDirectory.publishTemporaryFile(named: ".bitmatch.tmp.b", as: "A001C001.MXF", relativeTo: parentFD))

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "someone else's")
    }

    /// The fallback itself must refuse a file that appeared at the name
    /// (linkat reports EEXIST first when one is already there, so the test
    /// above does not reach the fallback). Fails if `publishByClaimingName`
    /// renames without claiming the name exclusively first.
    func testClaimFallbackRefusesToReplaceAFileThatAppeared() throws {
        let parentFD = try openDirectory(mountPoint)
        defer { _ = Darwin.close(parentFD) }
        let existing = mountPoint.appendingPathComponent("A001C002.MXF")
        try Data("appeared meanwhile".utf8).write(to: existing)
        try writeTemporary("clip", named: ".bitmatch.tmp.c", in: parentFD)

        XCTAssertThrowsError(try PinnedDestinationDirectory.publishByClaimingName(temporaryName: ".bitmatch.tmp.c", name: "A001C002.MXF", relativeTo: parentFD))

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "appeared meanwhile")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent(".bitmatch.tmp.c").path))
    }

    /// End to end: a transfer to an exFAT backup verifies every file.
    func testTransferToExFATBackupVerifiesEveryFile() async throws {
        let fixture = try DisposableTransferFixture(seed: 20_260_925, fileCount: 3, bytesPerFile: 16 * 1024)
        defer { fixture.cleanup() }
        let destination = mountPoint.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let operation = try await TransferPipeline(
            fileSystem: LocalFileAccess(),
            checksum: ChecksumEngine.shared
        ).performFileOperation(
            sourceURL: fixture.source,
            destinationURLs: [destination],
            verificationMode: .standard,
            settings: CameraLabelSettings(),
            estimatedTotalBytes: nil,
            progressCallback: { _ in },
            onFileResult: nil
        )

        XCTAssertEqual(operation.results.count, fixture.manifest.count)
        for result in operation.results {
            XCTAssertTrue(result.success, "\(result.destinationURL.lastPathComponent): \(String(describing: result.error))")
            XCTAssertEqual(result.verificationResult?.isValid, true)
        }
    }
    /// Real exFAT AppleDouble files generated by differing quarantine attributes.
    /// Plant: bypass existing companion checksum validation; refusal assertions fail.
    func testDifferentAutoGeneratedCompanionNeverOverwritesOrMakesTransferSafe() async throws {
        let fm = FileManager.default
        let source = image.deletingLastPathComponent().appendingPathComponent("Card")
        let seed = mountPoint.appendingPathComponent("Seed")
        let backup = mountPoint.appendingPathComponent("Backup")
        let output = backup.appendingPathComponent("Card")
        for directory in [source, seed, output] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let bytes = Data("unchanged media".utf8)
        for directory in [source, seed, output] { try bytes.write(to: directory.appendingPathComponent("clip.bin")) }
        func quarantine(_ file: URL, value: String) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            process.arguments = ["-w", "com.apple.quarantine", value, file.path]
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        try quarantine(seed.appendingPathComponent("clip.bin"), value: "0081;00000001;FixtureSource;")
        try quarantine(output.appendingPathComponent("clip.bin"), value: "0081;00000002;FixtureDestination;")
        let sourceCompanion = try Data(contentsOf: seed.appendingPathComponent("._clip.bin"))
        let originalDestinationCompanion = try Data(contentsOf: output.appendingPathComponent("._clip.bin"))
        XCTAssertNotEqual(sourceCompanion, originalDestinationCompanion)
        try sourceCompanion.write(to: source.appendingPathComponent("._clip.bin"))
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .performFileOperation(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                  settings: CameraLabelSettings(), progressCallback: { _ in }, onFileResult: nil)
        XCTAssertEqual(operation.results.count, 2)
        let media = try XCTUnwrap(operation.results.first { $0.sourceURL.lastPathComponent == "clip.bin" })
        let companion = try XCTUnwrap(operation.results.first { $0.sourceURL.lastPathComponent == "._clip.bin" })
        XCTAssertEqual(media.outcome, .verified)
        XCTAssertEqual(companion.outcome, .failed)
        let verdict = TransferCompletion.verdict(
            rows: TransferCompletion.rows(from: operation),
            sourceFiles: [source.appendingPathComponent("clip.bin"), source.appendingPathComponent("._clip.bin")],
            destinations: [backup], source: source, settings: CameraLabelSettings(), mode: .standard,
            generateASCMHL: false, handoffIssues: [], reportIssue: nil,
            project: .init(didPersist: true, locallySafe: nil))
        XCTAssertFalse(verdict.success)
        XCTAssertTrue(companion.error?.localizedDescription.contains("hidden companion") == true)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("._clip.bin")), originalDestinationCompanion)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("._clip.bin")), sourceCompanion)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), bytes)
    }

}
