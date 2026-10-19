import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

@MainActor
struct ByteWeightedProgressPresentationTests {
    @Test func handoffUsesSelectedByteWorkAndNeverResetsOrFinishesEarly() {
        let pipeline = OperationProgress(overallProgress: 1, currentFile: nil,
            filesProcessed: 2, totalFiles: 2, currentStage: .completed,
            speed: nil, elapsedTime: nil, averageSpeed: nil, peakSpeed: nil,
            bytesProcessed: 200, totalBytes: 100, workBytesProcessed: 500, totalWorkBytes: 500)
        let withMHL = CopyVerifyExecutor.pipelineProgress(pipeline, destinationCount: 2, includeMHL: true)
        #expect(abs(withMHL.overallProgress - 5.0 / 7.0) < 0.00001)
        let beginning = CopyVerifyExecutor.mhlProgress(.init(bytesProcessed: 0, totalBytes: 200,
            filesProcessed: 0, totalFiles: 2, published: false), precedingWorkBytes: 500)
        let midway = CopyVerifyExecutor.mhlProgress(.init(bytesProcessed: 100, totalBytes: 200,
            filesProcessed: 1, totalFiles: 2, published: false), precedingWorkBytes: 500)
        let published = CopyVerifyExecutor.mhlProgress(.init(bytesProcessed: 200, totalBytes: 200,
            filesProcessed: 2, totalFiles: 2, published: true), precedingWorkBytes: 500)
        #expect(beginning.overallProgress == withMHL.overallProgress)
        #expect(midway.overallProgress > beginning.overallProgress)
        #expect(published.overallProgress == 0.99)
        #expect(published.currentStage == .generating)
        #expect(CopyVerifyExecutor.pipelineProgress(pipeline, destinationCount: 2, includeMHL: false).overallProgress == 0.99)
        // Mapping the bar cannot change actual copied bytes.
        #expect(withMHL.bytesProcessed == pipeline.bytesProcessed)
    }

    @Test func tinyFinishedCardCannotSpendAHugeWaitingCardsProgress() {
        let tiny = row(state: .safeToErase, work: 1)
        let huge = row(state: .copying(progress: 0), fraction: 0, work: 999)
        let started = QueueAccessoryPresentation.weightedProgress(rows: [tiny, huge])
        #expect(started == 0.001)
        var half = huge
        half = row(state: .verifying(progress: 50), fraction: 0.5, work: 999)
        #expect(QueueAccessoryPresentation.weightedProgress(rows: [tiny, half]) == 0.5005)
        #expect(QueueAccessoryPresentation.weightedProgress(rows: [tiny, row(state: .waiting, work: nil)]) == nil)
        #expect(QueueAccessoryPresentation.weightedProgress(rows: [row(state: .finishing(progress: 100), fraction: 1, work: 100)]) == 0.99)
    }

    @Test func destinationBarsPreferByteWorkOverEqualFileCounts() throws {
        let update = OperationProgress(overallProgress: 0.4, currentFile: nil,
            filesProcessed: 2, totalFiles: 4, currentStage: .copying, speed: nil,
            elapsedTime: nil, averageSpeed: nil, peakSpeed: nil, bytesProcessed: 2, totalBytes: 1000,
            perDestinationTotals: [2, 2], perDestinationCompleted: [1, 1], perDestinationProgress: [0.001, 0.7])
        let rows = TransferProgressPresentation.rows(destinations: [URL(fileURLWithPath: "/one"), URL(fileURLWithPath: "/two")],
            progress: update, phase: .copying)
        #expect(rows[0].fraction == 0.001)
        #expect(rows[1].fraction == 0.7)
        #expect(rows[0].countText == "1 of 2")
    }

    private func row(state: CardSafetyState, fraction: Double? = nil, work: Double?) -> QueueSessionRow {
        QueueSessionRow(id: UUID(), cardName: "Card", evidence: nil, destinations: "Backup",
            safetyState: state, progressFraction: fraction, action: nil, cause: nil, copySummary: "",
            outcome: nil, destinationNames: ["Backup"], verificationModeName: "Standard", estimatedWorkBytes: work)
    }
}
