#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

/// Deterministic boundaries that lost another writer's bytes under the old
/// empty-claim/rename fallback. All paths are inside a disposable directory.
final class ClaimedNamePublicationRaceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-publication-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let scratch { try FileManager.default.removeItem(at: scratch) }
    }

    private func openScratchDirectory() throws -> Int32 {
        let fd = Darwin.open(scratch.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return fd
    }

    private func replaceNameWithOtherWriterFile(named name: String, bytes: Data, relativeTo parentFD: Int32) {
        XCTAssertEqual(name.withCString { unlinkat(parentFD, $0, 0) }, 0)
        let fd = name.withCString {
            openat(parentFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, bytes.count)
        XCTAssertEqual(fsync(fd), 0)
    }

    func testOtherWriterReplacingFinalNameBeforeCompletionIsNeitherOverwrittenNorDeleted() throws {
        let parentFD = try openScratchDirectory()
        defer { _ = Darwin.close(parentFD) }
        let marker = try TransferStatusMarker.create(rootFD: parentFD, attemptID: UUID(), sourcePaths: ["clip.mov"])
        XCTAssertEqual(try marker.currentStatus(), .incomplete)
        let finalName = "clip.mov"
        let otherBytes = Data("another writer's file".utf8)
        let copiedBytes = Data("original copy".utf8)
        let fd = try PinnedDestinationDirectory.createDirectFinalFile(named: finalName, relativeTo: parentFD)
        defer { _ = Darwin.close(fd) }

        // Former boundary: another writer replaced the empty claim after the
        // identity check and before renameat. Direct writes stay on our FD.
        replaceNameWithOtherWriterFile(named: finalName, bytes: otherBytes, relativeTo: parentFD)
        XCTAssertEqual(copiedBytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, copiedBytes.count)
        XCTAssertThrowsError(try PinnedDestinationDirectory.namedFileMatchesOpenFile(fd, named: finalName, relativeTo: parentFD))
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent(finalName)), otherBytes)
        XCTAssertEqual(try marker.currentStatus(), .incomplete)
    }

    func testFailureCleanupNeverUnlinksOtherWritersReplacement() throws {
        let parentFD = try openScratchDirectory()
        defer { _ = Darwin.close(parentFD) }
        let marker = try TransferStatusMarker.create(rootFD: parentFD, attemptID: UUID(), sourcePaths: ["clip.mov"])
        let finalName = "clip.mov"
        let otherBytes = Data("another writer's file".utf8)
        let fd = try PinnedDestinationDirectory.createDirectFinalFile(named: finalName, relativeTo: parentFD)
        replaceNameWithOtherWriterFile(named: finalName, bytes: otherBytes, relativeTo: parentFD)

        // Former boundary: an error after the claim check ran pathname-based
        // cleanup. The direct file owns only a descriptor and is never unlinked.
        _ = Darwin.close(fd)
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent(finalName)), otherBytes)
        XCTAssertEqual(try marker.currentStatus(), .incomplete)
    }

    func testMarkerNameCollisionIgnoresCaseAndSourceFileRemainsData() throws {
        let parentFD = try openScratchDirectory()
        defer { _ = Darwin.close(parentFD) }
        let collisionID = UUID()
        let existing = "BITMATCH_TRANSFER_STATUS_\(collisionID.uuidString).txt"
        let source = scratch.appendingPathComponent("SOURCE", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("source data".utf8).write(to: source.appendingPathComponent(existing))
        let marker = try TransferStatusMarker.create(rootFD: parentFD, attemptID: UUID(),
                                                     sourcePaths: [existing.lowercased()], firstCandidateID: collisionID)
        XCTAssertNotEqual(marker.name.lowercased(), existing.lowercased())
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(existing).path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(existing)), Data("source data".utf8))
    }

    func testTornMarkerCannotAuthorizeVerifiedStatus() throws {
        let parentFD = try openScratchDirectory()
        defer { _ = Darwin.close(parentFD) }
        let marker = try TransferStatusMarker.create(rootFD: parentFD, attemptID: UUID(), sourcePaths: [])
        let statusURL = scratch.appendingPathComponent(marker.name)
        XCTAssertEqual(TransferStatusMarker.validatedStatus(at: statusURL, relativePath: marker.name), .incomplete)
        try marker.append(.filesVerified)
        XCTAssertEqual(TransferStatusMarker.validatedStatus(at: statusURL, relativePath: marker.name), .filesVerified)
        let fd = Darwin.open(statusURL.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        let torn = Data("X".utf8)
        XCTAssertEqual(torn.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, 1)
        _ = Darwin.close(fd)
        XCTAssertNil(TransferStatusMarker.validatedStatus(at: statusURL, relativePath: marker.name))
        XCTAssertThrowsError(try marker.currentStatus())
    }
}
#endif
