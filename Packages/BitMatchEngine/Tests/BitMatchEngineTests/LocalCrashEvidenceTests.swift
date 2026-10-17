import Foundation
import XCTest
@testable import BitMatchEngine

final class LocalCrashEvidenceTests: XCTestCase {
    private func isolatedDefaults() throws -> UserDefaults {
        let name = "BitMatch.LocalCrashEvidenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private final class Consent: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        func revoke() { lock.lock(); defer { lock.unlock() }; value = false }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ seconds: TimeInterval) { value = Date(timeIntervalSince1970: seconds) }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(to seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }; value = Date(timeIntervalSince1970: seconds)
        }
    }

    private final class RemovalFault: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        private var failEpoch = false
        func shouldFail(_ url: URL) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return active && (url.lastPathComponent == "system-evidence.json"
                || (failEpoch && url.lastPathComponent == "system-evidence-epoch.json"))
        }
        func set(_ value: Bool, epoch: Bool = false) {
            lock.lock(); defer { lock.unlock() }; active = value; failEpoch = epoch
        }
    }

    private final class SyncFault: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false
        func allow() -> Bool { lock.lock(); defer { lock.unlock() }; return !failing }
        func setFailing(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failing = value }
    }

    private func fixture() throws -> (URL, LocalCrashEvidenceStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-evidence-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, LocalCrashEvidenceStore(directory: root, defaults: try isolatedDefaults(),
            now: { Date(timeIntervalSince1970: 50) }, synchronizeDefaults: { _ in true }))
    }

    private func evidence(_ value: Int = 11, periodBegin: TimeInterval = 100) -> LocalCrashEvidence {
        LocalCrashEvidence(kind: .crash, periodBegin: Date(timeIntervalSince1970: periodBegin),
            periodEnd: Date(timeIntervalSince1970: TimeInterval(200 + value)),
            appVersion: "0.2.9 PRIVATE_FOOTAGE", build: "5 SECRET_SET",
            signal: value, exceptionType: 1, exceptionCode: 2,
            frames: [.init(binaryUUID: UUID(uuidString: "70B89F27-1634-3580-A695-57CDB41D7743")!, offset: 165_304)])
    }

    func testDefaultOffAndDelayedCallbackCannotRestoreEvidenceAfterOptOut() throws {
        let (root, store) = try fixture()
        XCTAssertNil(store.collectionToken())
        store.setEnabled(true)
        let delayedCallbackToken = try XCTUnwrap(store.collectionToken())
        store.append(evidence(), token: delayedCallbackToken)
        XCTAssertEqual(store.snapshot().records.count, 1)

        store.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-evidence.json").path))
        store.append(evidence(12), token: delayedCallbackToken)
        XCTAssertTrue(store.snapshot().records.isEmpty)

        // Re-enabling must not make the old callback's token valid again.
        store.setEnabled(true)
        store.append(evidence(13), token: delayedCallbackToken)
        XCTAssertTrue(store.snapshot().records.isEmpty)
        let liveToken = try XCTUnwrap(store.collectionToken())
        store.append(evidence(14), token: liveToken)
        XCTAssertEqual(store.snapshot().records.map(\.signal), [14])
    }

    func testDefaultOffLaunchDoesNotRequirePreferenceSync() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("default-off-\(UUID())")
        let store = LocalCrashEvidenceStore(directory: root, defaults: try isolatedDefaults(),
            synchronizeDefaults: { _ in false })
        store.setEnabled(false)
        XCTAssertNil(store.collectionToken())
        XCTAssertFalse(store.snapshot().recordingHadErrors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testClearInvalidatesCallbackAndDuplicatesAreIgnored() throws {
        let (_, store) = try fixture()
        store.setEnabled(true)
        let token = try XCTUnwrap(store.collectionToken())
        store.append(evidence(), token: token)
        store.append(evidence(), token: token)
        XCTAssertEqual(store.snapshot().records.count, 1)
        store.clear()
        store.append(evidence(12), token: token)
        XCTAssertTrue(store.snapshot().records.isEmpty)
    }

    func testClearEpochBlocksLaterRedeliveryAcrossRestartAndReenable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epoch-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(50)
        let defaults = try isolatedDefaults()
        let store = LocalCrashEvidenceStore(directory: root, defaults: defaults, now: { clock.read() },
            synchronizeDefaults: { _ in true })
        store.setEnabled(true)
        let firstToken = try XCTUnwrap(store.collectionToken())
        store.append(evidence(), token: firstToken)
        XCTAssertEqual(store.snapshot().records.count, 1)

        clock.advance(to: 150)
        store.clear()
        XCTAssertTrue(store.snapshot().records.isEmpty)
        store.append(evidence(12), token: firstToken) // Already processing at Clear.
        let afterClear = try XCTUnwrap(store.collectionToken())
        store.append(evidence(12), token: afterClear) // Delivered after Clear.
        XCTAssertTrue(store.snapshot().records.isEmpty)

        let restarted = LocalCrashEvidenceStore(directory: root, defaults: defaults, now: { clock.read() },
            synchronizeDefaults: { _ in true })
        restarted.setEnabled(true)
        let restartToken = try XCTUnwrap(restarted.collectionToken())
        restarted.append(evidence(13), token: restartToken) // Old payload redelivered.
        XCTAssertTrue(restarted.snapshot().records.isEmpty)
        restarted.append(evidence(14, periodBegin: 160), token: restartToken)
        XCTAssertEqual(restarted.snapshot().records.map(\.signal), [14])

        restarted.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-evidence-epoch.json").path))
        clock.advance(to: 170)
        restarted.setEnabled(true)
        let reenabledToken = try XCTUnwrap(restarted.collectionToken())
        restarted.append(evidence(15, periodBegin: 160), token: reenabledToken)
        XCTAssertTrue(restarted.snapshot().records.isEmpty)
        restarted.append(evidence(16, periodBegin: 180), token: reenabledToken)
        XCTAssertEqual(restarted.snapshot().records.map(\.signal), [16])
    }

    func testPersistRechecksPreferenceEvenBeforeSubscriberIsRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("consent-test-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let consent = Consent()
        let store = LocalCrashEvidenceStore(directory: root, defaults: try isolatedDefaults(),
            consentProvider: { consent.read() },
            now: { Date(timeIntervalSince1970: 50) }, synchronizeDefaults: { _ in true })
        store.setEnabled(true)
        let token = try XCTUnwrap(store.collectionToken())
        consent.revoke() // Models the Settings write racing a queued Apple callback.
        store.append(evidence(), token: token)
        XCTAssertTrue(store.snapshot().records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-evidence.json").path))
    }

    func testOversizedEvidenceFileIsNeverReadIntoExport() throws {
        let (root, store) = try fixture()
        store.setEnabled(true)
        try Data(repeating: 0, count: 65 * 1024)
            .write(to: root.appendingPathComponent("system-evidence.json"))
        let snapshot = store.snapshot()
        XCTAssertTrue(snapshot.enabled)
        XCTAssertTrue(snapshot.records.isEmpty)
        XCTAssertTrue(snapshot.recordingHadErrors)
    }

    func testEpochPersistenceFailureDisablesCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-epoch-\(UUID())")
        try Data().write(to: root) // A file blocks creation of the private directory.
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LocalCrashEvidenceStore(directory: root, defaults: try isolatedDefaults(),
            now: { Date(timeIntervalSince1970: 50) }, synchronizeDefaults: { _ in true })
        store.setEnabled(true)
        XCTAssertNil(store.collectionToken())
        XCTAssertFalse(store.snapshot().enabled)
        XCTAssertTrue(store.snapshot().recordingHadErrors)
    }

    func testConsentBoundaryPersistenceFailureDisablesCollection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("blocked-consent-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LocalCrashEvidenceStore(directory: root, defaults: try isolatedDefaults(),
            now: { Date(timeIntervalSince1970: 50) }, synchronizeDefaults: { _ in false })
        store.setEnabled(true)
        XCTAssertNil(store.collectionToken())
        XCTAssertFalse(store.snapshot().enabled)
        XCTAssertTrue(store.snapshot().recordingHadErrors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-evidence.json").path))
    }

    func testFailedDeletionKeepsCollectionOffAndIsVisibleAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delete-fault-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(50)
        let fault = RemovalFault()
        let defaults = try isolatedDefaults()
        let remove: @Sendable (URL) throws -> Void = { url in
            if fault.shouldFail(url) {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        }
        let store = LocalCrashEvidenceStore(directory: root, defaults: defaults,
            now: { clock.read() }, removeItem: remove, synchronizeDefaults: { _ in true })
        store.setEnabled(true)
        store.append(evidence(), token: try XCTUnwrap(store.collectionToken()))

        fault.set(true)
        clock.advance(to: 150)
        store.clear()
        XCTAssertNil(store.collectionToken())
        XCTAssertTrue(store.snapshot().deletionHadErrors)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-evidence.json").path))
        let exportStore = TransferDiagnosticStore(directory: root.appendingPathComponent("transfer"),
            systemEvidenceStore: store)
        let export = try XCTUnwrap(JSONSerialization.jsonObject(with: exportStore.exportData()) as? [String: Any])
        XCTAssertEqual(export["systemEvidenceDeletionHadErrors"] as? Bool, true)
        XCTAssertEqual((export["systemEvidence"] as? [Any])?.count, 0)
        store.setEnabled(true)
        XCTAssertNil(store.collectionToken()) // Re-enable must retry deletion first.

        let restarted = LocalCrashEvidenceStore(directory: root, defaults: defaults,
            now: { clock.read() }, removeItem: remove, synchronizeDefaults: { _ in true })
        restarted.setEnabled(true)
        XCTAssertNil(restarted.collectionToken()) // Old bytes remain after restart.
        XCTAssertTrue(restarted.snapshot().deletionHadErrors)

        fault.set(false)
        restarted.setEnabled(true)
        XCTAssertNotNil(restarted.collectionToken())
        XCTAssertFalse(restarted.snapshot().deletionHadErrors)
        XCTAssertTrue(restarted.snapshot().records.isEmpty)

        restarted.append(evidence(14, periodBegin: 160), token: try XCTUnwrap(restarted.collectionToken()))
        fault.set(true)
        restarted.setEnabled(false)
        XCTAssertTrue(restarted.snapshot().deletionHadErrors)
        XCTAssertNil(restarted.collectionToken())
        restarted.setEnabled(true)
        XCTAssertNil(restarted.collectionToken())
        fault.set(false)
        clock.advance(to: 170)
        restarted.setEnabled(true)
        XCTAssertNotNil(restarted.collectionToken())
        XCTAssertTrue(restarted.snapshot().records.isEmpty)
    }

    func testBothFilesFailToDeleteThenRestartCannotRestoreOldConsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("both-delete-fault-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try isolatedDefaults()
        let clock = Clock(50)
        let fault = RemovalFault()
        let remove: @Sendable (URL) throws -> Void = { url in
            if fault.shouldFail(url) { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let store = LocalCrashEvidenceStore(directory: root, defaults: defaults,
            now: { clock.read() }, removeItem: remove, synchronizeDefaults: { _ in true })
        store.setEnabled(true)
        store.append(evidence(), token: try XCTUnwrap(store.collectionToken()))
        clock.advance(to: 150)
        fault.set(true, epoch: true)
        store.setEnabled(false)
        XCTAssertNil(store.collectionToken())
        XCTAssertTrue(store.snapshot().deletionHadErrors)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-evidence.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-evidence-epoch.json").path))

        // Simulate a new process where the preference has been turned on.
        let restarted = LocalCrashEvidenceStore(directory: root, defaults: defaults,
            now: { clock.read() }, removeItem: remove, synchronizeDefaults: { _ in true })
        restarted.setEnabled(true)
        XCTAssertNil(restarted.collectionToken())
        XCTAssertTrue(restarted.snapshot().deletionHadErrors)

        fault.set(false)
        clock.advance(to: 170)
        restarted.setEnabled(true)
        let token = try XCTUnwrap(restarted.collectionToken())
        restarted.append(evidence(12), token: token)
        XCTAssertTrue(restarted.snapshot().records.isEmpty)
        restarted.append(evidence(13, periodBegin: 180), token: token)
        XCTAssertEqual(restarted.snapshot().records.map(\.signal), [13])
    }

    func testFailedBoundaryAndDeletionLeaveTombstoneAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("combined-fault-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let defaults = try isolatedDefaults()
        let clock = Clock(50)
        let removal = RemovalFault()
        let sync = SyncFault()
        let remove: @Sendable (URL) throws -> Void = { url in
            if removal.shouldFail(url) { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        }
        let store = LocalCrashEvidenceStore(directory: root, defaults: defaults,
            now: { clock.read() }, removeItem: remove,
            synchronizeDefaults: { _ in sync.allow() })
        store.setEnabled(true)
        store.append(evidence(), token: try XCTUnwrap(store.collectionToken()))

        clock.advance(to: 150)
        removal.set(true, epoch: true)
        sync.setFailing(true)
        store.clear()
        XCTAssertNil(store.collectionToken())
        XCTAssertTrue(store.snapshot().deletionHadErrors)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("system-evidence.json").path))

        // Model a failed preference flush: the next process sees the old
        // boundary while both old evidence and the new blocked epoch survive.
        defaults.set(Date(timeIntervalSince1970: 50), forKey: "BitMatchCrashEvidenceConsentBoundary")
        let restarted = LocalCrashEvidenceStore(directory: root, defaults: defaults,
            now: { clock.read() }, removeItem: remove,
            synchronizeDefaults: { _ in true })
        restarted.setEnabled(true)
        XCTAssertNil(restarted.collectionToken())
        XCTAssertTrue(restarted.snapshot().records.isEmpty)

        removal.set(false)
        restarted.setEnabled(true)
        let token = try XCTUnwrap(restarted.collectionToken())
        restarted.append(evidence(12), token: token)
        XCTAssertTrue(restarted.snapshot().records.isEmpty)
        restarted.append(evidence(13, periodBegin: 160), token: token)
        XCTAssertEqual(restarted.snapshot().records.map(\.signal), [13])
    }

    func testBoundedAllowlistedExportAndNoRawStackStrings() throws {
        let (root, store) = try fixture()
        store.setEnabled(true)
        let token = try XCTUnwrap(store.collectionToken())
        for index in 0..<40 { store.append(evidence(index), token: token) }
        let fileSize = try root.appendingPathComponent("system-evidence.json")
            .resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertLessThanOrEqual(fileSize ?? .max, 64 * 1024)
        let transferStore = TransferDiagnosticStore(directory: root.appendingPathComponent("transfer"),
            systemEvidenceStore: store)
        let json = try transferStore.exportData()
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_FOOTAGE"))
        XCTAssertFalse(text.contains("SECRET_SET"))
        XCTAssertFalse(text.contains("binaryName"))
        XCTAssertFalse(text.contains("address"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let rows = try XCTUnwrap(object["systemEvidence"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 16)
        XCTAssertEqual(rows.first?["signal"] as? Int, 24)
        XCTAssertEqual(rows.last?["signal"] as? Int, 39)
        XCTAssertEqual(rows.last?["appVersion"] as? String, "0.2.9")
        XCTAssertEqual(rows.last?["build"] as? String, "5")
        XCTAssertEqual(object["systemEvidenceEnabled"] as? Bool, true)
        XCTAssertNotNil(object["systemEvidenceNote"] as? String)
        store.setEnabled(false)
        let disabled = try XCTUnwrap(JSONSerialization.jsonObject(with: transferStore.exportData()) as? [String: Any])
        XCTAssertEqual((disabled["systemEvidence"] as? [Any])?.count, 0)
        XCTAssertEqual(disabled["systemEvidenceEnabled"] as? Bool, false)
    }

    func testDecodedLocalFileCannotBypassExportSanitization() throws {
        let (root, store) = try fixture()
        store.setEnabled(true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(evidence())) as? [String: Any])
        row["appVersion"] = "0.2.9 PRIVATE_FOOTAGE"
        row["build"] = "5 SECRET_SET"
        row["frames"] = Array(repeating: [
            "binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743", "offset": 165_304
        ] as [String: Any], count: 32)
        let file = root.appendingPathComponent("system-evidence.json")
        try JSONSerialization.data(withJSONObject: [row]).write(to: file)

        let decoded = try XCTUnwrap(store.snapshot().records.first)
        XCTAssertEqual(decoded.appVersion, "0.2.9")
        XCTAssertEqual(decoded.build, "5")
        XCTAssertEqual(decoded.frames.count, 8)
        let transferStore = TransferDiagnosticStore(directory: root.appendingPathComponent("transfer"),
            systemEvidenceStore: store)
        let export = String(decoding: try transferStore.exportData(), as: UTF8.self)
        XCTAssertFalse(export.contains("PRIVATE_FOOTAGE"))
        XCTAssertFalse(export.contains("SECRET_SET"))
    }

    func testFrameParserRetainsOnlyAttributedUUIDAndOffset() throws {
        let marker = "SECRET_FOOTAGE_" + UUID().uuidString
        let json: [String: Any] = ["callStackTree": ["callStacks": [
            ["threadAttributed": false, "callStackRootFrames": [["binaryUUID": UUID().uuidString,
                "offsetIntoBinaryTextSegment": 1, "binaryName": marker]]],
            ["threadAttributed": true, "callStackRootFrames": [["binaryUUID": "70B89F27-1634-3580-A695-57CDB41D7743",
                "offsetIntoBinaryTextSegment": 165_304, "binaryName": marker, "address": 7_170_766_264,
                "subFrames": [["binaryUUID": "77A62F2E-8212-30F3-84C1-E8497440ACF8",
                    "offsetIntoBinaryTextSegment": 6_948, "binaryName": marker]]]]]
        ]]]
        let frames = MetricKitFrameParser.frames(from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(frames.map(\.offset), [165_304, 6_948])
        let encoded = String(decoding: try JSONEncoder().encode(frames), as: UTF8.self)
        XCTAssertFalse(encoded.contains(marker))
        XCTAssertFalse(encoded.contains("address"))
        XCTAssertFalse(encoded.contains("binaryName"))
    }
}
