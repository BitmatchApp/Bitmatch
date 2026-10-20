import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

final class TransferDiagnosticStoreTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostics-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func previousEvent(in root: URL, limit: Int = 1024) throws -> TransferDiagnosticStore {
        let store = TransferDiagnosticStore(directory: root, limit: limit)
        store.record(.pipelineDrained, run: nil) { $0.code = 17 }
        try FileManager.default.moveItem(at: root.appendingPathComponent("current.jsonl"),
                                         to: root.appendingPathComponent("previous.jsonl"))
        return store
    }

    private func exportedObject(_ store: TransferDiagnosticStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
    }

    func testOversizedInputIsRejectedWithoutDiscardingOtherFile() throws {
        let root = try fixture()
        let store = try previousEvent(in: root)
        try Data(repeating: 0, count: 1025).write(to: root.appendingPathComponent("current.jsonl"))
        let object = try exportedObject(store)
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["code"] as? Int }, [17])
        XCTAssertEqual(object["formatVersion"] as? Int, 2)
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(object["incompleteRecords"] as? Int, 0, "An unread file has an unknown record count")
        let rejected = try XCTUnwrap(object["rejectedInputs"] as? [[String: String]])
        XCTAssertEqual(rejected, [["file": "current", "reason": "oversized"]])
    }

    func testOversizedPreviousDoesNotDiscardValidCurrent() throws {
        let root = try fixture()
        let store = TransferDiagnosticStore(directory: root, limit: 1024)
        store.record(.pipelineDrained, run: nil) { $0.code = 19 }
        try Data(repeating: 0, count: 1025).write(to: root.appendingPathComponent("previous.jsonl"))
        let object = try exportedObject(store)
        XCTAssertEqual((object["events"] as? [[String: Any]])?.compactMap { $0["code"] as? Int }, [19])
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(object["rejectedInputs"] as? [[String: String]], [["file": "previous", "reason": "oversized"]])
    }

    func testValidInputAtByteLimitIsNotTruncated() throws {
        let root = try fixture()
        let file = root.appendingPathComponent("current.jsonl")
        TransferDiagnosticStore(directory: root).record(.pipelineDrained, run: nil) { $0.code = 17 }
        let line = try Data(contentsOf: file)
        var data = Data()
        for _ in 0..<400 { data.append(line) }
        XCTAssertGreaterThan(data.count, 64 * 1024)
        XCTAssertLessThanOrEqual(data.count, 256 * 1024)
        try data.write(to: file)
        let object = try exportedObject(TransferDiagnosticStore(directory: root, limit: data.count))
        XCTAssertEqual((object["events"] as? [Any])?.count, 400)
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, false)
        XCTAssertEqual(object["incompleteRecords"] as? Int, 0)
        XCTAssertEqual(object["rejectedInputs"] as? [[String: String]], [])
    }

    func testMalformedInputFlagsErrorWithoutDiscardingEarlierEvents() throws {
        let root = try fixture()
        let store = try previousEvent(in: root)
        try Data("{unfinished SECRET_FOOTAGE".utf8).write(to: root.appendingPathComponent("current.jsonl"))
        let object = try exportedObject(store)
        XCTAssertEqual((object["events"] as? [[String: Any]])?.compactMap { $0["code"] as? Int }, [17])
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(object["incompleteRecords"] as? Int, 1)
        XCTAssertEqual(object["rejectedInputs"] as? [[String: String]], [])
        XCTAssertFalse(String(decoding: try store.exportData(), as: UTF8.self).contains("SECRET_FOOTAGE"))
    }

    func testMissingInputsAreOrdinaryEmptyHistory() throws {
        let object = try exportedObject(TransferDiagnosticStore(directory: try fixture()))
        XCTAssertEqual((object["events"] as? [Any])?.count, 0)
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, false)
        XCTAssertEqual(object["rejectedInputs"] as? [[String: String]], [])
    }

    func testSymlinkInputIsNotFollowed() throws {
        let root = try fixture()
        let store = try previousEvent(in: root)
        let outside = root.appendingPathComponent("outside")
        let other = TransferDiagnosticStore(directory: outside)
        other.record(.admitted, run: nil) { $0.code = 99 }
        let original = try Data(contentsOf: outside.appendingPathComponent("current.jsonl"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("current.jsonl"),
                                                   withDestinationURL: outside.appendingPathComponent("current.jsonl"))
        let object = try exportedObject(store)
        XCTAssertEqual((object["events"] as? [[String: Any]])?.compactMap { $0["code"] as? Int }, [17])
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(object["rejectedInputs"] as? [[String: String]], [["file": "current", "reason": "unsupportedFileType"]])
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("current.jsonl")), original)
    }

#if canImport(Darwin)
    func testFIFOInputIsRejectedWithoutWaitingForWriter() throws {
        let root = try fixture()
        let store = try previousEvent(in: root)
        let path = root.appendingPathComponent("current.jsonl").path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        let finished = DispatchSemaphore(value: 0)
        let watchdogDone = DispatchSemaphore(value: 0)
        // A regression to a blocking reader must fail without hanging the
        // suite. This releases such a reader; correctness uses the rejection
        // below, not a hardware-dependent elapsed-time threshold.
        DispatchQueue.global().async {
            defer { watchdogDone.signal() }
            if finished.wait(timeout: .now() + 5) == .timedOut {
                let writer = Darwin.open(path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                if writer >= 0 { Darwin.close(writer) }
            }
        }
        defer {
            finished.signal()
            XCTAssertEqual(watchdogDone.wait(timeout: .now() + 10), .success)
        }
        let object = try exportedObject(store)
        XCTAssertEqual((object["events"] as? [[String: Any]])?.compactMap { $0["code"] as? Int }, [17])
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(object["rejectedInputs"] as? [[String: String]], [["file": "current", "reason": "unsupportedFileType"]])
    }

    func testPermissionDeniedInputDoesNotHideOtherFile() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root cannot enforce a fixture's read-permission denial") }
        let root = try fixture()
        let store = try previousEvent(in: root)
        let current = root.appendingPathComponent("current.jsonl")
        try Data("not readable".utf8).write(to: current)
        XCTAssertEqual(chmod(current.path, 0o000), 0)
        defer { _ = chmod(current.path, 0o600) }
        let object = try exportedObject(store)
        XCTAssertEqual((object["events"] as? [[String: Any]])?.compactMap { $0["code"] as? Int }, [17])
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(object["rejectedInputs"] as? [[String: String]], [["file": "current", "reason": "unreadable"]])
    }
#endif
    func testEventsSurviveReopeningAndContainOnlyStructuredFields() throws {
        let root = try fixture()
        let run = UUID()
        let store = TransferDiagnosticStore(directory: root)
        store.record(.mhlExclusiveRename, run: run) { $0.code = 45; $0.taskCancelled = false }
        store.record(.cancelOrigin, run: run) { $0.origin = .windowClose }
        let data = try TransferDiagnosticStore(directory: root).exportData()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["event"] as? String, "mhlExclusiveRename")
        XCTAssertEqual(events[0]["code"] as? Int, 45)
        XCTAssertEqual(events[0]["run"] as? String, run.uuidString)
        XCTAssertEqual(events[1]["origin"] as? String, "windowClose")
        let keys = Set(events.flatMap { $0.keys })
        XCTAssertTrue(keys.isDisjoint(with: ["path", "sourceURL", "destinationURL", "filename", "bookmark", "message", "errorDescription"]))
    }
    func testRotationKeepsStorageBoundedAndRetainsRecentEvents() throws {
        let root = try fixture()
        let store = TransferDiagnosticStore(directory: root, limit: 1024)
        for index in 0..<100 { store.record(.pipelineDrained, run: UUID()) { $0.code = index } }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertLessThanOrEqual(files.count, 2)
        for file in files { XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 1024) }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(events.last?["code"] as? Int, 99)
        XCTAssertLessThan(events.count, 100)
    }
    func testTruncatedRecordDoesNotDiscardEarlierEvents() throws {
        let root = try fixture()
        let store = TransferDiagnosticStore(directory: root)
        store.record(.mhlStarted, run: UUID())
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("current.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{unfinished".utf8))
        try handle.close()
        store.record(.journalInterrupted, run: UUID())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
        XCTAssertEqual((object["events"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(object["incompleteRecords"] as? Int, 1)
    }
    func testStorageFailureDoesNotThrowOrChangeTransferOutcome() throws {
        let root = try fixture()
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let store = TransferDiagnosticStore(directory: blocked)
        store.record(.admitted, run: UUID())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual((object["events"] as? [[String: Any]])?.count, 0)
    }
    func testLoggerExcludesFootageNamesPathsAndErrorDescriptions() throws {
        let marker = "SECRET_FOOTAGE_" + UUID().uuidString
        let run = UUID()
        SharedLogger.transferError(NSError(domain: marker, code: 45,
            userInfo: [NSLocalizedDescriptionKey: marker]), run: run)
        SharedLogger.transferConfiguration(run: run,
            source: URL(fileURLWithPath: "/" + marker),
            destinations: [URL(fileURLWithPath: "/" + marker + "/backup")],
            mhl: true, report: true, mode: .standard)
        SharedLogger.transferProgress(OperationProgress(overallProgress: 0.5,
            currentFile: marker, filesProcessed: 2, totalFiles: 4,
            currentStage: .verifying, speed: nil), run: run)
        SharedLogger.info(marker) // Free-form logs must never enter the export.
        let data = try TransferDiagnosticStore.shared.exportData()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(marker))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            .filter { ($0["run"] as? String) == run.uuidString }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events.first?["kind"] as? String, "other")
        XCTAssertEqual(events.last?["filesProcessed"] as? Int, 2)
    }
    func testVerifyBreadcrumbsCarryNumbersAndMemoryFootprintOnly() throws {
        let run = UUID()
        SharedLogger.verifyEvent(.verifyStarted, run: run, ordinal: 8, destinationIndex: 0, bytes: 45_344_117_808)
        SharedLogger.verifyEvent(.verifyRead, run: run, ordinal: 8, destinationIndex: 0, bytes: 8 * 1024 * 1024 * 1024)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: TransferDiagnosticStore.shared.exportData()) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
            .filter { ($0["run"] as? String) == run.uuidString }
        XCTAssertEqual(events.map { $0["event"] as? String }, ["verifyStarted", "verifyRead"])
        XCTAssertEqual(events.first?["ordinal"] as? Int, 8)
        XCTAssertEqual(events.first?["bytesProcessed"] as? Int, 45_344_117_808)
        XCTAssertEqual(events.last?["bytesProcessed"] as? Int, 8 * 1024 * 1024 * 1024)
        XCTAssertGreaterThan(events.first?["footprintMB"] as? Int ?? 0, 0)
    }
    func testConcurrentWritersProduceCompleteRecords() async throws {
        let root = try fixture()
        let store = TransferDiagnosticStore(directory: root)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 { group.addTask { store.record(.pipelineDrained, run: UUID()) { $0.code = index } } }
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        XCTAssertEqual(Set(events.compactMap { $0["code"] as? Int }), Set(0..<100))
        XCTAssertEqual(object["incompleteRecords"] as? Int, 0)
    }

}
