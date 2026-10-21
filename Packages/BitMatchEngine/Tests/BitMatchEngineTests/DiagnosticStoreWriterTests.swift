import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

final class DiagnosticStoreWriterTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagnostic-writers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func object(_ store: TransferDiagnosticStore) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
    }

    func testIndependentStoresAndPathAliasesKeepAll401Events() throws {
        // Plant: remove the flock acquisition in withDirectoryLock. Separate
        // instances then race between creating, seeking and writing current.
        let root = try fixture()
        let alias = root.appendingPathComponent("../" + root.lastPathComponent)
        let stores = [TransferDiagnosticStore(directory: root), TransferDiagnosticStore(directory: alias)]
        stores[0].record(.admitted, run: nil) { $0.code = -1 }
        DispatchQueue.concurrentPerform(iterations: 2) { writer in
            for index in 0..<200 {
                stores[writer].record(.pipelineDrained, run: nil) { $0.code = writer * 200 + index }
            }
        }
        let exported = try object(TransferDiagnosticStore(directory: root))
        let codes = try XCTUnwrap(exported["events"] as? [[String: Any]]).compactMap { $0["code"] as? Int }
        XCTAssertEqual(codes.count, 401)
        XCTAssertEqual(Set(codes), Set(-1..<400))
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, false)
        XCTAssertEqual(exported["snapshotUnavailable"] as? Bool, false)
    }

    func testConcurrentRotationAndExportsAreWholeBoundedSnapshots() throws {
        // Plant: bypass flock in withDirectoryLock. Concurrent rotation then
        // loses records or exposes inconsistent snapshots. The separate-process
        // test below checks export lock acquisition deterministically.
        let root = try fixture()
        let stores = (0..<3).map { _ in TransferDiagnosticStore(directory: root, limit: 2048) }
        let snapshots = DiagnosticSnapshots()
        DispatchQueue.concurrentPerform(iterations: 3) { worker in
            if worker == 2 {
                for _ in 0..<80 {
                    do { snapshots.append(try stores[worker].exportData()) }
                    catch { snapshots.failed() }
                }
            } else {
                for index in 0..<150 {
                    stores[worker].record(.pipelineDrained, run: nil) { $0.code = worker * 1000 + index }
                }
            }
        }
        stores[0].record(.journalFinished, run: nil) { $0.code = 9999 }
        snapshots.append(try stores[2].exportData())
        XCTAssertEqual(snapshots.failures, 0)
        XCTAssertEqual(snapshots.values.count, 81)
        for snapshot in snapshots.values {
            let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot) as? [String: Any])
            XCTAssertEqual(exported["recordingHadErrors"] as? Bool, false)
            XCTAssertEqual(exported["incompleteRecords"] as? Int, 0)
            XCTAssertEqual(exported["snapshotUnavailable"] as? Bool, false)
            let codes = try XCTUnwrap(exported["events"] as? [[String: Any]]).compactMap { $0["code"] as? Int }
            XCTAssertEqual(Set(codes).count, codes.count)
            for writer in 0..<2 {
                let sequence = codes.filter { $0 / 1000 == writer && $0 != 9999 }.map { $0 % 1000 }
                if let first = sequence.first, let last = sequence.last {
                    XCTAssertEqual(sequence, Array(first...last), "A retained producer suffix has no holes or reordering")
                }
            }
        }
        let final = try object(stores[0])
        XCTAssertEqual((final["events"] as? [[String: Any]])?.last?["code"] as? Int, 9999)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["previous.jsonl", "current.jsonl"])
        for file in files { XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 2048) }
    }

    func testFirstDroppedEventLeavesAnErrorForAnotherInstance() throws {
        // Plant: omit the sticky failure marker; a new instance then hides the loss.
        let root = try fixture().appendingPathComponent("not-created-yet")
        TransferDiagnosticStore(directory: root, limit: 1).record(.admitted, run: nil)
        let exported = try object(TransferDiagnosticStore(directory: root))
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual((exported["events"] as? [Any])?.count, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".recording-error")).count, 0)
    }

#if canImport(Darwin)
    /// Deterministic contention: an external holder keeps the directory lock
    /// past the writer's 250 ms budget. Every attempted event is dropped,
    /// counted, and disclosed; nothing is written. This classifies the
    /// stress-probe marker shape without calling contention proven in the field.
    func testHeldDirectoryLockDropsAndCountsEveryEvent() throws {
        let root = try fixture()
        let holderFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(holderFD, 0)
        defer { close(holderFD) }
        XCTAssertEqual(flock(holderFD, LOCK_EX), 0)
        let store = TransferDiagnosticStore(directory: root)
        for index in 0..<5 {
            store.record(.pipelineDrained, run: nil) { $0.code = index }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("current.jsonl").path))
        XCTAssertEqual(flock(holderFD, LOCK_UN), 0)
        let exported = try object(store)
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual(exported["droppedEvents"] as? Int, 5)
        XCTAssertEqual((exported["events"] as? [Any])?.count, 0)
        let detail = try XCTUnwrap(exported["recordingFailureDetail"] as? [String: Any])
        XCTAssertEqual(detail["stage"] as? String, "directoryLock")
        XCTAssertEqual(detail["code"] as? Int, Int(EWOULDBLOCK))
        // The persisted claim was written at the first failure: a lower bound.
        XCTAssertEqual(detail["droppedEvents"] as? Int, 1)
        store.record(.journalFinished, run: nil) { $0.code = 99 }
        let after = try object(store)
        XCTAssertEqual((after["events"] as? [[String: Any]])?.compactMap { $0["code"] as? Int }, [99])
        XCTAssertEqual(after["droppedEvents"] as? Int, 5, "Retained plus dropped must account for every attempt")
    }
#endif

#if os(macOS)
    func testOtherProcessLockTimesOutWithoutWritingAndFailureSurvivesReopening() throws {
        // Plant: bypass flock. A separate process already owns the folder, but
        // the record incorrectly succeeds and a new exporter claims completeness.
        let root = try fixture()
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-u", "-c", """
            import os, fcntl, sys, select
            fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
            fcntl.flock(fd, fcntl.LOCK_EX)
            sys.stdout.buffer.write(b'locked'); sys.stdout.buffer.flush()
            ready = bool(select.select([sys.stdin.buffer], [], [], 5)[0])
            if ready: sys.stdin.buffer.read(1)
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
            if not ready: sys.stdin.buffer.read(1)
            """, root.path]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            try? input.fileHandleForWriting.write(contentsOf: Data([1]))
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 6), Data("locked".utf8))
        let store = TransferDiagnosticStore(directory: root)
        store.record(.pipelineDrained, run: nil) { $0.code = 7 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("current.jsonl").path))
        let lockedExport = try object(TransferDiagnosticStore(directory: root))
        XCTAssertEqual(lockedExport["snapshotUnavailable"] as? Bool, true)
        XCTAssertEqual(lockedExport["recordingHadErrors"] as? Bool, true)
        XCTAssertEqual((lockedExport["events"] as? [Any])?.count, 0)
        try input.fileHandleForWriting.write(contentsOf: Data([1]))
        try input.fileHandleForWriting.close()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        let reopened = TransferDiagnosticStore(directory: root)
        reopened.record(.journalFinished, run: nil) { $0.code = 8 }
        let exported = try object(reopened)
        XCTAssertEqual((exported["events"] as? [[String: Any]])?.compactMap { $0["code"] as? Int }, [8])
        XCTAssertEqual(exported["snapshotUnavailable"] as? Bool, false)
        XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true, "Another instance must disclose the dropped event")
        XCTAssertEqual(exported["recordingFailureDetailAvailable"] as? Bool, true)
        XCTAssertEqual(exported["recordingFailureDetailSource"] as? String, "persistedMarker")
        let detail = try XCTUnwrap(exported["recordingFailureDetail"] as? [String: Any])
        XCTAssertEqual(detail["stage"] as? String, "directoryLock")
        XCTAssertEqual(detail["code"] as? Int, Int(EWOULDBLOCK))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".recording-error")).count, 0)
    }
#endif

#if canImport(Darwin)
    func testWriterDoesNotFollowSymlinkOrBlockOnFIFO() throws {
        // Plant: remove O_NOFOLLOW in openCurrent, allowing an outside-file write.
        for useFIFO in [false, true] {
            let root = try fixture()
            let outside = root.appendingPathComponent("SECRET_FOOTAGE")
            let original = Data("private contents".utf8)
            try original.write(to: outside)
            let current = root.appendingPathComponent("current.jsonl")
            if useFIFO {
                XCTAssertEqual(mkfifo(current.path, 0o600), 0)
            } else {
                try FileManager.default.createSymbolicLink(at: current, withDestinationURL: outside)
            }
            TransferDiagnosticStore(directory: root).record(.admitted, run: nil)
            XCTAssertEqual(try Data(contentsOf: outside), original)
            let data = try TransferDiagnosticStore(directory: root).exportData()
            let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(exported["recordingHadErrors"] as? Bool, true)
            XCTAssertEqual((exported["events"] as? [Any])?.count, 0)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET_FOOTAGE"))
        }
    }
#endif
}

private final class DiagnosticSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []
    private var errors = 0
    func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    func failed() { lock.lock(); defer { lock.unlock() }; errors += 1 }
    var values: [Data] { lock.lock(); defer { lock.unlock() }; return storage }
    var failures: Int { lock.lock(); defer { lock.unlock() }; return errors }
}
