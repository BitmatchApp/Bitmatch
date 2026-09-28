import Foundation
import Testing
@testable import BitMatch_iPad
import BitMatchEngine

struct QueueAccessoryPresentationTests {
    @Test func emptyQueueIsHidden() {
        #expect(QueueAccessoryPresentation.make(queue: queue([])) == .hidden)
    }

    @Test func runningQueueShowsCardPositionOverallPercentAndTimeLeft() {
        let rows = [
            row("A001", state: .safeToErase),
            row("B002", state: .copying(progress: 50), progress: 0.5),
            row("C003", state: .waiting)
        ]
        let result = QueueAccessoryPresentation.make(
            queue: queue(rows),
            timeRemaining: "12 min"
        )

        #expect(result.title == "B002")
        #expect(result.detail == "2 of 3 · 50% · 12 min left")
        #expect(result.tone == .progress)
    }

    @Test func safeToEraseFlashTemporarilyReplacesRunningProgress() {
        let safe = row("A001", state: .safeToErase)
        let result = QueueAccessoryPresentation.make(
            queue: queue([safe, row("B002", state: .copying(progress: 20), progress: 0.2)]),
            flashedSafeRecordID: safe.id
        )

        #expect(result.title == "A001 · safe to erase")
        #expect(result.tone == .safeToErase)
    }

    @Test func failureAndReasonPersistAheadOfSafeFlash() {
        let failed = row("A001", state: .failed, cause: "Backup disconnected")
        let safe = row("B002", state: .safeToErase)
        let result = QueueAccessoryPresentation.make(
            queue: queue([failed, safe]),
            flashedSafeRecordID: safe.id,
            acknowledgedAttention: QueueAccessoryPresentation.attentionTokens(in: [failed])
        )

        #expect(result.title == "A001 · failed")
        #expect(result.detail == "Backup disconnected")
        #expect(result.tone == .failure)
        #expect(result.attentionRecordID == failed.id)
    }

    @Test func allVerifiedCardsSayAllCardsSafeToErase() {
        let result = QueueAccessoryPresentation.make(queue: queue([
            row("A001", state: .safeToErase),
            row("B002", state: .safeToErase)
        ]))

        #expect(result.title == "All cards safe to erase")
        #expect(result.detail == "2 of 2 verified")
        #expect(result.tone == .safeToErase)
    }

    @Test func warningStatesRemainVisible() {
        for state in [CardSafetyState.needsAttention, .copiedNotVerified, .interrupted] {
            let result = QueueAccessoryPresentation.make(queue: queue([
                row("A001", state: state, cause: "Check the transfer")
            ]))
            #expect(result.tone == .warning)
            #expect(result.detail == "Check the transfer")
        }
    }

    @Test func backgroundMessageAppearsInRunningSummary() {
        let result = QueueAccessoryPresentation.make(
            queue: queue([row("A001", state: .copying(progress: 20), progress: 0.2)]),
            backgroundMessage: TransferProgressPresentation.iOSBackgroundLimit
        )
        #expect(result.backgroundMessage == TransferProgressPresentation.iOSBackgroundLimit)
        #expect(result.accessibilityLabel.contains("Keep BitMatch open"))
    }

    @Test func quickCompletionWaitsUntilTheActiveCardFinishes() {
        let quick = row("A001", state: .copiedNotVerified)
        let running = row("B002", state: .copying(progress: 25), progress: 0.25)
        let duringRun = QueueAccessoryPresentation.make(queue: queue([quick, running]))
        let betweenCards = QueueAccessoryPresentation.make(
            queue: queue([quick, row("B002", state: .waiting)]),
            isQueueRunning: true
        )
        let afterRun = QueueAccessoryPresentation.make(queue: queue([quick]))

        #expect(duringRun.title == "B002")
        #expect(duringRun.tone == .progress)
        #expect(betweenCards.tone == .neutral)
        #expect(afterRun.tone == .warning)
    }

    @Test func progressAboveOneIsClamped() {
        let result = QueueAccessoryPresentation.make(queue: queue([
            row("A001", state: .copying(progress: 140), progress: 1.4)
        ]))
        #expect(result.detail == "1 of 1 · 100%")
        #expect(result.progressFraction == 1)
    }

    @Test func sameRecordRealarmsAfterLeavingAndReenteringAProblemState() {
        let id = UUID()
        let failed = row("A001", id: id, state: .failed, cause: "Backup disconnected")
        let acknowledged = QueueAccessoryPresentation.attentionTokens(in: [failed])
        let active = row("A001", id: id, state: .copying(progress: 10), progress: 0.1)
        let cleared = QueueAccessoryPresentation.reconciledAcknowledgements(
            acknowledged,
            with: [active]
        )
        let failedAgain = row("A001", id: id, state: .failed, cause: "Backup disconnected")
        let result = QueueAccessoryPresentation.make(
            queue: queue([failedAgain]),
            acknowledgedAttention: cleared
        )
        #expect(cleared.isEmpty)
        #expect(result.tone == .failure)
        #expect(result.attentionRecordID == id)
    }

    @Test func changedProblemOnAcknowledgedRecordRealarmsImmediately() {
        let id = UUID()
        let firstProblem = row("A001", id: id, state: .failed, cause: "Backup disconnected")
        let changedProblem = row("A001", id: id, state: .needsAttention, cause: "One file failed")
        let result = QueueAccessoryPresentation.make(
            queue: queue([changedProblem, row("B002", state: .copying(progress: 20), progress: 0.2)]),
            acknowledgedAttention: QueueAccessoryPresentation.attentionTokens(in: [firstProblem])
        )
        #expect(result.tone == .warning)
        #expect(result.attentionRecordID == id)
        #expect(result.detail == "One file failed")
    }

    @Test func acknowledgedProblemRemainsVisibleWhenNothingIsRunning() {
        let interrupted = row("A001", state: .interrupted, cause: "Card disconnected")
        let result = QueueAccessoryPresentation.make(
            queue: queue([interrupted]),
            acknowledgedAttention: QueueAccessoryPresentation.attentionTokens(in: [interrupted])
        )
        #expect(result.tone == .warning)
        #expect(result.detail == "Card disconnected")
    }

    private func queue(_ rows: [QueueSessionRow]) -> QueueSessionPresentation {
        QueueSessionPresentation(
            rows: rows,
            tally: QueueTally(),
            headerTitle: nil,
            headerDetail: nil,
            summaryTitle: nil,
            copySummary: "",
            ejectableCardIDs: [],
            showsExportReport: false,
            pausedCardID: nil,
            pausedTitle: nil,
            pausedCause: nil
        )
    }

    private func row(
        _ name: String,
        id: UUID = UUID(),
        state: CardSafetyState,
        progress: Double? = nil,
        cause: String? = nil
    ) -> QueueSessionRow {
        QueueSessionRow(
            id: id, cardName: name, evidence: nil, destinations: "Backup",
            safetyState: state, progressFraction: progress, action: nil, cause: cause,
            copySummary: name, outcome: nil, destinationNames: ["Backup"],
            verificationModeName: VerificationMode.standard.rawValue
        )
    }
}
