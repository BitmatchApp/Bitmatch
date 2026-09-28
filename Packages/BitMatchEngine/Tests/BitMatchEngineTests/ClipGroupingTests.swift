import Foundation
import XCTest
@testable import BitMatchEngine

final class ClipGroupingTests: XCTestCase {
    func testGenericSidecarsWithSameStemJoinClip() throws {
        let files = urls("/Card/DCIM/C0001.MP4", "/Card/DCIM/C0001.XMP", "/Card/DCIM/C0001.THM", "/Card/DCIM/C0002.XML")
        let group = try XCTUnwrap(ClipGrouping.group(containing: files[0], among: files))

        XCTAssertEqual(group.name, "C0001")
        XCTAssertEqual(group.files.map(\.lastPathComponent), ["C0001.MP4", "C0001.THM", "C0001.XMP"])
    }

    func testM01XMLJoinsMediaStem() throws {
        let files = urls("/Card/PRIVATE/C0001.MP4", "/Card/PRIVATE/C0001M01.XML", "/Card/PRIVATE/C0001M02.XML")
        let group = try XCTUnwrap(ClipGrouping.group(containing: files[0], among: files))

        XCTAssertEqual(group.name, "C0001")
        XCTAssertEqual(group.files.map(\.lastPathComponent), ["C0001.MP4", "C0001M01.XML"])
    }

    func testM01SidecarCanIdentifyItsMediaClip() throws {
        let files = urls("/Card/PRIVATE/C0001.MP4", "/Card/PRIVATE/C0001M01.XML")
        let group = try XCTUnwrap(ClipGrouping.group(containing: files[1], among: files))

        XCTAssertEqual(group.name, "C0001")
        XCTAssertEqual(group.files.map(\.lastPathComponent), ["C0001.MP4", "C0001M01.XML"])
    }

    func testMatchingIsCaseInsensitiveButDoesNotCrossFolders() throws {
        let files = urls("/Card/A/C0001.mp4", "/Card/A/c0001.lrv", "/Card/B/C0001.XML")
        let group = try XCTUnwrap(ClipGrouping.group(containing: files[0], among: files))

        XCTAssertEqual(group.files.map(\.lastPathComponent), ["c0001.lrv", "C0001.mp4"])
    }

    func testUnrecognizedExtensionIsNotAClipSidecar() throws {
        let files = urls("/Card/C0001.MP4", "/Card/C0001.txt")
        let group = try XCTUnwrap(ClipGrouping.group(containing: files[0], among: files))

        XCTAssertEqual(group.files.map(\.lastPathComponent), ["C0001.MP4"])
    }

    func testDifferentMediaFilesWithSameStemDoNotMerge() throws {
        let files = urls("/Card/C0001.MP4", "/Card/C0001.MOV", "/Card/C0001.XML")
        let group = try XCTUnwrap(ClipGrouping.group(containing: files[0], among: files))

        XCTAssertEqual(group.files.map(\.lastPathComponent), ["C0001.MP4", "C0001.XML"])
    }

    func testAppleDoubleFilesAreExcludedFromClipAndSidecarGroups() throws {
        let files = urls("/Card/C0001.MP4", "/Card/._C0001.MP4", "/Card/C0001.XMP")
        let group = try XCTUnwrap(ClipGrouping.group(containing: files[0], among: files))

        XCTAssertEqual(group.files.map(\.lastPathComponent), ["C0001.MP4", "C0001.XMP"])
        XCTAssertNil(ClipGrouping.group(containing: files[1], among: files))
    }

    private func urls(_ paths: String...) -> [URL] {
        paths.map { URL(fileURLWithPath: $0) }
    }
}
