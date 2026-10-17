// ExFATDestinationTests.swift
// exFAT has no hard links and no RENAME_EXCL. These tests mount a real exFAT
// image to exercise the visible, durable marker and direct final-file path.
// macOS's exFAT driver reports a temporary inode until a file is fsynced.
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
        var info = statfs()
        XCTAssertEqual(statfs(mountPoint.path, &info), 0)
        let actual = withUnsafeBytes(of: info.f_fstypename) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        print("EXFAT_DESTINATION mounted f_fstypename=\(actual)")
        XCTAssertEqual(actual.lowercased(), "exfat")
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

    /// The visible warning is durable before a final media name is opened.
    func testDirectFinalFileOnExFATHasDurableMarker() throws {
        let parentFD = try openDirectory(mountPoint)
        defer { _ = Darwin.close(parentFD) }
        let marker = try TransferStatusMarker.create(rootFD: parentFD, attemptID: UUID(), sourcePaths: ["A001C001.MXF"])
        XCTAssertEqual(try marker.currentStatus(), .incomplete)
        let markerFD = Darwin.open(mountPoint.appendingPathComponent(marker.name).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(markerFD, 0)
        if markerFD >= 0 {
            defer { _ = Darwin.close(markerFD) }
            let fullSync = fcntl(markerFD, F_FULLFSYNC)
            let fullError = fullSync == 0 ? 0 : errno
            let fileSync = fsync(markerFD)
            let fileError = fileSync == 0 ? 0 : errno
            let rootSync = fsync(parentFD)
            let rootError = rootSync == 0 ? 0 : errno
            print("EXFAT_DESTINATION marker F_FULLFSYNC rc=\(fullSync) errno=\(fullError); marker fsync rc=\(fileSync) errno=\(fileError); root fsync rc=\(rootSync) errno=\(rootError)")
            XCTAssertEqual(fileSync, 0)
            XCTAssertEqual(rootSync, 0)
        }
        let fd = try PinnedDestinationDirectory.createDirectFinalFile(named: "A001C001.MXF", relativeTo: parentFD)
        defer { _ = Darwin.close(fd) }
        let bytes = Data("clip".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, bytes.count)
        try PinnedDestinationDirectory.flushToMedium(fd)
        try PinnedDestinationDirectory.synchronizeDirectory(parentFD)

        let published = mountPoint.appendingPathComponent("A001C001.MXF")
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "clip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent(marker.name).path))
    }

    /// Promise 1: O_EXCL refuses an existing destination file.
    func testDirectFinalOnExFATRefusesToReplaceAnExistingFile() throws {
        let parentFD = try openDirectory(mountPoint)
        defer { _ = Darwin.close(parentFD) }
        let existing = mountPoint.appendingPathComponent("A001C001.MXF")
        try Data("someone else's".utf8).write(to: existing)
        _ = try TransferStatusMarker.create(rootFD: parentFD, attemptID: UUID(), sourcePaths: ["A001C001.MXF"])
        XCTAssertThrowsError(try PinnedDestinationDirectory.createDirectFinalFile(named: "A001C001.MXF", relativeTo: parentFD))

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "someone else's")
    }

    /// Unknown filesystems without links cannot take the old claim path.
    func testTemporaryPublicationOnExFATFailsClosedWithoutClaimOrRename() throws {
        let parentFD = try openDirectory(mountPoint)
        defer { _ = Darwin.close(parentFD) }
        let existing = mountPoint.appendingPathComponent("A001C002.MXF")
        try writeTemporary("clip", named: ".bitmatch.tmp.c", in: parentFD)
        XCTAssertThrowsError(try PinnedDestinationDirectory.publishTemporaryFile(
            named: ".bitmatch.tmp.c", as: "A001C002.MXF", relativeTo: parentFD
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: existing.path))
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
