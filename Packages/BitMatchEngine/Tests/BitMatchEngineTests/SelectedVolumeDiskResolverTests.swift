import XCTest
@testable import BitMatchEngine

final class SelectedVolumeDiskResolverTests: XCTestCase {
    func testSelectedFolderResolvesItsOwnVolumeBeforeDiskLookup() {
        let root = URL(fileURLWithPath: "/Volumes/Backup")
        for selected in [root, root.appendingPathComponent("Card"), root.appendingPathComponent("Job/Day/Card")] {
            var reads: [URL] = []
            var lookups: [URL] = []
            let value = SelectedVolumeDiskResolver.disk(
                for: selected,
                readVolumeRoot: { reads.append($0); return root },
                makeDisk: { lookups.append($0); return "selected-disk" }
            )
            XCTAssertEqual(value, "selected-disk")
            XCTAssertEqual(reads, [selected])
            XCTAssertEqual(lookups, [root], "Disk Arbitration must receive the mount root")
        }
    }

    func testMissingOrNonFileVolumeCannotTriggerDiskLookup() {
        let selected = URL(fileURLWithPath: "/Volumes/Backup/Card")
        let remote = URL(string: "sftp://example.invalid/backup")!
        for volume in [nil, remote] as [URL?] {
            let value: String? = SelectedVolumeDiskResolver.disk(
                for: selected, readVolumeRoot: { _ in volume },
                makeDisk: { _ in XCTFail("No reliable selected volume"); return "unexpected" }
            )
            XCTAssertNil(value)
        }
        let value: String? = SelectedVolumeDiskResolver.disk(
            for: remote, readVolumeRoot: { _ in XCTFail("Not a local selection"); return selected },
            makeDisk: { _ in XCTFail("Not a local selection"); return "unexpected" }
        )
        XCTAssertNil(value)
    }

    func testCancelledVolumeResolutionCannotStartDiskLookup() {
        for cancelDuringRead in [false, true] {
            var cancelled = !cancelDuringRead
            let value: String? = SelectedVolumeDiskResolver.disk(
                for: URL(fileURLWithPath: "/Volumes/Backup/Card"),
                readVolumeRoot: { _ in
                    XCTAssertTrue(cancelDuringRead)
                    cancelled = true
                    return URL(fileURLWithPath: "/Volumes/Backup")
                },
                makeDisk: { _ in XCTFail("Cancelled lookup"); return "unexpected" },
                isCancelled: { cancelled }
            )
            XCTAssertNil(value)
        }
    }
}
