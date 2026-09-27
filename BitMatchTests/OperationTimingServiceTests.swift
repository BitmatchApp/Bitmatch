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
}
