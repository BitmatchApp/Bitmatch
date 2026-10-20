import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

/// Actual journal I/O over owned temporary metadata fixtures. No bookmarks
/// are resolved and no source or backup media are read or modified.
final class JournalStartupPersistenceTests: XCTestCase {
    /// Plant: make TransferJournal.init persist every decoded journal again.
    func testCurrentTerminalAndQueuedHistoryIsUnchangedAcrossRepeatedOpens() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let states: [LocalTransferState] = [.completed, .issues, .interrupted, .cancelled, .failed, .queued]
        let records = try states.map { try fixture.record(state: $0) }
        try fixture.write(records)
        let before = try fixture.snapshot()

        for _ in 0..<3 {
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertNil(journal.persistenceError)
            XCTAssertEqual(try Fixture.canonical(journal.records), try Fixture.canonical(records))
            XCTAssertEqual(try fixture.snapshot(), before, "Opening current History must not replace or normalize its file")
        }
    }

    /// Plant: make TransferJournal.init persist every decoded journal again.
    /// This is real engine metadata I/O, not an app responsiveness, peak-RAM or
    /// media-transfer benchmark; correctness has no timing threshold.
    func testTwentyThousandSavedResultRowsRemainUnchangedAcrossRepeatedOpens() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(state: .issues, rowCount: 20_000)
        try fixture.write([original])
        let before = try fixture.snapshot()
        let originalEvidence = try Fixture.canonical([original])
        let originalIDs = original.results.map(\.id)

        for _ in 0..<2 {
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertNil(journal.persistenceError)
            let loaded = try XCTUnwrap(journal.records.first)
            XCTAssertEqual(loaded.state, .issues)
            XCTAssertEqual(loaded.results.count, 20_000)
            XCTAssertEqual(loaded.results.map(\.id), originalIDs)
            XCTAssertEqual(try Fixture.canonical(journal.records), originalEvidence)
            XCTAssertEqual(try fixture.snapshot(), before)
        }
    }

    /// Plant: omit the generated-row-ID migration flag from startup's write decision.
    func testMissingAndNullLegacyRowIDsArePersistedOnceAlongsideExistingIDs() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(state: .issues, rowCount: 3)
        let originalIDs = record.results.map(\.id)
        try fixture.write([record], missingIDs: [1], nullIDs: [2])
        let before = try fixture.snapshot()

        let migratedIDs: [UUID]
        do {
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertNil(journal.persistenceError)
            let loaded = try XCTUnwrap(journal.records.first)
            migratedIDs = loaded.results.map(\.id)
            XCTAssertEqual(migratedIDs.count, 3)
            XCTAssertEqual(Set(migratedIDs).count, 3)
            XCTAssertEqual(migratedIDs[0], originalIDs[0])
            XCTAssertNotEqual(migratedIDs[1], originalIDs[1])
            XCTAssertNotEqual(migratedIDs[2], originalIDs[2])
            XCTAssertEqual(loaded.state, .issues)
            XCTAssertEqual(loaded.results.map(\.path), record.results.map(\.path))
            XCTAssertEqual(loaded.results.map(\.status), record.results.map(\.status))
            XCTAssertEqual(loaded.results.map(\.checksum), record.results.map(\.checksum))
        }

        let migrated = try fixture.snapshot()
        XCTAssertNotEqual(migrated.bytes, before.bytes)
        let saved = try JSONDecoder().decode([LocalTransferRecord].self, from: migrated.bytes)
        XCTAssertEqual(saved.first?.results.map(\.id), migratedIDs)
        for _ in 0..<2 {
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertNil(journal.persistenceError)
            XCTAssertEqual(journal.records.first?.results.map(\.id), migratedIDs)
            XCTAssertEqual(try fixture.snapshot(), migrated, "Already-migrated IDs must stay durable without another rewrite")
        }
    }

    /// Plant: exclude running-to-interrupted recovery from startup's write decision.
    func testRunningRecoveryPersistsEvenWithoutLegacyRows() throws {
        try checkRunningRecovery(migrateRowID: false)
    }

    /// Plant: skip legacy-ID persistence when recovering a running attempt.
    func testRunningRecoveryAndLegacyIDMigrationAreBothDurable() throws {
        try checkRunningRecovery(migrateRowID: true)
    }

    /// Plant: permit mutations when a required migration write has failed.
    func testFailedLegacyMigrationWriteBlocksMutationsAndPreservesOriginalBytes() throws {
        try checkRequiredWriteFailure(state: .issues, migrateRowID: true)
    }

    /// Plant: publish the original running state after its recovery write fails.
    func testFailedRecoveryWriteStillShowsInterruptionAndBlocksMutations() throws {
        try checkRequiredWriteFailure(state: .running, migrateRowID: false)
    }

    /// Plant: clear loadFailed merely because recovery produced in-memory records.
    func testFailedCombinedRecoveryAndMigrationCannotStartNewWork() throws {
        try checkRequiredWriteFailure(state: .running, migrateRowID: true)
    }

    /// Plant: retain unconditional startup persistence for a current journal.
    func testCurrentReadOnlyHistoryLoadsButAnOrdinaryMutationStillFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(state: .issues)
        try fixture.write([record])
        let before = try fixture.snapshot()
        try fixture.makeStoreReadOnly()
        defer { fixture.restorePermissions() }

        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(journal.persistenceError)
        XCTAssertEqual(journal.records.first?.state, .issues)
        XCTAssertThrowsError(try journal.cancel(id: record.id, summary: "Owned test cancellation"))
        XCTAssertEqual(journal.records.first?.state, .issues)
        XCTAssertNotNil(journal.persistenceError)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    /// Plant: remove persistence from TransferJournal.commit after skipping startup writes.
    func testOrdinaryMutationStillPersistsAndSubsequentOpenDoesNotRewriteIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(state: .issues)
        try fixture.write([record])
        let before = try fixture.snapshot()
        do {
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertEqual(try fixture.snapshot(), before)
            try journal.cancel(id: record.id, summary: "Cancelled owned synthetic attempt")
            XCTAssertEqual(journal.records.first?.state, .cancelled)
            XCTAssertEqual(journal.records.first?.results.map(\.id), record.results.map(\.id))
        }
        let changed = try fixture.snapshot()
        XCTAssertNotEqual(changed.bytes, before.bytes)
        let reopened = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(reopened.persistenceError)
        XCTAssertEqual(reopened.records.first?.state, .cancelled)
        XCTAssertEqual(reopened.records.first?.summary, "Cancelled owned synthetic attempt")
        XCTAssertNotNil(reopened.records.first?.endedAt)
        XCTAssertEqual(reopened.records.first?.results.map(\.id), record.results.map(\.id))
        XCTAssertEqual(try fixture.snapshot(), changed)
    }

    /// Plant: swallow malformed UUID decoding as a request to generate a new ID.
    func testMalformedIDsAndPartiallyDecodedLegacyRowsNeverRewriteHistory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(state: .issues, rowCount: 2)
        for malformedID in ["not-a-uuid" as Any, 42, ["wrong": "type"]] {
            var object = try Fixture.object([record])
            var rows = try XCTUnwrap(object[0]["results"] as? [[String: Any]])
            rows[0].removeValue(forKey: "id") // Migration is discovered before the later decode fails.
            rows[1]["id"] = malformedID
            object[0]["results"] = rows
            try fixture.writeObject(object)
            let before = try fixture.snapshot()
            do {
                let journal = TransferJournal(fileURL: fixture.journal)
                XCTAssertNotNil(journal.persistenceError)
                XCTAssertTrue(journal.records.isEmpty)
                XCTAssertThrowsError(try journal.cancel(id: record.id))
                XCTAssertEqual(try fixture.snapshot(), before)
            }
        }
    }

    /// Plant: omit the lifetime flock when no startup rewrite is required.
    func testNoWriteStartupRetainsExclusiveJournalOwnership() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.write([fixture.record(state: .queued)])
        let before = try fixture.snapshot()
        let first = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(first.persistenceError)
        let second = TransferJournal(fileURL: fixture.journal)
        XCTAssertNotNil(second.persistenceError)
        XCTAssertTrue(second.records.isEmpty)
        XCTAssertEqual(try fixture.snapshot(), before)
        withExtendedLifetime(first) {}
    }

    /// Plant: make ResultRow's legacy decoder require a journal migration context.
    func testDirectLegacyRowDecodingRemainsAvailableWithoutLeakingMigrationState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(state: .issues)
        var rowObject = try XCTUnwrap(Fixture.object([record])[0]["results"] as? [[String: Any]])[0]
        rowObject.removeValue(forKey: "id")
        let legacyBytes = try JSONSerialization.data(withJSONObject: rowObject)
        let first = try JSONDecoder().decode(ResultRow.self, from: legacyBytes)
        let second = try JSONDecoder().decode(ResultRow.self, from: legacyBytes)
        XCTAssertNotEqual(first.id, second.id, "Direct decoding has no durable journal in which to save an ID")
        XCTAssertEqual(first.path, record.results[0].path)
        XCTAssertEqual(first.status, record.results[0].status)

        try fixture.write([record])
        let before = try fixture.snapshot()
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(journal.persistenceError)
        XCTAssertEqual(journal.records.first?.results.first?.id, record.results.first?.id)
        XCTAssertEqual(try fixture.snapshot(), before, "An unrelated decoder must not mark this journal for migration")
    }

    private func checkRunningRecovery(migrateRowID: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(state: .running)
        try fixture.write([original], missingIDs: migrateRowID ? [0] : [])
        let before = try fixture.snapshot()
        let recovered: LocalTransferRecord
        do {
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertNil(journal.persistenceError)
            recovered = try XCTUnwrap(journal.records.first)
            XCTAssertEqual(recovered.id, original.id)
            XCTAssertEqual(recovered.state, .interrupted)
            XCTAssertNotNil(recovered.endedAt)
            XCTAssertTrue(recovered.summary.contains("Interrupted"))
            XCTAssertEqual(recovered.results.map(\.path), original.results.map(\.path))
            XCTAssertEqual(recovered.results.map(\.status), original.results.map(\.status))
            if !migrateRowID { XCTAssertEqual(recovered.results[0].id, original.results[0].id) }
        }
        let after = try fixture.snapshot()
        XCTAssertNotEqual(after.bytes, before.bytes)
        let persisted = try XCTUnwrap(JSONDecoder().decode([LocalTransferRecord].self, from: after.bytes).first)
        XCTAssertEqual(try Fixture.canonical([persisted]), try Fixture.canonical([recovered]))
        let reopened = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(reopened.persistenceError)
        XCTAssertEqual(try Fixture.canonical(reopened.records), try Fixture.canonical([recovered]))
        XCTAssertEqual(try fixture.snapshot(), after)
    }

    private func checkRequiredWriteFailure(state: LocalTransferState, migrateRowID: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try fixture.record(state: state)
        try fixture.write([original], missingIDs: migrateRowID ? [0] : [])
        let before = try fixture.snapshot()
        try fixture.makeStoreReadOnly()
        defer { fixture.restorePermissions() }
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertNotNil(journal.persistenceError)
        let visible = try XCTUnwrap(journal.records.first)
        XCTAssertEqual(visible.state, state == .running ? .interrupted : state)
        if state == .running { XCTAssertNotNil(visible.endedAt) }
        XCTAssertThrowsError(try journal.cancel(id: original.id))
        XCTAssertEqual(try fixture.snapshot(), before)
    }
}

private extension JournalStartupPersistenceTests {
    struct FileSnapshot: Equatable {
        let bytes: Data
        let device: Int32
        let inode: UInt64
        let modificationSeconds: Int
        let modificationNanoseconds: Int
    }

    struct Fixture {
        let root: URL
        let store: URL
        let journal: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-journal-startup-\(UUID())", isDirectory: true)
            store = root.appendingPathComponent("store", isDirectory: true)
            journal = store.appendingPathComponent("history.json")
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Pre-create the actual lock so a read-only directory can still
            // acquire it; only the subsequent atomic journal write must fail.
            try Data().write(to: journal.appendingPathExtension("lock"), options: .withoutOverwriting)
        }

        func record(state: LocalTransferState, rowCount: Int = 2) throws -> LocalTransferRecord {
            func resource(_ name: String) throws -> LocalTransferResource {
                let json: [String: Any] = ["url": root.appendingPathComponent(name).absoluteString, "bookmark": ""]
                return try JSONDecoder().decode(LocalTransferResource.self,
                    from: JSONSerialization.data(withJSONObject: json))
            }
            let source = try resource("Owned synthetic card")
            let destination = try resource("Owned synthetic backup")
            var reports = ReportPrefs()
            reports.operatorName = "Synthetic operator"
            reports.notes = "Retained synthetic evidence"
            var record = LocalTransferRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                source: source, destinations: [destination], verificationMode: .standard,
                cameraSettings: .init(), reportSettings: reports, generateASCMHL: false,
                independentDestinationCount: 1)
            record.state = state
            if state != .queued { record.startedAt = Date(timeIntervalSince1970: 1_700_000_010) }
            if state != .running && state != .queued { record.endedAt = Date(timeIntervalSince1970: 1_700_000_020) }
            record.summary = "Synthetic \(state.rawValue) attempt"
            record.results = (0..<rowCount).map { index in
                ResultRow(path: "CLIPS/clip-\(index).MOV", status: ResultOutcome.failed.statusText,
                    size: Int64(index + 1), checksum: "synthetic-checksum-\(index)", destination: "Owned synthetic backup",
                    destinationPath: destination.url.appendingPathComponent("CLIPS/clip-\(index).MOV").path,
                    wasReused: index == 0)
            }
            record.plannedFileCounts = [rowCount]
            record.estimatedSourceBytes = Int64(rowCount * 20)
            record.copyDurationSeconds = 3
            record.verifyDurationSeconds = 2
            record.performanceTelemetry = TransferPerformanceTelemetry(copyDurationSeconds: 3, verifyDurationSeconds: 2)
            record.sourceFingerprint = "synthetic-fingerprint"
            return record
        }

        static func canonical(_ records: [LocalTransferRecord]) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(records)
        }

        static func object(_ records: [LocalTransferRecord]) throws -> [[String: Any]] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: canonical(records)) as? [[String: Any]])
        }

        func write(_ records: [LocalTransferRecord], missingIDs: Set<Int> = [], nullIDs: Set<Int> = []) throws {
            var recordsObject = try Self.object(records)
            for recordIndex in recordsObject.indices {
                var rows = try XCTUnwrap(recordsObject[recordIndex]["results"] as? [[String: Any]])
                for index in rows.indices {
                    if missingIDs.contains(index) { rows[index].removeValue(forKey: "id") }
                    if nullIDs.contains(index) { rows[index]["id"] = NSNull() }
                }
                recordsObject[recordIndex]["results"] = rows
            }
            try writeObject(recordsObject)
        }

        func writeObject(_ object: [[String: Any]]) throws {
            // Pretty JSON proves that a no-op open preserves bytes instead of
            // merely rewriting semantically equivalent sorted compact JSON.
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: journal)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                                                 ofItemAtPath: journal.path)
        }

        func snapshot() throws -> FileSnapshot {
            var info = stat()
            XCTAssertEqual(lstat(journal.path, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
            return try FileSnapshot(bytes: Data(contentsOf: journal), device: info.st_dev, inode: info.st_ino,
                modificationSeconds: info.st_mtimespec.tv_sec, modificationNanoseconds: info.st_mtimespec.tv_nsec)
        }

        func makeStoreReadOnly() throws {
            XCTAssertEqual(chmod(store.path, 0o500), 0)
            if access(store.path, W_OK) == 0 {
                restorePermissions()
                throw XCTSkip("This host cannot enforce write denial on the owned read-only fixture directory")
            }
        }

        func restorePermissions() {
            XCTAssertEqual(chmod(store.path, 0o700), 0)
        }

        func cleanup() {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Owned journal fixture cleanup failed: \(error)") }
        }
    }
}
