import Foundation
import Testing
@testable import BitMatchEngine

struct SourceFaultLineageTests {
    private func resource(_ url: URL) throws -> LocalTransferResource {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try LocalTransferResource(url: url)
    }

    private func record(
        retryOf: UUID? = nil,
        rows: [ResultRow] = []
    ) throws -> LocalTransferRecord {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceFaultLineage-\(UUID().uuidString)")
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: try resource(root.appendingPathComponent("card")),
            destinations: [try resource(root.appendingPathComponent("backup"))],
            verificationMode: .standard, cameraSettings: .init(),
            reportSettings: ReportPrefs(), generateASCMHL: false, retryOf: retryOf)
        record.state = .completed
        record.results = rows
        return record
    }

    private func faultRow(_ reason: ResultFailureReason) -> ResultRow {
        ResultRow(path: "CLIPS/clip.MOV", status: ResultOutcome.failed.statusText,
                  size: 4, checksum: nil, destination: "backup", failureReason: reason.rawValue)
    }

    private func successRow() -> ResultRow {
        ResultRow(path: "CLIPS/clip.MOV", status: ResultOutcome.verified.statusText,
                  size: 4, checksum: "abc", destination: "backup")
    }

    @Test func verifiedRetryKeepsEarlierSourceFault() throws {
        let first = try record(rows: [faultRow(.sourceReadFailed)])
        let retry = try record(retryOf: first.id, rows: [successRow()])
        #expect(SourceFaultLineage.hasPriorSourceFault(for: retry, in: [retry, first]))
        #expect(SourceFaultLineage.priorSourceFaults(for: retry, in: [retry, first])
            == [.init(attemptID: first.id, reasons: [ResultFailureReason.sourceReadFailed.rawValue])])
    }

    @Test func faultsTraverseMultipleLinksOldestFirst() throws {
        let first = try record(rows: [faultRow(.sourceUnstable)])
        let second = try record(retryOf: first.id, rows: [faultRow(.sourceReadFailed)])
        let third = try record(retryOf: second.id, rows: [successRow()])
        let faults = SourceFaultLineage.priorSourceFaults(for: third, in: [third, second, first])
        #expect(faults.map(\.attemptID) == [first.id, second.id])
    }

    @Test func nonSourceFailuresAndSuccessesDoNotWarn() throws {
        let first = try record(rows: [faultRow(.outOfSpace), successRow()])
        let retry = try record(retryOf: first.id, rows: [successRow()])
        #expect(!SourceFaultLineage.hasPriorSourceFault(for: retry, in: [retry, first]))
        // A successful row carrying a reason token is not a fault.
        let clean = try record(rows: [ResultRow(
            path: "CLIPS/clip.MOV", status: ResultOutcome.verified.statusText,
            size: 4, checksum: "abc", destination: "backup",
            failureReason: ResultFailureReason.sourceUnstable.rawValue)])
        let afterClean = try record(retryOf: clean.id, rows: [successRow()])
        #expect(!SourceFaultLineage.hasPriorSourceFault(for: afterClean, in: [afterClean, clean]))
    }

    @Test func missingPredecessorAndCyclesStopWithoutClaiming() throws {
        let orphan = try record(retryOf: UUID(), rows: [successRow()])
        #expect(SourceFaultLineage.priorSourceFaults(for: orphan, in: [orphan]).isEmpty)

        let firstID = UUID()
        let secondID = UUID()
        var first = try record(retryOf: secondID, rows: [faultRow(.sourceUnstable)])
        first = LocalTransferRecord(
            id: firstID, createdAt: first.createdAt, source: first.source,
            destinations: first.destinations, verificationMode: .standard,
            cameraSettings: .init(), reportSettings: ReportPrefs(),
            generateASCMHL: false, retryOf: secondID)
        first.results = [faultRow(.sourceUnstable)]
        var second = try record(retryOf: firstID, rows: [successRow()])
        second = LocalTransferRecord(
            id: secondID, createdAt: second.createdAt, source: second.source,
            destinations: second.destinations, verificationMode: .standard,
            cameraSettings: .init(), reportSettings: ReportPrefs(),
            generateASCMHL: false, retryOf: firstID)
        second.results = [successRow()]
        // The cycle terminates; the one reachable fault is still reported.
        #expect(SourceFaultLineage.priorSourceFaults(for: second, in: [second, first]).count == 1)
    }
}
