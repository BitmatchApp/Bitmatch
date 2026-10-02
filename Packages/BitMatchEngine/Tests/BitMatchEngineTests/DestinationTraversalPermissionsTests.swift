#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

final class DestinationTraversalPermissionsTests: XCTestCase {
    func testSelectedFolderBelowSearchOnlyAncestorCanBePinned() throws {
        guard geteuid() != 0 else { throw XCTSkip("Requires unprivileged directory permissions") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("destination-search-\(UUID())")
        let ancestor = root.appendingPathComponent("search-only")
        let selected = ancestor.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        defer {
            _ = chmod(ancestor.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(chmod(ancestor.path, 0o111), 0)
        let listingFD = Darwin.open(ancestor.path, O_RDONLY | O_DIRECTORY)
        if listingFD >= 0 { _ = Darwin.close(listingFD); return XCTFail("Fixture must deny directory listing") }
        XCTAssertEqual(errno, EACCES)
        let pinned = try PinnedDestinationDirectory.open(destination: selected, rootComponents: ["Card"])
        XCTAssertTrue(pinned.logicalRootStillMatchesPinnedDirectory())
        let fd = try pinned.openOrCreateDirectory(at: ["DCIM"])
        _ = Darwin.close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.appendingPathComponent("Card/DCIM").path))
    }
}
#endif
