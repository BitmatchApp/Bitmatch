import CryptoKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

private func reportFact(for url: URL) throws -> ReportFileFact {
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return ReportFileFact(path: url.path, size: UInt64(data.count), modificationDate: nil, sha256: digest)
}

private final class FlushFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var fail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

/// Actual journal I/O over owned temporary metadata and backup fixtures.
final class JournalStartupPersistenceTests: XCTestCase {
    func testStagingCleanupPreservesForeignEntriesAndRemovesOnlyRecordedDigests() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        let staging = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(record.id.uuidString.utf8).write(to: staging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        let name = "BitMatch_Report_2026-11-27T12-00-00Z.pdf"
        let owned = staging.appendingPathComponent(name)
        let foreign = staging.appendingPathComponent("foreign")
        try Data("ours".utf8).write(to: owned)
        try Data("keep".utf8).write(to: foreign)
        var fact = try reportFact(for: owned)
        fact = ReportFileFact(path: reports.appendingPathComponent(name).path, size: fact.size, modificationDate: nil, sha256: fact.sha256)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.reportStagingPath = staging.path
        record.intendedReportFileFacts = [fact]
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [staging.path])
        guard case .pending(let reason) = outcomes[staging.path] else { return XCTFail("Foreign file must remain pending") }
        XCTAssertTrue(reason.contains("unexpected file(s)"), reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }

    func testStagingCleanupRemovesFullyProvenDirectory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup"), reports = backup.appendingPathComponent("Reports")
        let staging = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(record.id.uuidString.utf8).write(to: staging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        let name = "BitMatch_Report_2026-11-27T12-00-00Z.csv", file = staging.appendingPathComponent(name)
        try Data("ours".utf8).write(to: file)
        let fact = try reportFact(for: file)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.reportStagingPath = staging.path
        record.intendedReportFileFacts = [ReportFileFact(path: reports.appendingPathComponent(name).path, size: fact.size, modificationDate: nil, sha256: fact.sha256)]
        XCTAssertEqual(TransferJournal.withdrawReports(record: record, paths: [staging.path])[staging.path], .withdrawn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testStagingRecoveryRerootsAtResolvedDestination() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup"), moved = fixture.root.appendingPathComponent("remounted")
        let staging = backup.appendingPathComponent("Reports/.bitmatch-staging-" + record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(record.id.uuidString.utf8).write(to: staging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        record.destinations = [try LocalTransferResource(url: backup)]
        record.reportStagingPath = staging.path
        try FileManager.default.moveItem(at: backup, to: moved)
        record.runDestinationURLs = [moved]
        guard let access = try? record.destinations[0].beginReadAccess() else {
            throw XCTSkip("This filesystem did not resolve the moved bookmark")
        }
        defer { access.release() }
        guard access.url.standardizedFileURL == moved.standardizedFileURL else {
            throw XCTSkip("This filesystem did not resolve the moved bookmark")
        }
        let result = TransferJournal.withdrawReports(record: record, paths: [staging.path])
        XCTAssertEqual(result[staging.path], .withdrawn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Reports/" + staging.lastPathComponent).path))
    }
    func testNilIdentityReportPublicationReplacementAndWithdrawalUseContainment() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("report.json")
        let pdf = reports.appendingPathComponent("report.pdf")
        let paths = [json.path, pdf.path]
        record.pendingReportPaths = paths
        try TransferJournal.validateReportPublication(record: record, paths: paths, volumeIdentityAt: { _ in nil })
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        try Data("safe".utf8).write(to: pdf)
        try TransferJournal.validateReportPublication(record: record, paths: paths, volumeIdentityAt: { _ in nil })
        try Data("replacement".utf8).write(to: pdf)
        let outcomes = TransferJournal.withdrawReports(record: record, paths: paths, volumeIdentityAt: { _ in nil })
        XCTAssertEqual(outcomes[json.path], .withdrawn)
        XCTAssertEqual(outcomes[pdf.path], .withdrawn)
        record.pendingWithdrawalPaths = paths
        let recovered = await TransferJournal.recoverPendingWithdrawals(record)
        XCTAssertNil(recovered.pendingWithdrawalPaths)
        XCTAssertTrue(recovered.summary.lowercased().contains("destination identity unavailable; matched by path"))
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = reports.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let escaped = link.appendingPathComponent("report.pdf").path
        record.pendingReportPaths = [escaped]
        XCTAssertThrowsError(try TransferJournal.validateReportPublication(record: record, paths: [escaped], volumeIdentityAt: { _ in nil }))
        try FileManager.default.removeItem(at: backup)
        XCTAssertThrowsError(try TransferJournal.validateReportPublication(record: record, paths: paths, volumeIdentityAt: { _ in nil }))
    }

    func testStagingRecoveryReadsAndCleansInsideReportAccess() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        let staging = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(record.id.uuidString.utf8).write(to: staging.appendingPathComponent(TransferJournal.stagingOwnerMarker))
        let json = reports.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json"), pdf = reports.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: staging.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json"))
        try Data("ours".utf8).write(to: pdf)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.runSourceURL = nil
        record.pendingReportPaths = [json.path, pdf.path]
        record.reportStagingPath = staging.path
        let stagedFact = try reportFact(for: staging.appendingPathComponent(json.lastPathComponent))
        record.intendedReportFileFacts = [ReportFileFact(path: json.path, size: stagedFact.size, modificationDate: nil, sha256: stagedFact.sha256)]
        record.reportFileFacts = [try reportFact(for: pdf)]
        record.pendingWithdrawalPaths = [json.path, pdf.path, staging.path]
        var depth = 0
        var stagingChecks = 0
        let outcomes = TransferJournal.withdrawReports(record: record, paths: record.pendingWithdrawalPaths!,
            volumeIdentityAt: { _ in record.destinations[0].volumeID },
            reportAccessChanged: { depth += $0 ? 1 : -1 },
            beforeStagingAccess: { _ in
                stagingChecks += 1
                guard depth > 0 else { throw NSError(domain: "Outside report access", code: 1) }
            })
        XCTAssertEqual(outcomes[pdf.path], .withdrawn)
        XCTAssertEqual(outcomes[staging.path], .withdrawn)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertGreaterThanOrEqual(stagingChecks, 2)
        XCTAssertEqual(depth, 0)
    }

    func testWithdrawalStopsAfter64OccupiedHiddenNames() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup"), reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("report.json"), pdf = reports.appendingPathComponent("report.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        try Data("safe".utf8).write(to: pdf)
        record.pendingReportPaths = [json.path, pdf.path]
        for suffix in 0..<64 {
            let name = ReportName.withdrawnName(report: pdf.lastPathComponent, recordID: record.id, collision: suffix)
            try Data("foreign".utf8).write(to: reports.appendingPathComponent(name))
        }
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [pdf.path], volumeIdentityAt: { _ in record.destinations[0].volumeID })
        guard case .pending(let reason) = outcomes[pdf.path] else { return XCTFail("Expected pending withdrawal") }
        XCTAssertTrue(reason.contains("No free hidden report name was found"), reason)
        XCTAssertEqual(try Data(contentsOf: pdf), Data("safe".utf8))
    }

    func testCancelledWithdrawalLeavesReportPending() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup"), reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("report.json"), pdf = reports.appendingPathComponent("report.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        try Data("safe".utf8).write(to: pdf)
        record.pendingReportPaths = [json.path, pdf.path]
        let snapshot = record
        let outcome = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return TransferJournal.withdrawReports(record: snapshot, paths: [pdf.path],
                volumeIdentityAt: { _ in snapshot.destinations[0].volumeID })[pdf.path]
        }.value
        guard case .pending(let reason) = outcome else { return XCTFail("Cancelled withdrawal must remain pending") }
        XCTAssertTrue(reason.contains("withdrawal was cancelled"), reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
    }

    func testLegacyStagingPathDecodesIntoSet() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let record = try fixture.record(state: .running)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["reportStagingPath"] = "/backup/Reports/old"
        json.removeValue(forKey: "reportStagingPaths")
        let decoded = try JSONDecoder().decode(LocalTransferRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.reportStagingPaths, ["/backup/Reports/old"])
    }

    func testSecondExportKeepsUnreadableFirstStagingAcrossRelaunch() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("card"), backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let history = fixture.root.appendingPathComponent("wave8p-history.json")
        let paths: [String]
        let first: URL
        do {
            let journal = TransferJournal(fileURL: history, recoverReportsOnInit: false)
            let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                cameraSettings: .init(), reportSettings: .init())
            try journal.markRunning(id: id)
            first = backup.appendingPathComponent("Reports/.bitmatch-staging-" + id.uuidString)
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            let marker = first.appendingPathComponent(TransferJournal.stagingOwnerMarker)
            try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
            try Data("safe".utf8).write(to: first.appendingPathComponent("retained.pdf"))
            try journal.recordPendingReportPaths(id: id, paths: [first.path])
            let removedStaging = Mutex<[String]>([])
            let date = Date()
            do {
                _ = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: nil,
                    results: [], finished: date, checksumAlgorithm: nil, jobID: id, started: date, duration: 1,
                    sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
                    prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none,
                    safeToErase: true, recordIntendedPaths: { try journal.recordPendingReportPaths(id: id, paths: $0) },
                    didRemoveStaging: { path in removedStaging.withLock { $0.append(path) } },
                    beforePublish: { _ in throw NSError(domain: "stop", code: 1) })
                XCTFail("Expected publication to stop")
            } catch {
                XCTAssertEqual((error as NSError).domain, "stop")
            }
            paths = try XCTUnwrap(journal.records.first?.reportStagingPaths)
            XCTAssertEqual(paths.count, 2)
            XCTAssertTrue(paths.contains(first.path))
            XCTAssertTrue(paths.contains(first.path + "-2"))
            let removed = removedStaging.withLock { $0 }
            XCTAssertEqual(removed, [first.path + "-2"])
            try journal.interrupt(id: id, summary: "Publication stopped", removedStagingPaths: removed)
            XCTAssertEqual(journal.records.first?.reportStagingPaths, [first.path])
        }
        let reopened = TransferJournal(fileURL: history)
        XCTAssertNil(reopened.persistenceError)
        XCTAssertEqual(reopened.records.first?.reportStagingPaths, [first.path])
        XCTAssertTrue(reopened.records.first?.pendingWithdrawalPaths?.contains(first.path) == true)
        var markerIsDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent(TransferJournal.stagingOwnerMarker).path, isDirectory: &markerIsDirectory))
        XCTAssertTrue(markerIsDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("retained.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path + "-2"))
    }

    func testStartupVisitsEveryRecordedStagingDirectory() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup"), reports = backup.appendingPathComponent("Reports")
        let first = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
        let second = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString + "-2")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(record.id.uuidString.utf8).write(to: folder.appendingPathComponent(TransferJournal.stagingOwnerMarker))
            try Data("safe".utf8).write(to: folder.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.pdf"))
        }
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let fact = try reportFact(for: first.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.pdf"))
        record.intendedReportFileFacts = [ReportFileFact(path: reports.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.pdf").path, size: fact.size, modificationDate: nil, sha256: fact.sha256)]
        record.reportStagingPaths = [first.path, second.path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(journal.records[0].reportStagingPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testWithdrawalFIFOIsPendingWithReason() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup"), reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.runSourceURL = nil
        let json = reports.appendingPathComponent("report.json"), pdf = reports.appendingPathComponent("report.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        XCTAssertEqual(mkfifo(pdf.path, 0o600), 0)
        record.pendingReportPaths = [json.path, pdf.path]
        let finished = expectation(description: "FIFO withdrawal returns")
        let result = Mutex<TransferJournal.ReportWithdrawalOutcome?>(nil)
        let snapshot = record
        DispatchQueue.global().async {
            let outcomes = TransferJournal.withdrawReports(record: snapshot, paths: [pdf.path], volumeIdentityAt: { _ in snapshot.destinations[0].volumeID })
            result.withLock { $0 = outcomes[pdf.path] }
            finished.fulfill()
        }
        let completion = XCTWaiter.wait(for: [finished], timeout: 1)
        if completion != .completed {
            // Release a blocked FIFO reader so a failing regression cannot strand the test process.
            let writer = open(pdf.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { _ = close(writer) }
        }
        XCTAssertEqual(completion, .completed)
        guard case .pending(let reason) = result.withLock({ $0 }) else { return XCTFail("FIFO must stay pending") }
        XCTAssertTrue(reason.contains("not a regular file"), reason)
        XCTAssertTrue(reason.contains("left in place"), reason)
    }

    func testWithdrawalReadFailureAfterHashIsNotReportedAsChange() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup"), reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.runSourceURL = nil
        let json = reports.appendingPathComponent("report.json"), pdf = reports.appendingPathComponent("report.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        try Data("ours".utf8).write(to: pdf)
        record.pendingReportPaths = [json.path, pdf.path]
        record.reportFileFacts = try [reportFact(for: json), reportFact(for: pdf)]
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [pdf.path], beforeWithdrawalMove: { url in
            try? FileManager.default.removeItem(at: url)
        }, volumeIdentityAt: { _ in record.destinations[0].volumeID })
        guard case .pending(let reason) = outcomes[pdf.path] else { return XCTFail("Unverifiable file must stay pending") }
        XCTAssertTrue(reason.contains("could not be verified"), reason)
        XCTAssertFalse(reason.contains("changed"), reason)
    }

    func testWithdrawalLeavesReplacementAfterHash() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup"), reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        record.runSourceURL = nil
        let json = reports.appendingPathComponent("report.json"), pdf = reports.appendingPathComponent("report.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        try Data("ours".utf8).write(to: pdf)
        record.pendingReportPaths = [json.path, pdf.path]
        record.reportFileFacts = try [reportFact(for: json), reportFact(for: pdf)]
        let replacement = Data("replacement".utf8)
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [pdf.path], beforeWithdrawalMove: { url in
            if url == pdf { try? replacement.write(to: url, options: .atomic) }
        }, volumeIdentityAt: { _ in nil })
        guard case .pending = outcomes[pdf.path] else { return XCTFail("Replacement must remain pending") }
        XCTAssertEqual(try Data(contentsOf: pdf), replacement)
    }

    func testNilIdentityMissingReportsOnReplacementTreeRemainPending() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        let paths = ["report.json", "report.pdf"].map { reports.appendingPathComponent($0).path }
        record.pendingReportPaths = paths
        record.pendingWithdrawalPaths = paths
        try FileManager.default.moveItem(at: backup, to: fixture.root.appendingPathComponent("original-backup"))
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)

        let recovered = await TransferJournal.recoverPendingWithdrawals(record)
        XCTAssertEqual(Set(recovered.pendingWithdrawalPaths ?? []), Set(paths))
        XCTAssertTrue(recovered.withdrawalReason?.contains("destination identity unavailable; cannot confirm the report is gone") == true)
        XCTAssertTrue(recovered.summary.contains("Reports on an unavailable backup may still read safe"))
        XCTAssertTrue(recovered.summary.contains("this backup reports no volume identity"))
        XCTAssertTrue(recovered.summary.contains("will not clear by itself"))
        XCTAssertTrue(recovered.summary.contains("may still read safe"))
    }

    func testMissingStagingClearsWithOwnedPublicOrWithdrawnJSONOnNilIdentity() throws {
        for withdrawn in [false, true] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            var record = try fixture.record(state: .interrupted)
            let backup = fixture.root.appendingPathComponent("backup")
            let reports = backup.appendingPathComponent("Reports")
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
            encoded.removeValue(forKey: "volumeID")
            record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
            record.runDestinationURLs = [backup]
            let json = reports.appendingPathComponent("report.json")
            let staging = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
            let proof = withdrawn ? reports.appendingPathComponent(".unsettled-\(record.id.uuidString)-report.json") : json
            try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: proof)
            record.pendingReportPaths = [json.path]
            record.reportStagingPath = staging.path
            let outcomes = TransferJournal.withdrawReports(record: record, paths: [json.path, staging.path], volumeIdentityAt: { _ in nil })
            XCTAssertEqual(outcomes[staging.path], .absentOnVerifiedBackup)
            XCTAssertEqual(outcomes[json.path], withdrawn ? .absentOnVerifiedBackup : .withdrawn)
        }
    }

    func testNilIdentityPublicationThenFailedCardSaveAndRecoveryWithdrawsStaleStaging() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let source = fixture.root.appendingPathComponent("card"), backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        let now = Date()
        let intended = Mutex<[String]>([])
        let files = try await EvidenceWriter.write(kind: .copyAndVerify, destinationURLs: [backup], pdfData: Data("report".utf8),
            results: [], finished: now, checksumAlgorithm: nil, jobID: record.id, started: now, duration: 1,
            sourceURL: source, fileCount: 0, matchCount: 0, totalBytesProcessed: 0, workers: 1, filesPerSecond: 1,
            prefs: .init(), generateFullReport: true, projectCSV: nil, projectJSON: Optional<String>.none, safeToErase: true,
            recordIntendedPaths: { paths in intended.withLock { $0 = paths } })
        let staging = try XCTUnwrap(intended.withLock { $0.first { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix(".bitmatch-staging-") } })
        record.pendingReportPaths = files.map(\.path)
        record.reportFileFacts = try files.map { try reportFact(for: $0) }
        record.reportStagingPath = staging
        record.pendingWithdrawalPaths = files.map(\.path) + [staging]
        func failedStep() throws { throw NSError(domain: "SimulatedFailure", code: 1) }
        XCTAssertThrowsError(try failedStep(), "Card save failed")
        XCTAssertThrowsError(try failedStep(), "Recovery settlement failed")
        let recovered = await TransferJournal.recoverPendingWithdrawals(record)
        XCTAssertNil(recovered.pendingWithdrawalPaths, recovered.withdrawalReason ?? "")
        XCTAssertNil(recovered.reportStagingPath)
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testForeignWithdrawnJSONCannotProveMissingReportsOrStaging() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup"), reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("report.json")
        let staging = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
        let hidden = reports.appendingPathComponent(".unsettled-\(record.id.uuidString)-report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": UUID().uuidString]).write(to: hidden)
        record.pendingReportPaths = [json.path]
        record.reportStagingPath = staging.path
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [json.path, staging.path], volumeIdentityAt: { _ in nil })
        guard case .pending = outcomes[json.path], case .pending = outcomes[staging.path] else {
            return XCTFail("Foreign proof must not clear either path")
        }
    }

    func testMarkReportsHandledPersistsDateAndKeepsVerdict() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        record.pendingWithdrawalPaths = ["/missing/report.json"]
        record.withdrawalReason = "destination identity unavailable"
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try journal.markReportsHandled(id: record.id, date: date)
        let updated = try XCTUnwrap(journal.records.first)
        XCTAssertNil(updated.pendingWithdrawalPaths)
        XCTAssertNil(updated.withdrawalReason)
        XCTAssertEqual(updated.state, record.state)
        XCTAssertEqual(updated.results.count, record.results.count)
        XCTAssertTrue(updated.summary.contains("reports marked handled by the user on 2023-11-14"))
        let persisted = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: fixture.journal))
        XCTAssertNil(persisted.first?.pendingWithdrawalPaths)
    }

    func testManualHandlingRequiresNoIdentityAndNoOwnershipProof() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded["volumeID"] = "original-volume"
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        record.runSourceURL = nil
        let json = reports.appendingPathComponent("report.json")
        record.pendingReportPaths = [json.path]
        record.pendingWithdrawalPaths = [json.path]
        XCTAssertFalse(TransferJournal.canMarkReportsHandled(record))
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        XCTAssertTrue(TransferJournal.canMarkReportsHandled(record))
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        XCTAssertFalse(TransferJournal.canMarkReportsHandled(record))
        try FileManager.default.moveItem(at: json, to: reports.appendingPathComponent(".unsettled-\(record.id.uuidString)-report.json"))
        XCTAssertFalse(TransferJournal.canMarkReportsHandled(record))
    }

    func testManualHandlingRequiresDestinationAccess() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        record.runSourceURL = nil
        let json = reports.appendingPathComponent("report.json")
        record.pendingReportPaths = [json.path]
        record.pendingWithdrawalPaths = [json.path]
        XCTAssertFalse(TransferJournal.canMarkReportsHandled(record, access: { _, _ in throw LocalTransferJournalError.invalidState }))
        XCTAssertTrue(TransferJournal.canMarkReportsHandled(record))
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        XCTAssertFalse(TransferJournal.canMarkReportsHandled(record))
    }

    func testLateWithdrawalIsRecordedAfterUserHandledReports() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var snapshot = try fixture.record(state: .interrupted)
        let path = "/missing/Volume. Name/report.pdf"
        snapshot.pendingWithdrawalPaths = [path]
        var recovered = snapshot
        recovered.pendingWithdrawalPaths = nil
        recovered.summary += " Unsettled reports were withdrawn: \(path)."
        recovered.lastWithdrawnReportPaths = [path]
        let current = TransferJournal.markingReportsHandled(snapshot)
        let merged = TransferJournal.mergeWithdrawalRecovery(current: current, snapshot: snapshot, recovered: recovered)
        XCTAssertTrue(merged.summary.contains(path))
        XCTAssertTrue(merged.summary.contains("withdrawn after the user marked them handled"))
        XCTAssertTrue(merged.summary.contains("may still read safe"))
    }

    func testRetryAfterWithdrawalJournalWriteFailsUsesWithdrawnOwnershipJSON() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("report.json"), pdf = reports.appendingPathComponent("report.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        try Data("report".utf8).write(to: pdf)
        record.pendingReportPaths = [json.path, pdf.path]
        record.reportFileFacts = try [json, pdf].map { try reportFact(for: $0) }
        record.pendingWithdrawalPaths = record.pendingReportPaths
        try fixture.write([record])
        let gate = FlushFailureGate()
        let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false,
            afterJournalRename: { if gate.fail { throw NSError(domain: "Flush", code: 1) } })
        gate.fail = true
        XCTAssertThrowsError(try journal.retryPendingReportWithdrawals(id: record.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
        let withdrawnJSON = reports.appendingPathComponent(".unsettled-\(record.id.uuidString)-report.json")
        XCTAssertEqual(try reportFact(for: withdrawnJSON).sha256, record.reportFileFacts?.first { $0.path == json.path }?.sha256)
        gate.fail = false
        try journal.retryPendingReportWithdrawals(id: record.id)
        XCTAssertNil(journal.records.first?.pendingWithdrawalPaths)
    }

    func testNilIdentityOwnedJSONAllowsMissingStemMemberToClear() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalTransferResource(url: backup))) as? [String: Any])
        encoded.removeValue(forKey: "volumeID")
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: encoded))]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("report.json")
        let missing = reports.appendingPathComponent("report.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        let paths = [json.path, missing.path]
        record.pendingReportPaths = paths
        let outcomes = TransferJournal.withdrawReports(record: record, paths: paths, volumeIdentityAt: { _ in nil })
        XCTAssertEqual(outcomes[json.path], .withdrawn)
        XCTAssertEqual(outcomes[missing.path], .absentOnVerifiedBackup)
    }
    func testStartupWithdrawsFreshStemAndStagingButKeepsForeignOriginalPending() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let foreign = reports.appendingPathComponent("old.json")
        let fresh = reports.appendingPathComponent("fresh.json")
        let pdf = reports.appendingPathComponent("fresh.pdf")
        let staging = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
        try Data("foreign".utf8).write(to: foreign)
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: fresh)
        try Data("safe".utf8).write(to: pdf)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Data(record.id.uuidString.utf8).write(to: staging.appendingPathComponent(".bitmatch-owner"))
        try Data("safe".utf8).write(to: staging.appendingPathComponent("fresh.pdf"))
        record.pendingReportPaths = [foreign.path, fresh.path, pdf.path]
        record.reportStagingPath = staging.path
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(Set(journal.records[0].pendingWithdrawalPaths ?? []), Set([foreign.path, staging.path]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testStartupUsesStagedJSONToWithdrawPartialPublication() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        let staging = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json")
        let pdf = reports.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.pdf")
        try Data("safe".utf8).write(to: pdf)
        try Data(record.id.uuidString.utf8).write(to: staging.appendingPathComponent(".bitmatch-owner"))
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: staging.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json"))
        record.pendingReportPaths = [json.path, pdf.path]
        record.reportStagingPath = staging.path
        let stagedFact = try reportFact(for: staging.appendingPathComponent(json.lastPathComponent))
        record.intendedReportFileFacts = [ReportFileFact(path: json.path, size: stagedFact.size, modificationDate: nil, sha256: stagedFact.sha256)]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(journal.records[0].pendingWithdrawalPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testForeignStagingIsNeverRemoved() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let staging = backup.appendingPathComponent("Reports/.bitmatch-staging-" + record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: staging.appendingPathComponent("keep"))
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.reportStagingPath = staging.path
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [staging.path])
        guard case .pending = outcomes[staging.path] else { return XCTFail("Foreign staging must remain pending") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("keep").path))
    }

    func testPendingPublicWithdrawalKeepsOwnedStagingProof() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        let staging = reports.appendingPathComponent(".bitmatch-staging-" + record.id.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(record.id.uuidString.utf8).write(to: staging.appendingPathComponent(".bitmatch-owner"))
        let pdf = reports.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.pdf"), json = reports.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json")
        try Data("safe".utf8).write(to: pdf)
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: staging.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json"))
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.pendingReportPaths = [pdf.path, json.path]
        record.reportStagingPath = staging.path
        let stagedFact = try reportFact(for: staging.appendingPathComponent(json.lastPathComponent))
        record.intendedReportFileFacts = [ReportFileFact(path: json.path, size: stagedFact.size, modificationDate: nil, sha256: stagedFact.sha256)]
        let first = TransferJournal.withdrawReports(record: record, paths: [pdf.path, json.path, staging.path], volumeIdentityAt: { _ in "different" })
        guard case .pending = first[staging.path] else { return XCTFail("Proof must stay while withdrawal is pending") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("BitMatch_Report_2026-11-27T12-00-00Z.json").path))
        let second = TransferJournal.withdrawReports(record: record, paths: [pdf.path, json.path, staging.path])
        XCTAssertEqual(second[pdf.path], .withdrawn)
        XCTAssertEqual(second[staging.path], .withdrawn)
    }

    func testWithdrawalMergeKeepsNewPendingPathsAndRecordsActualOutcome() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var snapshot = try fixture.record(state: .interrupted)
        snapshot.summary = "Keep the card"
        snapshot.pendingWithdrawalPaths = ["/backup/old.json"]
        var recovered = snapshot
        recovered.pendingWithdrawalPaths = nil
        recovered.summary += " Unsettled reports were withdrawn: /backup/old.json."
        var current = snapshot
        current.pendingWithdrawalPaths = ["/backup/old.json", "/backup/new.json"]
        current.withdrawalReason = "New report unavailable"
        let merged = TransferJournal.mergeWithdrawalRecovery(current: current, snapshot: snapshot, recovered: recovered)
        XCTAssertEqual(merged.pendingWithdrawalPaths, ["/backup/new.json"])
        XCTAssertTrue(merged.summary.contains("withdrawn: /backup/old.json"))
        XCTAssertTrue(merged.summary.contains("/backup/new.json"))
        XCTAssertEqual(merged.withdrawalReason, "New report unavailable")
    }
    func testWithdrawalMergePreservesPeriodSpaceInPendingPath() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var snapshot = try fixture.record(state: .interrupted)
        snapshot.summary = "Keep the card"
        snapshot.pendingWithdrawalPaths = ["/backup/old.json"]
        var recovered = snapshot
        recovered.pendingWithdrawalPaths = nil
        recovered.summary += " Unsettled reports were withdrawn: /backup/old.json."
        var current = snapshot
        current.pendingWithdrawalPaths = ["/backup/old.json", "/backup/Volume. Name/report.json"]
        current.withdrawalReason = "Unavailable"
        let merged = TransferJournal.mergeWithdrawalRecovery(current: current, snapshot: snapshot, recovered: recovered)
        XCTAssertEqual(merged.pendingWithdrawalPaths, ["/backup/Volume. Name/report.json"])
        XCTAssertTrue(merged.pendingWithdrawalNote?.contains("/backup/Volume. Name/report.json") == true)
    }
    func testFinishThrowsWhenDirectoryFlushFailsAfterPublication() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let gate = FlushFailureGate()
        let source = fixture.root.appendingPathComponent("card")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let id: UUID
        do {
            let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false,
                afterJournalRename: { if gate.fail { throw NSError(domain: "Flush", code: 1) } })
            id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                cameraSettings: .init(), reportSettings: .init())
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: [1])
            let row = ResultRow(path: source.appendingPathComponent("clip.mov").path,
                status: ResultOutcome.verified.statusText, size: 4, checksum: "abc",
                destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("clip.mov").path)
            gate.fail = true
            XCTAssertThrowsError(try journal.finish(id: id, results: [row], summary: "Finished", hadIssues: false)) {
                XCTAssertTrue($0 is FlushAfterPublishFailure)
            }
            XCTAssertEqual(journal.records.first { $0.id == id }?.state, .running)
            XCTAssertNotNil(journal.persistenceError)
        }
        let reopened = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        XCTAssertEqual(reopened.records.first { $0.id == id }?.state, .interrupted, "An unconfirmed flush must remain unsafe after restart")
        XCTAssertTrue(reopened.records.first { $0.id == id }?.summary.lowercased().contains("interrupted") == true)
        let marker = fixture.store.appendingPathComponent(".\(fixture.journal.lastPathComponent).settling-\(id.uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFlushedMarkerForLandedRecordSurvivesFailedMarkerRemoval() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("card")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let id: UUID
        do {
            let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false,
                beforeSettlementMarkerRemoval: { throw NSError(domain: "MarkerRemoval", code: 1) })
            id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: [1])
            let row = ResultRow(path: source.appendingPathComponent("clip.mov").path,
                status: ResultOutcome.verified.statusText, size: 4, checksum: "abc",
                destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("clip.mov").path)
            try journal.finish(id: id, results: [row], summary: "Finished", hadIssues: false)
            let marker = fixture.store.appendingPathComponent(".\(fixture.journal.lastPathComponent).settling-\(id.uuidString)")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
            XCTAssertEqual(object["phase"] as? String, "flushed")
        }
        let reopened = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        XCTAssertEqual(reopened.records.first { $0.id == id }?.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.appendingPathComponent(".\(fixture.journal.lastPathComponent).settling-\(id.uuidString)").path))
    }

    func testFailedFlushedRestampRecoversAsInterrupted() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("card")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let id: UUID
        do {
            let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false,
                afterFlushedMarkerRename: { throw NSError(domain: "MarkerFlush", code: 1) })
            id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: [1])
            let row = ResultRow(path: source.appendingPathComponent("clip.mov").path,
                status: ResultOutcome.verified.statusText, size: 4, checksum: "abc",
                destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("clip.mov").path)
            XCTAssertThrowsError(try journal.finish(id: id, results: [row], summary: "Finished", hadIssues: false))
            XCTAssertEqual(journal.records.first { $0.id == id }?.state, .running)
            // Model a failed rollback too: a visibly flushed marker must not
            // defeat the durable writing-phase witness left by the failure.
            let marker = fixture.store.appendingPathComponent(".\(fixture.journal.lastPathComponent).settling-\(id.uuidString)")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
            object["phase"] = "flushed"
            try JSONSerialization.data(withJSONObject: object).write(to: marker)
        }
        let reopened = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        XCTAssertEqual(reopened.records.first { $0.id == id }?.state, .interrupted)
    }

    func testSettlementMarkerWithOldRecordRecoversConservatively() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let gate = FlushFailureGate()
        let source = fixture.root.appendingPathComponent("card")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let id: UUID
        do {
            let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false,
                afterJournalRename: { if gate.fail { throw NSError(domain: "Flush", code: 1) } })
            id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: [1])
            let old = try Data(contentsOf: fixture.journal)
            let row = ResultRow(path: source.appendingPathComponent("clip.mov").path,
                status: ResultOutcome.verified.statusText, size: 4, checksum: "abc",
                destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("clip.mov").path)
            gate.fail = true
            XCTAssertThrowsError(try journal.finish(id: id, results: [row], summary: "Finished", hadIssues: false))
            try old.write(to: fixture.journal)
        }
        let reopened = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        XCTAssertEqual(reopened.records.first { $0.id == id }?.state, .interrupted)
    }

    func testSettlementMarkerForDifferentCompletedRevisionRecoversConservatively() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let gate = FlushFailureGate()
        let source = fixture.root.appendingPathComponent("card")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let id: UUID
        do {
            let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false,
                afterJournalRename: { if gate.fail { throw NSError(domain: "Flush", code: 1) } })
            id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: [1])
            let row = ResultRow(path: source.appendingPathComponent("clip.mov").path,
                status: ResultOutcome.verified.statusText, size: 4, checksum: "abc",
                destination: backup.lastPathComponent, destinationPath: backup.appendingPathComponent("clip.mov").path)
            gate.fail = true
            XCTAssertThrowsError(try journal.finish(id: id, results: [row], summary: "Finished", hadIssues: false))
            let marker = fixture.store.appendingPathComponent(".\(fixture.journal.lastPathComponent).settling-\(id.uuidString)", isDirectory: false)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
            object["phase"] = "flushed"
            try JSONSerialization.data(withJSONObject: object).write(to: marker)
            var records = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: fixture.journal))
            records[0].summary = "Older completed revision"
            try JSONEncoder().encode(records).write(to: fixture.journal)
        }
        let reopened = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        XCTAssertEqual(reopened.records.first { $0.id == id }?.state, .interrupted)
    }

    func testWithdrawalKeepsPathsPendingWhenWholeDestinationIsUnavailableOrReplaced() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let offline = fixture.root.appendingPathComponent("offline")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("report.json")
        let pdf = reports.appendingPathComponent("report.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        try Data("safe".utf8).write(to: pdf)
        let paths = [json.path, pdf.path]
        record.pendingReportPaths = paths
        try FileManager.default.moveItem(at: backup, to: offline)
        // A replacement at the old path must never be touched.
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: pdf)
        // Simulate a disconnected volume even if macOS follows the moved folder's bookmark.
        var resource = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record.destinations[0])) as? [String: Any])
        resource["volumeID"] = "different-volume"
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: resource))]
        let outcomes = TransferJournal.withdrawReports(record: record, paths: paths)
        for path in paths {
            guard case .pending = outcomes[path] else { return XCTFail("Expected pending for \(path)") }
        }
        XCTAssertEqual(try Data(contentsOf: pdf), Data("replacement".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: offline.appendingPathComponent("Reports/report.json").path))
    }

    func testReportParentOnDifferentVolumeNeverProvesAbsence() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let path = reports.appendingPathComponent("report.json").path
        record.pendingReportPaths = [path]
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [path], volumeIdentityAt: { _ in "different-volume" })
        guard case .pending = outcomes[path] else { return XCTFail("A different report volume must remain pending") }
    }

    func testReportPublicationRejectsDifferentParentVolume() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let resource = try LocalTransferResource(url: backup)
        record.destinations = [resource]
        record.runDestinationURLs = [backup]
        let report = reports.appendingPathComponent("report.json")
        let sentinel = Data("replacement volume".utf8)
        try sentinel.write(to: report)
        record.pendingReportPaths = [report.path]
        XCTAssertThrowsError(try TransferJournal.validateReportPublication(record: record, paths: [report.path],
            volumeIdentityAt: { _ in "different-volume" }))
        XCTAssertEqual(try Data(contentsOf: report), sentinel)
        XCTAssertNoThrow(try TransferJournal.validateReportPublication(record: record, paths: [report.path],
            volumeIdentityAt: { _ in resource.volumeID }))
    }

    func testExistingReportOnDifferentVolumeIsNotWithdrawn() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let resource = try LocalTransferResource(url: backup)
        record.destinations = [resource]
        record.runDestinationURLs = [backup]
        let json = backup.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        record.pendingReportPaths = [json.path]
        let outcomes = TransferJournal.withdrawReports(record: record, paths: [json.path], volumeIdentityAt: { url in
            url.lastPathComponent == "report.json" ? "different-volume" : resource.volumeID
        })
        guard case .pending = outcomes[json.path] else { return XCTFail("Report on a different volume must remain pending") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
    }

    func testAbsentAndWithdrawnReportsHaveDistinctHistoryEvidence() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = backup.appendingPathComponent("report.json")
        let missing = backup.appendingPathComponent("missing.pdf")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        record.pendingReportPaths = [json.path, missing.path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        let summary = journal.records[0].summary
        XCTAssertTrue(summary.contains("withdrawn"))
        XCTAssertTrue(summary.contains("found absent on the verified backup"))
        XCTAssertTrue(summary.contains(json.path))
        XCTAssertTrue(summary.contains(missing.path))
    }

    func testMissingReportParentStaysPending() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let path = backup.appendingPathComponent("missing/report.json").path
        record.pendingReportPaths = [path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(journal.records[0].pendingWithdrawalPaths, [path])
        XCTAssertNotNil(journal.records[0].withdrawalReason)
    }

    func testUnreadableJSONAndOwnershipMismatchRemainPendingWithReasons() throws {
        for contents in [Data("{half-written".utf8), try JSONSerialization.data(withJSONObject: ["jobId": UUID().uuidString])] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            var record = try fixture.record(state: .running)
            let backup = fixture.root.appendingPathComponent("backup")
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            record.destinations = [try LocalTransferResource(url: backup)]
            record.runDestinationURLs = [backup]
            let json = backup.appendingPathComponent("report.json")
            let pdf = backup.appendingPathComponent("different.pdf")
            try contents.write(to: json); try Data("safe".utf8).write(to: pdf)
            record.pendingReportPaths = [json.path, pdf.path]
            try fixture.write([record])
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertEqual(Set(journal.records[0].pendingWithdrawalPaths ?? []), Set([json.path, pdf.path]))
            XCTAssertTrue(journal.records[0].summary.contains("report.json"))
            XCTAssertNotNil(journal.records[0].withdrawalReason)
        }
    }

    func testOwnershipReadFailureStaysPending() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = backup.appendingPathComponent("report.json")
        try FileManager.default.createDirectory(at: json, withIntermediateDirectories: false)
        record.pendingReportPaths = [json.path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(journal.records[0].pendingWithdrawalPaths, [json.path])
        XCTAssertTrue(journal.records[0].withdrawalReason?.contains("could not be read") == true)
        XCTAssertTrue(journal.records[0].withdrawalReason?.contains(json.resolvingSymlinksInPath().path) == true)
    }

    func testRetryMapsRecordedAndRunRootsThroughSymlinkAliases() throws {
        for recordedThroughAlias in [true, false] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            var record = try fixture.record(state: .interrupted)
            let backup = fixture.root.appendingPathComponent("backup")
            let alias = fixture.root.appendingPathComponent("backup-alias")
            let reports = backup.appendingPathComponent("Reports")
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backup)
            record.destinations = [try LocalTransferResource(url: backup)]
            record.runDestinationURLs = [recordedThroughAlias ? backup : alias]
            let paths = ["report.csv", "report.sha-256.txt", "report.pdf", "report.json"].map {
                (recordedThroughAlias ? alias : backup).appendingPathComponent("Reports/" + $0)
            }
            for path in paths {
                let data = path.pathExtension == "json"
                    ? try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString])
                    : Data("safe".utf8)
                try data.write(to: path)
            }
            record.pendingReportPaths = paths.map(\.path)
            record.pendingWithdrawalPaths = paths.map(\.path)
            try fixture.write([record])
            let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
            try journal.retryPendingReportWithdrawals(id: record.id)
            XCTAssertNil(journal.records[0].pendingWithdrawalPaths, journal.records[0].withdrawalReason ?? "")
            for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), path.path) }
        }
    }

    func testRecordedJSONFallbackRequiresConfirmedReportsFolder() throws {
        for folder in ["Reports", "Other"] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            var record = try fixture.record(state: .interrupted)
            let backup = fixture.root.appendingPathComponent("backup")
            let directory = backup.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            record.destinations = [try LocalTransferResource(url: backup)]
            record.runDestinationURLs = [backup]
            let json = directory.appendingPathComponent("report.json")
            try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
            record.pendingReportPaths = [json.path]
            record.pendingWithdrawalPaths = [json.path]
            // Model a saved mapping that cannot be re-rooted.
            record.relativeReportPaths = []
            try fixture.write([record])
            let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
            try journal.retryPendingReportWithdrawals(id: record.id)
            if folder == "Reports" {
                XCTAssertNil(journal.records[0].pendingWithdrawalPaths)
                XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
            } else {
                XCTAssertEqual(journal.records[0].pendingWithdrawalPaths, [json.path])
                XCTAssertTrue(journal.records[0].withdrawalReason?.contains(json.path) == true)
                XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
            }
        }
    }

    func testUnknownLegacyOperationIDIsNotAssumedToProveOwnership() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = backup.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": UUID().uuidString]).write(to: json)
        record.pendingReportPaths = [json.path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(journal.records[0].pendingWithdrawalPaths, [json.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
    }

    func testLegacyOperationIDReportAndExplicitDifferentlyNamedPathsAreWithdrawn() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let operationID = UUID()
        record.operationID = operationID
        let paths = ["report-2.json", "report.pdf", "other.sha256.txt"].map { backup.appendingPathComponent($0) }
        try JSONSerialization.data(withJSONObject: ["jobId": operationID.uuidString]).write(to: paths[0])
        for path in paths.dropFirst() { try Data("safe".utf8).write(to: path) }
        record.pendingReportPaths = paths.map(\.path)
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(journal.records[0].pendingWithdrawalPaths)
        for path in paths { XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)) }
    }

    func testAsyncRetryRunsIOOffMainThread() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = backup.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        record.pendingReportPaths = [json.path]
        record.pendingWithdrawalPaths = [json.path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        try await journal.retryPendingReportWithdrawalsAsync(id: record.id, beforeIO: {
            XCTAssertFalse(Thread.isMainThread)
        })
        XCTAssertNil(journal.records[0].pendingWithdrawalPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
    }

    @MainActor
    func testRetryWithdrawsEveryRecordedReportAfterFolderReturnsWithNonstandardPaths() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .interrupted)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        let offline = backup.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let names = ["report.csv", "report.sha-256.txt", "report.pdf", "report.json"]
        for name in names {
            let data = name.hasSuffix(".json")
                ? try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString])
                : Data("safe".utf8)
            try data.write(to: reports.appendingPathComponent(name))
        }
        let paths = names.map { backup.path + "/./Reports/" + $0 }
        record.pendingReportPaths = paths
        record.pendingWithdrawalPaths = paths
        try fixture.write([record])
        try FileManager.default.moveItem(at: reports, to: offline)
        let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        try await journal.retryPendingReportWithdrawalsAsync(id: record.id)
        XCTAssertEqual(Set(journal.records[0].pendingWithdrawalPaths ?? []), Set(paths))
        try FileManager.default.moveItem(at: offline, to: reports)
        try await journal.retryPendingReportWithdrawalsAsync(id: record.id)
        XCTAssertNil(journal.records[0].pendingWithdrawalPaths)
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(atPath: reports.appendingPathComponent(name).path), name)
        }
    }

    func testKnownPublicationIDMustMatchOwnershipJSON() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.reportPublicationID = UUID()
        let json = backup.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        record.pendingReportPaths = [json.path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(journal.records[0].pendingWithdrawalPaths, [json.path])
        XCTAssertTrue(journal.records[0].withdrawalReason?.contains("ownership does not match") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
    }

    func testInterruptedWritePersistsFailedWithdrawalAndRetries() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("card")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: fixture.journal, recoverReportsOnInit: false)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let json = backup.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": id.uuidString, "source": ["path": source.path]]).write(to: json)
        try journal.recordPendingReportPaths(id: id, paths: [json.path])
        try journal.interrupt(id: id, summary: "Keep the card", pendingWithdrawalReason: "backup unavailable")
        XCTAssertEqual(journal.records[0].pendingWithdrawalPaths, [json.path])
        try journal.retryPendingReportWithdrawals(id: id)
        XCTAssertNil(journal.records[0].pendingWithdrawalPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
    }

    func testReportPathsAreSavedRelativeToTheRunDestination() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("card")
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let journal = TransferJournal(fileURL: fixture.journal)
        let id = try journal.enqueue(sourceURL: source, destinationURLs: [backup], verificationMode: .standard,
                                     cameraSettings: .init(), reportSettings: .init())
        try journal.markRunning(id: id)
        let path = backup.appendingPathComponent("Reports/report.json").path
        try journal.recordPendingReportPaths(id: id, paths: [path])
        let decoded = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: fixture.journal))
        XCTAssertEqual(decoded[0].relativeReportPaths?.first?.path, "Reports/report.json")
        XCTAssertEqual(decoded[0].relativeReportPaths?.first?.destinationIndex, 0)
    }
    func testStartupWithdrawsReportsRecordedByRunningAttempt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let reports = ["report.json", "report.pdf", "report.sha256.txt"].map { backup.appendingPathComponent($0) }
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: reports[0])
        for report in reports.dropFirst() { try Data("safe".utf8).write(to: report) }
        record.pendingReportPaths = reports.map(\.path)
        try fixture.write([record])

        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(journal.records.first?.state, .interrupted)
        XCTAssertTrue(journal.records.first?.summary.contains("withdrawn") == true)
        for report in reports {
            XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: report.deletingLastPathComponent().appendingPathComponent(".unsettled-" + record.id.uuidString + "-" + report.lastPathComponent).path))
        }
    }

    func testRecoveryLeavesAnotherRunsReportsUntouched() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = backup.appendingPathComponent("report.json")
        let pdf = backup.appendingPathComponent("report.pdf")
        let bytes = try JSONSerialization.data(withJSONObject: ["jobId": UUID().uuidString])
        try bytes.write(to: json); try Data("other".utf8).write(to: pdf)
        record.pendingReportPaths = [json.path, pdf.path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(try Data(contentsOf: json), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertTrue(journal.records[0].summary.contains("ownership does not match"))
        XCTAssertFalse(journal.records[0].pendingWithdrawalPaths?.isEmpty ?? true)
    }

    func testRecoveryRejectsMatchingJobWithDifferentRunSource() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        record.runSourceURL = fixture.root.appendingPathComponent("card")
        let json = backup.appendingPathComponent("report.json")
        let pdf = backup.appendingPathComponent("report.pdf")
        let bytes = try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString, "source": ["path": "/different-card"]])
        try bytes.write(to: json); try Data("other".utf8).write(to: pdf)
        record.pendingReportPaths = [json.path, pdf.path]
        try fixture.write([record])
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(try Data(contentsOf: json), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertTrue(journal.records[0].summary.contains("ownership does not match"))
        XCTAssertFalse(journal.records[0].pendingWithdrawalPaths?.isEmpty ?? true)
    }

    func testPendingWithdrawalSurvivesRestartUntilFolderReturns() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let folder = backup.appendingPathComponent("Reports")
        let offline = backup.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = folder.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        record.pendingReportPaths = [json.path]
        try fixture.write([record])
        try FileManager.default.moveItem(at: folder, to: offline)
        do {
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertFalse(journal.records[0].pendingWithdrawalPaths?.isEmpty ?? true)
        }
        try FileManager.default.moveItem(at: offline, to: folder)
        let reopened = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(reopened.records[0].pendingWithdrawalPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
        XCTAssertEqual(reopened.records[0].state, .interrupted)
    }

    func testPartialWithdrawalRetainsProofAndRetriesRemainingSibling() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = backup.appendingPathComponent("report.json")
        let folder = backup.appendingPathComponent("pdfs")
        let offline = backup.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("report.pdf")
        let jsonData = try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString, "safeToErase": true])
        try jsonData.write(to: json)
        try Data("safe pdf".utf8).write(to: pdf)
        record.pendingReportPaths = [json.path, pdf.path]
        record.reportFileFacts = try [json, pdf].map { try reportFact(for: $0) }
        try fixture.write([record])
        try FileManager.default.moveItem(at: folder, to: offline)
        let withdrawnJSON = backup.appendingPathComponent(".unsettled-\(record.id.uuidString)-report.json")
        do {
            let journal = TransferJournal(fileURL: fixture.journal)
            XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
            XCTAssertEqual(try Data(contentsOf: withdrawnJSON), jsonData)
            XCTAssertEqual(journal.records[0].pendingWithdrawalPaths, [pdf.path])
        }
        let reopened = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(reopened.records[0].pendingWithdrawalPaths, [pdf.path])
        try FileManager.default.moveItem(at: offline, to: folder)
        try reopened.retryPendingReportWithdrawals(id: record.id)
        XCTAssertNil(reopened.records[0].pendingWithdrawalPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
    }

    func testUnavailableBookmarkLeavesWithdrawalPendingUntilOriginalResourceReturns() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("external-backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let original = try LocalTransferResource(url: backup)
        // An unavailable external security-scoped bookmark models a drive
        // absent when iPhone/iPad restores its journal.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["bookmark"] = ""
        record.destinations = [try JSONDecoder().decode(LocalTransferResource.self, from: JSONSerialization.data(withJSONObject: object))]
        record.runDestinationURLs = [backup]
        let json = backup.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        record.pendingReportPaths = [json.path]
        try fixture.write([record])
        var pending: LocalTransferRecord
        do {
            let journal = TransferJournal(fileURL: fixture.journal)
            pending = try XCTUnwrap(journal.records.first)
            XCTAssertFalse(pending.pendingWithdrawalPaths?.isEmpty ?? true)
            XCTAssertTrue(pending.summary.contains("may still read safe"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        }
        pending.destinations = [original]
        try fixture.write([pending])
        let reopened = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(reopened.records[0].pendingWithdrawalPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
    }

    func testAbsentBackupRemainsPendingAndIsRetriedWhenRecordLoads() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let reports = backup.appendingPathComponent("Reports")
        let offline = backup.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let json = reports.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: json)
        record.pendingReportPaths = [json.path]
        try fixture.write([record])
        try FileManager.default.moveItem(at: reports, to: offline)
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(journal.records[0].state, .interrupted)
        XCTAssertFalse(journal.records[0].pendingWithdrawalPaths?.isEmpty ?? true)
        XCTAssertTrue(journal.records[0].summary.contains("may still read safe"))
        try FileManager.default.moveItem(at: offline, to: reports)
        try journal.retryPendingReportWithdrawals(id: record.id)
        XCTAssertNil(journal.records[0].pendingWithdrawalPaths)
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
    }

    func testMovedBackupIsResolvedAndReplacementAtOldPathIsUntouched() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var record = try fixture.record(state: .running)
        let backup = fixture.root.appendingPathComponent("backup")
        let moved = fixture.root.appendingPathComponent("remounted")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        record.destinations = [try LocalTransferResource(url: backup)]
        record.runDestinationURLs = [backup]
        let original = backup.appendingPathComponent("report.json")
        try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString]).write(to: original)
        record.pendingReportPaths = [original.path]
        try fixture.write([record])
        try FileManager.default.moveItem(at: backup, to: moved)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let replacement = try JSONSerialization.data(withJSONObject: ["jobId": record.id.uuidString])
        try replacement.write(to: original)
        let resolved = try? record.destinations[0].beginReadAccess()
        let resolvesMoved = resolved?.url.standardizedFileURL == moved.standardizedFileURL
        resolved?.release()
        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(try Data(contentsOf: original), replacement)
        if resolvesMoved {
            XCTAssertNil(journal.records[0].pendingWithdrawalPaths)
            XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("report.json").path))
        } else {
            XCTAssertFalse(journal.records[0].pendingWithdrawalPaths?.isEmpty ?? true)
            XCTAssertTrue(journal.records[0].summary.contains("may still read safe"))
        }
    }

    func testReportPublicationFailureDowngradesCompletedHistoryDurably() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(state: .completed, rowCount: 1)
        try fixture.write([record])
        do {
            let journal = TransferJournal(fileURL: fixture.journal)
            try journal.recordReportPublicationFailure(id: record.id, summary: "Report export failed; keep the card.")
            XCTAssertEqual(journal.records.first?.state, .issues)
            XCTAssertNil(journal.records.first?.expectedExclusionQueueQualification)
        }
        let reopened = TransferJournal(fileURL: fixture.journal)
        XCTAssertEqual(reopened.records.first?.state, .issues)
        XCTAssertEqual(reopened.records.first?.summary, "Report export failed; keep the card.")
    }

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

    /// Plant: write the journal with `Data.write(.atomic)` again, or leave the
    /// flushed temporary file behind after the rename.
    func testStartupPersistenceLeavesOnlyTheJournalAndItsLockInTheStore() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(state: .issues, rowCount: 2)
        try fixture.write([record], missingIDs: [0])

        let journal = TransferJournal(fileURL: fixture.journal)
        XCTAssertNil(journal.persistenceError)
        XCTAssertEqual(journal.records.count, 1)

        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.store.path).sorted()
        XCTAssertEqual(names, ["history.json", "history.json.lock"], "No temporary journal file may remain after a flushed write")
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
