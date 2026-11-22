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
        rows: [ResultRow] = [],
        state: LocalTransferState = .completed
    ) throws -> LocalTransferRecord {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceFaultLineage-\(UUID().uuidString)")
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: try resource(root.appendingPathComponent("card")),
            destinations: [try resource(root.appendingPathComponent("backup"))],
            verificationMode: .standard, cameraSettings: .init(),
            reportSettings: ReportPrefs(), generateASCMHL: false, retryOf: retryOf)
        record.state = state
        record.results = rows
        return record
    }

    private func failedRowWithoutReason() -> ResultRow {
        ResultRow(path: "CLIPS/clip.MOV", status: ResultOutcome.failed.statusText,
                  size: 4, checksum: nil, destination: "backup")
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
        #expect(SourceFaultLineage.assess(for: retry, in: [retry, first])
            == .priorFaultFound([.init(attemptID: first.id, reasons: [ResultFailureReason.sourceReadFailed.rawValue])]))
    }

    @Test func faultsTraverseMultipleLinksOldestFirst() throws {
        let first = try record(rows: [faultRow(.sourceUnstable)])
        let second = try record(retryOf: first.id, rows: [faultRow(.sourceReadFailed)])
        let third = try record(retryOf: second.id, rows: [successRow()])
        let faults = SourceFaultLineage.assess(for: third, in: [third, second, first]).faults
        #expect(faults.map(\.attemptID) == [first.id, second.id])
    }

    @Test func nonSourceFailuresAndSuccessesDoNotWarn() throws {
        let first = try record(rows: [faultRow(.outOfSpace), successRow()])
        let retry = try record(retryOf: first.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: retry, in: [retry, first]) == .noFaultObserved)
        // A successful row carrying a reason token is not a fault.
        let clean = try record(rows: [ResultRow(
            path: "CLIPS/clip.MOV", status: ResultOutcome.verified.statusText,
            size: 4, checksum: "abc", destination: "backup",
            failureReason: ResultFailureReason.sourceUnstable.rawValue)])
        let afterClean = try record(retryOf: clean.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: afterClean, in: [afterClean, clean]) == .noFaultObserved)
    }

    @Test func assessmentDistinguishesCompleteFromBrokenChains() throws {
        // No retry link at all: the chain is trivially complete.
        let standalone = try record(rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: standalone, in: [standalone]) == .noFaultObserved)

        // A faulted predecessor, fully reachable.
        let first = try record(rows: [faultRow(.sourceUnstable)])
        let retry = try record(retryOf: first.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: retry, in: [retry, first])
            == .priorFaultFound([.init(attemptID: first.id, reasons: [ResultFailureReason.sourceUnstable.rawValue])]))

        // A retry whose predecessor is gone: unknown, not "no fault".
        let orphan = try record(retryOf: UUID(), rows: [successRow()])
        let orphanAssessment = SourceFaultLineage.assess(for: orphan, in: [orphan])
        #expect(orphanAssessment == .lineageIncomplete([]))
        #expect(orphanAssessment.preventsSafeToEraseClaim)
        #expect(orphanAssessment.faults.isEmpty)
    }

    @Test func missingPredecessorAndCyclesStopWithoutClaiming() throws {
        let orphan = try record(retryOf: UUID(), rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: orphan, in: [orphan]).faults.isEmpty)

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
        // The cycle terminates; the one reachable fault is still reported,
        // and the assessment says the chain was never fully walked.
        #expect(SourceFaultLineage.assess(for: second, in: [second, first]).faults.count == 1)
        #expect(SourceFaultLineage.assess(for: second, in: [second, first]).preventsSafeToEraseClaim)
        if case .lineageIncomplete(let faults) = SourceFaultLineage.assess(for: second, in: [second, first]) {
            #expect(faults.count == 1)
        } else {
            Issue.record("Expected lineageIncomplete for a cyclic chain")
        }
    }

    /// An attempt that failed before this release wrote reason tokens, or
    /// that failed before producing rows, says nothing about the card. It
    /// is unknown, never clean.
    @Test(arguments: [LocalTransferState.failed, .interrupted, .issues])
    func unclassifiedUnsuccessfulPredecessorIsIncompleteNotClean(state: LocalTransferState) throws {
        let first = try record(rows: [], state: state)
        let retry = try record(retryOf: first.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: retry, in: [retry, first]) == .lineageIncomplete([]))
    }

    @Test func failedRowWithoutReasonIsIncompleteNotClean() throws {
        let first = try record(rows: [failedRowWithoutReason()], state: .issues)
        let retry = try record(retryOf: first.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: retry, in: [retry, first]) == .lineageIncomplete([]))
    }

    /// A cancellation is the person's choice, not a card fault, and a
    /// classified non-source failure says the card read fine.
    @Test func cancelledAndNonSourceFailuresStillCountAsWalked() throws {
        let cancelled = try record(rows: [], state: .cancelled)
        let outOfSpace = try record(retryOf: cancelled.id, rows: [faultRow(.outOfSpace)], state: .issues)
        let retry = try record(retryOf: outOfSpace.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: retry, in: [retry, outOfSpace, cancelled]) == .noFaultObserved)
    }

    @Test func chainOfExactlyTheLimitCompletesAndOneMoreDoesNot() throws {
        var records: [LocalTransferRecord] = [try record(rows: [successRow()])]
        for _ in 0..<SourceFaultLineage.maximumLinks {
            records.append(try record(retryOf: records.last!.id, rows: [successRow()]))
        }
        // records.last has exactly maximumLinks predecessors.
        #expect(SourceFaultLineage.assess(for: records.last!, in: records) == .noFaultObserved)
        records.append(try record(retryOf: records.last!.id, rows: [successRow()]))
        #expect(SourceFaultLineage.assess(for: records.last!, in: records) == .lineageIncomplete([]))
    }

    /// The card failed during the final check, after every file had been
    /// published as verified. The interrupted record carries only
    /// successful rows and no reason, so it must read as unknown.
    @Test(arguments: [LocalTransferState.interrupted, .failed])
    func unfinishedPredecessorWithOnlySuccessfulRowsIsIncomplete(state: LocalTransferState) throws {
        let first = try record(rows: [successRow()], state: state)
        let retry = try record(retryOf: first.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: retry, in: [retry, first]) == .lineageIncomplete([]))
    }

    /// A failed attempt that explains itself with a non-source reason is
    /// classified: the card read fine, the backup did not.
    @Test func failedPredecessorWithClassifiedNonSourceReasonIsWalked() throws {
        let first = try record(rows: [successRow(), faultRow(.outOfSpace)], state: .failed)
        let retry = try record(retryOf: first.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: retry, in: [retry, first]) == .noFaultObserved)
    }

    /// A failure explained on the record itself: "not connected" never read
    /// the card and counts as walked; a record-level source read failure is
    /// a prior fault.
    @Test func recordLevelReasonsClassifyRowlessFailures() throws {
        var notConnected = try record(rows: [], state: .failed)
        notConnected.failureReason = ResultFailureReason.sourceNotConnected.rawValue
        let afterNotConnected = try record(retryOf: notConnected.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: afterNotConnected, in: [afterNotConnected, notConnected]) == .noFaultObserved)

        var unreadable = try record(rows: [], state: .failed)
        unreadable.failureReason = ResultFailureReason.sourceReadFailed.rawValue
        let afterUnreadable = try record(retryOf: unreadable.id, rows: [successRow()])
        #expect(SourceFaultLineage.assess(for: afterUnreadable, in: [afterUnreadable, unreadable])
            == .priorFaultFound([.init(attemptID: unreadable.id, reasons: [ResultFailureReason.sourceReadFailed.rawValue])]))
    }
}
