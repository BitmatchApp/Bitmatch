import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct QueueSessionPresentationTests {
    @Test func rowsKeepQueueOrderAndRunningHeaderUsesFinished() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let safe = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let running = try fixture.record(name: "A002", state: .running, at: 2)
        let waiting = try fixture.record(name: "A003", state: .queued, at: 3)
        let progress = OperationProgress(
            overallProgress: 0.42, currentFile: "clip.mov", filesProcessed: 4, totalFiles: 10,
            currentStage: .copying, speed: nil, elapsedTime: nil, averageSpeed: nil,
            peakSpeed: nil, bytesProcessed: nil, totalBytes: nil, stageProgress: 0.42
        )

        let presentation = QueueSessionPresentation.make(
            records: [waiting, running, safe], sessionIDs: Set([safe.id, running.id, waiting.id]),
            progress: progress, mountedSourceIDs: Set([safe.id])
        )

        #expect(presentation.rows.map(\.cardName) == ["A001", "A002", "A003"])
        #expect(presentation.headerTitle == "Copying A002")
        #expect(presentation.headerDetail == "1 finished · 1 waiting")
        #expect(presentation.rows[0].action == .eject)
        #expect(presentation.rows[1].safetyState == .copying(progress: 42))
        #expect(presentation.rows[2].action == nil)
    }

    @Test func waitingQueueDoesNotPretendItAlreadyStopped() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let first = try fixture.record(name: "A001", state: .queued, at: 1)
        let second = try fixture.record(name: "A002", state: .queued, at: 2)
        let presentation = QueueSessionPresentation.make(
            records: [second, first], sessionIDs: [first.id, second.id],
            progress: nil, mountedSourceIDs: [first.id, second.id]
        )

        #expect(presentation.summaryTitle == nil)
        #expect(!presentation.showsQueueSummary)
        #expect(presentation.tally.text == "2 not started")
    }

    @Test func tallyAndActionsPreserveEverySafetyClass() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let safe = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let quick = try fixture.record(name: "A002", state: .issues, mode: .quick, outcome: .copiedUnverified, at: 2)
        let attention = try fixture.record(name: "A003", state: .issues, outcome: .failed, summary: "3 files failed on Shuttle B", at: 3)
        let failed = try fixture.record(name: "A004", state: .failed, summary: "A004 is not connected", at: 4)
        let interrupted = try fixture.record(name: "A005", state: .interrupted, summary: "Cancelled", at: 5)
        let waiting = try fixture.record(name: "A006", state: .queued, at: 6)
        let records = [waiting, interrupted, failed, attention, quick, safe]

        let presentation = QueueSessionPresentation.make(
            records: records, sessionIDs: Set(records.map(\.id)), progress: nil,
            mountedSourceIDs: Set([safe.id, quick.id, attention.id, failed.id, interrupted.id, waiting.id])
        )

        #expect(presentation.tally.text == "1 safe to erase · 1 copied, not verified · 1 needs attention · 1 failed · 1 interrupted · 1 not started")
        #expect(presentation.summaryTitle == "Queue stopped")
        #expect(presentation.ejectableCardIDs == [safe.id])
        #expect(presentation.rows.map(\.action) == [.eject, .review, .review, .review, .review, nil])
        #expect(!presentation.rows.dropFirst().contains { $0.safetyState.tint == .green })
    }

    @Test func finishedSummaryCopyTextAndEjectCountUseOnlyMountedSafeCards() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let first = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let second = try fixture.record(name: "A002", state: .completed, outcome: .verified, at: 2)
        let issue = try fixture.record(name: "A003", state: .issues, outcome: .failed, summary: "1 file failed on Shuttle A", at: 3)
        let records = [issue, second, first]
        let finishedAt = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 26, hour: 18, minute: 42
        )))

        let presentation = QueueSessionPresentation.make(
            records: records, sessionIDs: Set(records.map(\.id)), progress: nil,
            mountedSourceIDs: Set([first.id, issue.id]), now: finishedAt
        )

        #expect(presentation.summaryTitle == "Queue finished")
        #expect(presentation.ejectButtonTitle == "Eject 1 Verified Card")
        #expect(presentation.ejectableCardIDs == [first.id])
        let lines = presentation.copySummary.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Queue finished 18:42 ·"))
        #expect(lines[0].contains(presentation.tally.text))
        #expect(lines[1].contains("A001") && lines[1].contains("safe to erase"))
        // Backup identity deliberately prefers the volume over a temporary-folder
        // path (see backupIdentityPrefersTheVolumeAndNeverATemporaryPath), so a
        // fixture backup under the temp directory reports its volume name here.
        let expectedDrive = DestinationIdentityPresentation.title(for: fixture.backup)
        #expect(lines[3].contains("needs attention: 1 file failed on \(expectedDrive)"))
    }

    @Test func pauseBannerUsesOnlyThePausedRecordAndNamesItsState() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let failed = try fixture.record(name: "A001", state: .failed, summary: "Disconnected", at: 1)
        let interrupted = try fixture.record(name: "A002", state: .interrupted, summary: "Cancelled", at: 2)
        let records = [interrupted, failed]
        let presentation = QueueSessionPresentation.make(
            records: records, sessionIDs: Set(records.map(\.id)), progress: nil,
            mountedSourceIDs: [], pausedRecordID: interrupted.id
        )
        #expect(presentation.pausedCardID == interrupted.id)
        #expect(presentation.pausedTitle == "Queue paused — A002 was interrupted")
        #expect(presentation.pausedCause == "Cancelled")
    }

    @Test func stoppedAndUnfinishedCopySummaryUseTheirActualTitles() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let failed = try fixture.record(name: "A001", state: .failed, summary: "Disconnected", at: 1)
        let waiting = try fixture.record(name: "A002", state: .queued, at: 2)
        let stopped = QueueSessionPresentation.make(
            records: [waiting, failed], sessionIDs: [failed.id, waiting.id], progress: nil, mountedSourceIDs: []
        )
        let waitingOnly = QueueSessionPresentation.make(
            records: [waiting], sessionIDs: [waiting.id], progress: nil, mountedSourceIDs: []
        )
        #expect(stopped.copySummary.hasPrefix("Queue stopped "))
        #expect(waitingOnly.copySummary.hasPrefix("Queue "))
        #expect(!waitingOnly.copySummary.hasPrefix("Queue finished"))
        #expect(waitingOnly.ejectDisabledReason == "No verified cards are still connected.")
    }

    @Test func accessibilityStatusCombinesCardStateCauseAndSafetyWarning() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let failed = try fixture.record(name: "A004", state: .failed, summary: "Card disconnected", at: 1)
        let row = try #require(QueueSessionPresentation.make(
            records: [failed], sessionIDs: [failed.id], progress: nil, mountedSourceIDs: []
        ).rows.first)
        #expect(row.accessibilityStatus == "A004, Failed — do not erase, not safe to erase, Card disconnected")
    }

    @Test func zeroByteQueueEvidenceUsesEmptyWording() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(name: "A001", state: .completed, outcome: .verified, size: 0, at: 1)
        let row = try #require(QueueSessionPresentation.make(
            records: [record], sessionIDs: [record.id], progress: nil, mountedSourceIDs: [record.id]
        ).rows.first)
        #expect(row.evidence == "Empty · 1 file")
        #expect(!row.evidence!.contains("Zero KB"))
    }

    @Test func pauseCommandAndDockResolutionPoliciesAreFailSafe() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let issue = try fixture.record(name: "A003", state: .failed, summary: "A003 is not connected", at: 1)
        let retry = try fixture.record(name: "A003", state: .completed, outcome: .verified, at: 2)
        let rowsBefore = QueueSessionPresentation.make(
            records: [issue], sessionIDs: [issue.id], progress: nil, mountedSourceIDs: []
        ).rows
        let rowsAfter = QueueSessionPresentation.make(
            records: [retry, issue], sessionIDs: [issue.id, retry.id], progress: nil, mountedSourceIDs: [retry.id]
        ).rows

        #expect(!QueueCommandPolicy.canRunQueue(isPausedOnProblem: true, waitingCount: 2))
        #expect(QueueCommandPolicy.canRunQueue(isPausedOnProblem: false, waitingCount: 2))
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: rowsBefore, reviewedIDs: []) == 1)
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: rowsBefore, reviewedIDs: [issue.id]) == 0)
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: rowsAfter, reviewedIDs: []) == 0)
    }

    @Test func autoQueueUsesOnlyOneCandidateForEachNewVolumeIdentity() {
        let card = ConnectedDrivesPresentation.Volume(
            name: "A004", url: URL(fileURLWithPath: "/Volumes/A004"), totalBytes: 64, freeBytes: 32,
            isRemovable: true, isInternal: false, volumeID: "card-4", cameraName: "Alexa"
        )
        let backup = ConnectedDrivesPresentation.Volume(
            name: "Shuttle", url: URL(fileURLWithPath: "/Volumes/Shuttle"), totalBytes: 1_000, freeBytes: 500,
            isRemovable: true, isInternal: false, volumeID: "backup"
        )
        let remountedFirstCard = ConnectedDrivesPresentation.Volume(
            name: "A004", url: URL(fileURLWithPath: "/Volumes/A004 1"), totalBytes: 64, freeBytes: 32,
            isRemovable: true, isInternal: false, volumeID: "card-4", cameraName: "Alexa"
        )
        let rows = ConnectedDrivesPresentation.make(
            volumes: [card, backup, remountedFirstCard], sourceURL: nil, destinationURLs: []
        )
        #expect(AutoQueuePolicy.candidates(
            eligibleRows: rows, seenVolumeIDs: [], activeDestinationVolumeIDs: ["backup"]
        ).map(\.volumeID) == ["card-4"])
        #expect(AutoQueuePolicy.candidates(
            eligibleRows: rows, seenVolumeIDs: ["card-4"], activeDestinationVolumeIDs: []
        ).isEmpty)
    }

    @Test func dockBadgeIncludesStandaloneAttentionSinceLaunch() {
        #expect(QueueDockBadgePolicy.totalUnresolvedCount(
            rows: [], reviewedIDs: [], standaloneAttentionCount: 2
        ) == 2)
    }
}

private final class QueuePresentationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backup: URL

    init() throws {
        backup = root.appendingPathComponent("Shuttle A")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func record(
        name: String,
        state: LocalTransferState,
        mode: VerificationMode = .standard,
        outcome: ResultOutcome? = nil,
        size: Int64 = 64,
        summary: String = "Ready",
        at seconds: TimeInterval
    ) throws -> LocalTransferRecord {
        let source = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: seconds),
            source: try LocalTransferResource(url: source), destinations: [try LocalTransferResource(url: backup)],
            verificationMode: mode, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        record.state = state
        record.summary = summary
        if let outcome {
            record.results = [ResultRow(
                path: source.appendingPathComponent("clip.mov").path,
                status: outcome.statusText, size: size, checksum: outcome == .verified ? "abc" : nil,
                destination: "Shuttle A", destinationPath: backup.appendingPathComponent("clip.mov").path
            )]
        }
        return record
    }
}
