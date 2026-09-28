import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

@MainActor
struct OperationTimingServiceTests {
    @Test func standardRunRecordsAccumulatedCopyAndVerifyDurations() {
        var timestamp = Date(timeIntervalSince1970: 1_000)
        let timing = OperationTimingService(now: { timestamp })

        timing.startOperation(totalFiles: 2, totalBytes: 20)
        timing.updateStage(.preparing)
        timestamp.addTimeInterval(1)
        timing.updateStage(.copying)
        timestamp.addTimeInterval(10)
        timing.updateStage(.verifying)
        timestamp.addTimeInterval(4)
        timing.updateStage(.copying)
        timestamp.addTimeInterval(5)
        timing.updateStage(.verifying)
        timestamp.addTimeInterval(3)
        timing.updateStage(.completed)

        let durations = timing.phaseDurations(for: .standard)
        #expect(durations.copySeconds == 15)
        #expect(durations.verifySeconds == 7)
    }

    @Test func quickRunHasNoVerifyDuration() {
        var timestamp = Date(timeIntervalSince1970: 2_000)
        let timing = OperationTimingService(now: { timestamp })

        timing.startOperation(totalFiles: 1, totalBytes: 10)
        timing.updateStage(.copying)
        timestamp.addTimeInterval(6)
        timing.updateStage(.completed)

        let durations = timing.phaseDurations(for: .quick)
        #expect(durations.copySeconds == 6)
        #expect(durations.verifySeconds == nil)
    }

    @Test func pipelinedIntervalsReportWallTimeBytesAndOverlapWithoutDoubleCounting() {
        var timestamp = Date(timeIntervalSince1970: 3_000)
        let timing = OperationTimingService(now: { timestamp })
        timing.startOperation(totalFiles: 2, totalBytes: 2_000)

        let start = timestamp
        timing.recordPhaseInterval(
            stage: .copying,
            start: start,
            end: start.addingTimeInterval(10),
            bytes: 2_000
        )
        timing.recordPhaseInterval(
            stage: .verifying,
            start: start.addingTimeInterval(4),
            end: start.addingTimeInterval(10),
            bytes: 2_000
        )
        timing.recordPhaseInterval(
            stage: .verifying,
            start: start.addingTimeInterval(8),
            end: start.addingTimeInterval(12),
            bytes: 2_000
        )
        timestamp = start.addingTimeInterval(12)
        timing.beginMHL(bytes: 2_000)
        timestamp.addTimeInterval(3)
        timing.endMHL()

        let durations = timing.phaseDurations(for: .standard)
        #expect(durations.copySeconds == 10)
        #expect(durations.verifySeconds == 8)
        #expect(durations.overlapSeconds == 6)
        #expect(durations.copyBytes == 2_000)
        #expect(durations.verifyBytes == 4_000)
        #expect(durations.mhlSeconds == 3)
        #expect(durations.mhlBytes == 2_000)
        #expect((durations.copySeconds ?? 0) + (durations.verifySeconds ?? 0) >= 12)
    }

    @Test func firstVerificationBearingEventOmitsAmbiguousPhaseMeasurements() {
        let timestamp = Date(timeIntervalSince1970: 4_000)
        let timing = OperationTimingService(now: { timestamp })
        timing.startOperation(totalFiles: 1, totalBytes: 100)
        timing.updateStage(.copying)
        timing.recordFileResult(
            result(source: "clip.mov", success: true, size: 100, verification: verification(size: 100)),
            verificationMode: .standard
        )

        let durations = timing.phaseDurations(for: .standard)
        #expect(durations.copySeconds == nil)
        #expect(durations.verifySeconds == nil)
        #expect(durations.copyBytes == nil)
        #expect(durations.verifyBytes == nil)
    }

    @Test func copyFailureWithoutVerifyReportsOnlyKnownZeroVerifyWork() {
        var timestamp = Date(timeIntervalSince1970: 5_000)
        let timing = OperationTimingService(now: { timestamp })
        timing.startOperation(totalFiles: 1, totalBytes: 100)
        timing.updateStage(.copying)
        timestamp = timestamp.addingTimeInterval(2)
        timing.recordFileResult(
            result(source: "failed.mov", success: false, size: 0),
            verificationMode: .standard
        )

        let durations = timing.phaseDurations(for: .standard)
        #expect(durations.copySeconds == 2)
        #expect(durations.verifySeconds == 0)
        #expect(durations.copyBytes == nil)
        #expect(durations.verifyBytes == 0)
    }

    @Test func successfulVerificationByteCountsMatchCurrentReadStructure() {
        let timestamp = Date(timeIntervalSince1970: 6_000)

        for (mode, expectedBytes) in [
            (VerificationMode.standard, Int64(100)),
            (.thorough, 200),
            (.paranoid, 300),
        ] {
            let timing = OperationTimingService(now: { timestamp })
            timing.startOperation(totalFiles: 1, totalBytes: 100)
            timing.recordFileResult(result(source: mode.rawValue, success: true, size: 100), verificationMode: mode)
            timing.recordFileResult(
                result(source: mode.rawValue, success: true, size: 100, verification: verification(size: 100)),
                verificationMode: mode
            )
            #expect(timing.phaseDurations(for: mode).verifyBytes == expectedBytes)
        }
    }

    @Test func thoroughChecksumMismatchStillCountsCompletedChecksumPasses() {
        let timestamp = Date(timeIntervalSince1970: 7_000)
        let timing = OperationTimingService(now: { timestamp })
        timing.startOperation(totalFiles: 1, totalBytes: 100)
        timing.recordFileResult(result(source: "mismatch.mov", success: true, size: 100), verificationMode: .thorough)
        timing.recordFileResult(
            result(
                source: "mismatch.mov",
                success: false,
                size: 100,
                verification: verification(size: 100, matches: false)
            ),
            verificationMode: .thorough
        )

        #expect(timing.phaseDurations(for: .thorough).verifyBytes == 200)
    }

    private func result(
        source: String,
        success: Bool,
        size: Int64,
        verification: VerificationResult? = nil
    ) -> FileOperationResult {
        FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/source/\(source)"),
            destinationURL: URL(fileURLWithPath: "/destination/\(source)"),
            success: success,
            error: nil,
            fileSize: size,
            verificationResult: verification,
            processingTime: verification?.processingTime ?? 0
        )
    }

    private func verification(size: Int64, matches: Bool = true) -> VerificationResult {
        VerificationResult(
            sourceChecksum: "abc",
            destinationChecksum: matches ? "abc" : "def",
            matches: matches,
            checksumType: .sha256,
            processingTime: 1,
            fileSize: size
        )
    }
}
