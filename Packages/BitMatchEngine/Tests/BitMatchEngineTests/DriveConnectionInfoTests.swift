import XCTest
@testable import BitMatchEngine

final class DriveConnectionInfoTests: XCTestCase {
    func testSelectedFolderResolvesItsOwnVolumeBeforeDiskLookup() {
        let root = URL(fileURLWithPath: "/Volumes/Backup")
        for selected in [root, root.appendingPathComponent("Card"), root.appendingPathComponent("Job/Day/Card")] {
            var reads: [URL] = []
            var lookups: [URL] = []
            let value = DriveConnectionVolumeResolver.disk(
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
            let value: String? = DriveConnectionVolumeResolver.disk(
                for: selected, readVolumeRoot: { _ in volume },
                makeDisk: { _ in XCTFail("No reliable selected volume"); return "unexpected" }
            )
            XCTAssertNil(value)
        }
        let value: String? = DriveConnectionVolumeResolver.disk(
            for: remote, readVolumeRoot: { _ in XCTFail("Not a local selection"); return selected },
            makeDisk: { _ in XCTFail("Not a local selection"); return "unexpected" }
        )
        XCTAssertNil(value)
    }

    func testCancelledVolumeResolutionCannotStartDiskLookup() {
        for cancelDuringRead in [false, true] {
            var cancelled = !cancelDuringRead
            let value: String? = DriveConnectionVolumeResolver.disk(
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

    func testOnlyUSBHostHighSpeedProducesHint() {
        // IOUSBHost high-speed is 3. Legacy USBDeviceSpeed uses 2; it must
        // not accidentally label low/full-speed or unknown links USB 2.
        for speed in [nil, -1, 0, 1, 2, 3, 4, 5, 6, 7, 100] as [Int?] {
            var released: [Int] = []
            let fact = DriveConnectionRegistryWalk.find(
                startingAt: 0, isCancelled: { false },
                isUSBDevice: { _ in true }, speed: { _ in speed },
                parent: { _ in XCTFail("A device's parent must not supply its speed"); return nil },
                release: { released.append($0) }
            )
            XCTAssertEqual(fact, speed == 3 ? .usb2HighSpeed : nil, "speed \(String(describing: speed))")
            XCTAssertEqual(released, [0])
        }
        XCTAssertEqual(DriveConnectionInfo.usb2HighSpeed.bitsPerSecond, 480_000_000)
    }

    func testNearestDeviceWinsOverInterfaceAndUpstreamHub() {
        for deviceSpeed in [3, 5] {
            var released: [Int] = []
            var speedReads: [Int] = []
            let fact = DriveConnectionRegistryWalk.find(
                startingAt: 0, isCancelled: { false },
                isUSBDevice: { $0 == 2 || $0 == 3 },
                speed: { entry in speedReads.append(entry); return entry == 2 ? deviceSpeed : 3 },
                parent: { $0 + 1 }, release: { released.append($0) }
            )
            XCTAssertEqual(fact, deviceSpeed == 3 ? .usb2HighSpeed : nil)
            XCTAssertEqual(speedReads, [2])
            XCTAssertEqual(released, [0, 1, 2])
        }
    }

    func testUnknownDeviceDoesNotUseHubSpeed() {
        var visited: [Int] = []
        let fact = DriveConnectionRegistryWalk.find(
            startingAt: 0, isCancelled: { false },
            isUSBDevice: { _ in true }, speed: { _ in nil },
            parent: { _ in XCTFail("Missing device speed is unknown"); return nil },
            release: { visited.append($0) }
        )
        XCTAssertNil(fact)
        XCTAssertEqual(visited, [0])
    }

    func testWalkBudgetReleasesEveryAcquiredHandle() {
        var acquired = [0]
        var released: [Int] = []
        let fact = DriveConnectionRegistryWalk.find(
            startingAt: 0, isCancelled: { false },
            isUSBDevice: { _ in false }, speed: { _ in XCTFail("Not USB"); return 3 },
            parent: { entry in acquired.append(entry + 1); return entry + 1 },
            release: { released.append($0) }
        )
        XCTAssertNil(fact)
        XCTAssertEqual(acquired, Array(0..<64))
        XCTAssertEqual(released, acquired)
    }

    func testCancellationReleasesInitialOrJustAcquiredParent() {
        for cancelOnParent in [false, true] {
            var cancelled = !cancelOnParent
            var released: [Int] = []
            let fact = DriveConnectionRegistryWalk.find(
                startingAt: 0, isCancelled: { cancelled },
                isUSBDevice: { $0 == 1 }, speed: { _ in XCTFail("Cancelled"); return 3 },
                parent: { _ in cancelled = true; return 1 }, release: { released.append($0) }
            )
            XCTAssertNil(fact)
            XCTAssertEqual(released, cancelOnParent ? [0, 1] : [0])
        }
    }

    func testCancellationDuringSpeedReadDropsFact() {
        var cancelled = false
        var released: [Int] = []
        let fact = DriveConnectionRegistryWalk.find(
            startingAt: 0, isCancelled: { cancelled },
            isUSBDevice: { _ in true }, speed: { _ in cancelled = true; return 3 },
            parent: { _ in XCTFail("Cancelled"); return nil }, release: { released.append($0) }
        )
        XCTAssertNil(fact)
        XCTAssertEqual(released, [0])
    }

    func testMissingParentAndZeroBudgetReleaseInitialHandle() {
        for limit in [0, 64] {
            var released: [Int] = []
            let fact = DriveConnectionRegistryWalk.find(
                startingAt: 0, limit: limit, isCancelled: { false },
                isUSBDevice: { _ in false }, speed: { _ in nil }, parent: { _ in nil },
                release: { released.append($0) }
            )
            XCTAssertNil(fact)
            XCTAssertEqual(released, [0])
        }
    }
}
