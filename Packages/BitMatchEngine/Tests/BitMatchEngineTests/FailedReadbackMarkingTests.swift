import Foundation
import XCTest
@testable import BitMatchEngine

/// Failed-readback marking: the exact file that failed may be renamed to
/// `<name>.bitmatch-failed`; every other byte on disk stays untouched.
final class FailedReadbackMarkingTests: XCTestCase {
    private func fixture() throws -> (root: URL, pinned: PinnedDestinationDirectory) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-failed-marking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try PinnedDestinationDirectory.open(destination: root, rootComponents: []))
    }

    private func write(_ url: URL, _ text: String) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func testMatchingIdentityIsMarkedAndBytesSurvive() throws {
        let (root, pinned) = try fixture()
        let file = root.appendingPathComponent("clip.mov")
        try write(file, "verified-bad-bytes")
        let identity = try XCTUnwrap(try pinned.currentRegularFileIdentity(at: "clip.mov"))

        let outcome = try pinned.markFailedReadbackOutput(at: "clip.mov", expectedIdentity: identity)

        XCTAssertEqual(outcome, .marked(toRelativePath: "clip.mov.bitmatch-failed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("clip.mov.bitmatch-failed"), encoding: .utf8),
                       "verified-bad-bytes")
    }

    func testNestedPathIsMarkedWithinItsDirectory() throws {
        let (root, pinned) = try fixture()
        let nested = root.appendingPathComponent("Reel A", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let file = nested.appendingPathComponent("clip.mov")
        try write(file, "bad")
        let identity = try XCTUnwrap(try pinned.currentRegularFileIdentity(at: "Reel A/clip.mov"))

        let outcome = try pinned.markFailedReadbackOutput(at: "Reel A/clip.mov", expectedIdentity: identity)

        XCTAssertEqual(outcome, .marked(toRelativePath: "Reel A/clip.mov.bitmatch-failed"))
        XCTAssertEqual(try String(contentsOf: nested.appendingPathComponent("clip.mov.bitmatch-failed"), encoding: .utf8), "bad")
    }

    /// Plant: replace the failed file with another writer's bytes before
    /// marking. The replacement must survive untouched at the final name.
    func testReplacedFileIsNeverMarked() throws {
        let (root, pinned) = try fixture()
        let file = root.appendingPathComponent("clip.mov")
        try write(file, "our-failed-bytes")
        let identity = try XCTUnwrap(try pinned.currentRegularFileIdentity(at: "clip.mov"))
        try write(file, "other-writer-bytes!")

        let outcome = try pinned.markFailedReadbackOutput(at: "clip.mov", expectedIdentity: identity)

        XCTAssertEqual(outcome, .identityChanged)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "other-writer-bytes!")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".bitmatch-failed"))
    }

    func testOccupiedMarkedNameLeavesFailedFileInPlace() throws {
        let (root, pinned) = try fixture()
        let file = root.appendingPathComponent("clip.mov")
        try write(file, "failed")
        try write(root.appendingPathComponent("clip.mov.bitmatch-failed"), "previous-mark")
        let identity = try XCTUnwrap(try pinned.currentRegularFileIdentity(at: "clip.mov"))

        let outcome = try pinned.markFailedReadbackOutput(at: "clip.mov", expectedIdentity: identity)

        XCTAssertEqual(outcome, .markedNameOccupied)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "failed")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("clip.mov.bitmatch-failed"), encoding: .utf8),
                       "previous-mark")
    }

    /// Rows persisted before marking existed have no marking field; they
    /// must still decode, with marking absent.
    func testResultRowWithoutMarkingFieldDecodes() throws {
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","path":"/card/clip.mov","status":"⚠️ Checksum Mismatch","size":4}"#
        let row = try JSONDecoder().decode(ResultRow.self, from: Data(legacy.utf8))
        XCTAssertNil(row.failedOutputMarking)
        let marked = ResultRow(path: "/card/clip.mov", status: ResultOutcome.checksumMismatch.statusText,
                               size: 4, checksum: nil, destination: "Backup", failedOutputMarking: "nameOccupied")
        let decoded = try JSONDecoder().decode(ResultRow.self, from: JSONEncoder().encode(marked))
        XCTAssertEqual(decoded.failedOutputMarking, "nameOccupied")
    }

    func testMissingFileReportsMissing() throws {
        let (_, pinned) = try fixture()
        let identity = VerifiedFileIdentity(device: 1, inode: 2, size: 3, modificationSeconds: 4,
                                            modificationNanoseconds: 5, changeSeconds: 6, changeNanoseconds: 7)
        XCTAssertEqual(try pinned.markFailedReadbackOutput(at: "gone.mov", expectedIdentity: identity), .missing)
    }
}
