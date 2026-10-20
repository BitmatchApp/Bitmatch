import XCTest
import BitMatchEngine
@testable import BitMatch

@MainActor
final class DriveConnectionDetailsTests: XCTestCase {
    private final class Provider: DriveConnectionInfoProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var requested: [URL] = []
        var calls: [URL] { lock.withLock { requested } }
        let blocked: URL?
        let started = XCTestExpectation(description: "Lookup entered")
        let release = DispatchSemaphore(value: 0)

        init(blocked: URL? = nil) { self.blocked = blocked }

        func connectionInfo(for url: URL) -> DriveConnectionInfo? {
            lock.withLock { requested.append(url) }
            if url == blocked {
                started.fulfill()
                // A test failure cannot leave the test process blocked.
                guard release.wait(timeout: .now() + 10) == .success else { return nil }
            }
            return url.lastPathComponent == "Unknown" ? nil : .usb2HighSpeed
        }
    }

    func testOnlySelectedKnownConnectionsAppearInSelectionOrder() async {
        let provider = Provider()
        let model = DriveConnectionDetailsModel(provider: provider)
        let first = URL(fileURLWithPath: "/Volumes/Backup A/Card")
        let unknown = URL(fileURLWithPath: "/Volumes/Unknown")
        let second = URL(fileURLWithPath: "/Volumes/Backup B")
        await model.refresh(destinations: [first, unknown, second])
        XCTAssertEqual(provider.calls, [first, unknown, second])
        XCTAssertEqual(model.rows.map(\.url), [first, second])
        XCTAssertEqual(model.rows.map(\.title), ["Backup A", "Backup B"])
        XCTAssertTrue(model.rows.allSatisfy { $0.connection == .usb2HighSpeed })
        XCTAssertEqual(model.rows.first?.connectionLabel, "USB 2 connection (480 Mb/s)")
    }

    func testSupersededLookupCannotPublishOverNewSelection() async {
        let old = URL(fileURLWithPath: "/Volumes/Old")
        let new = URL(fileURLWithPath: "/Volumes/New")
        let provider = Provider(blocked: old)
        let model = DriveConnectionDetailsModel(provider: provider)
        let oldTask = Task { await model.refresh(destinations: [old]) }
        defer { provider.release.signal(); oldTask.cancel(); model.clear() }
        await fulfillment(of: [provider.started], timeout: 5)
        await model.refresh(destinations: [new])
        XCTAssertEqual(model.rows.map(\.url), [new])
        provider.release.signal()
        await oldTask.value
        XCTAssertEqual(model.rows.map(\.url), [new])
        XCTAssertEqual(provider.calls, [old, new])
    }

    func testClearDropsPendingResultAndStopsLaterSelectedLookups() async {
        let old = URL(fileURLWithPath: "/Volumes/Old")
        let later = URL(fileURLWithPath: "/Volumes/Later")
        let provider = Provider(blocked: old)
        let model = DriveConnectionDetailsModel(provider: provider)
        let task = Task { await model.refresh(destinations: [old, later]) }
        defer { provider.release.signal(); task.cancel(); model.clear() }
        await fulfillment(of: [provider.started], timeout: 5)
        model.clear()
        provider.release.signal()
        await task.value
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(provider.calls, [old])
    }

    func testParentTaskCancellationDropsPendingResultAndStopsLaterLookups() async {
        let old = URL(fileURLWithPath: "/Volumes/Old")
        let later = URL(fileURLWithPath: "/Volumes/Later")
        let provider = Provider(blocked: old)
        let model = DriveConnectionDetailsModel(provider: provider)
        let task = Task { await model.refresh(destinations: [old, later]) }
        defer { provider.release.signal(); task.cancel(); model.clear() }
        await fulfillment(of: [provider.started], timeout: 5)
        task.cancel()
        provider.release.signal()
        await task.value
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(provider.calls, [old])
    }

    func testEmptySelectionClearsKnownHintWithoutAnotherLookup() async {
        let provider = Provider()
        let model = DriveConnectionDetailsModel(provider: provider)
        let destination = URL(fileURLWithPath: "/Volumes/Backup")
        await model.refresh(destinations: [destination])
        XCTAssertEqual(model.rows.count, 1)
        await model.refresh(destinations: [])
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(provider.calls, [destination])
    }
}
