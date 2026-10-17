// CancelledOutcomeTests.swift
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// Cancelling must leave partial results in place so the outcome UI can
/// show what completed before cancellation. Resetting for a new operation
/// is the only path that clears them.
@MainActor
struct CancelledOutcomeTests {
    private func makeCoordinator() -> SharedAppCoordinator {
        // These presentation tests cancel a coordinator without starting a transfer.
        // Give each one private file operations so it cannot cancel another test's
        // active run on MacOSPlatformManager.shared's process-wide pipeline.
        let operations = RecordingFileOperations()
        return SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: operations),
            defaults: .isolatedWorkflowDefaults()
        )
    }

    private func makeRow(path: String) -> ResultRow {
        ResultRow(
            path: path,
            status: "Copied",
            size: 8,
            checksum: nil,
            destination: "Test destination"
        )
    }

    @Test func cancelPreservesPartialResults() async throws {
        #if os(macOS)
        let coordinator = makeCoordinator()
        coordinator.results = [makeRow(path: "/src/a.mov")]
        coordinator.operationState = .inProgress

        coordinator.cancelOperation()

        #expect(coordinator.operationState == .cancelled)
        #expect(coordinator.results.map(\.path) == ["/src/a.mov"])
        #else
        #expect(true)
        #endif
    }

    @Test func cancelSurfacesVisibleOutcomeState() async throws {
        #if os(macOS)
        let coordinator = makeCoordinator()
        coordinator.results = [makeRow(path: "/src/a.mov")]
        coordinator.operationState = .inProgress
        coordinator.cancelOperation()

        #expect(coordinator.showsOutcomeSummary)
        #else
        #expect(true)
        #endif
    }

    @Test func newOperationResetsAfterCancel() async throws {
        #if os(macOS)
        let coordinator = makeCoordinator()
        coordinator.results = [makeRow(path: "/src/a.mov")]
        coordinator.operationState = .inProgress
        coordinator.cancelOperation()

        coordinator.resetForNewOperation()

        #expect(coordinator.results.isEmpty)
        #expect(coordinator.operationState == .notStarted)
        #else
        #expect(true)
        #endif
    }

    @Test func masterReportIsNotCoveredByPreviousTransferOutcome() {
        #if os(macOS)
        let coordinator = makeCoordinator()
        coordinator.operationState = .failed

        #expect(coordinator.showsOutcomeSummary)
        #expect(coordinator.currentMode == .copyAndVerify)

        coordinator.switchMode(to: .masterReport)

        #expect(coordinator.showsOutcomeSummary)
        #expect(coordinator.currentMode == .masterReport)
        #expect(!(coordinator.currentMode == .copyAndVerify && coordinator.showsOutcomeSummary))
        #expect(coordinator.operationState == .failed)

        coordinator.switchMode(to: .copyAndVerify)
        #expect(coordinator.currentMode == .copyAndVerify && coordinator.showsOutcomeSummary)
        #else
        #expect(true)
        #endif
    }

    @Test func terminalScreenWaitsForDurableJournalSettlement() {
        let completed = OperationState.completed(.init(success: true, message: "Verified"))
        let shows = { (state: OperationState, recordState: LocalTransferState?, running: Bool) in
            SharedAppCoordinator.shouldShowOutcomeSummary(
                state: state, recordState: recordState,
                isOperationInProgress: running, hasJournalPersistenceError: false,
                lastOperationWasCompare: false
            )
        }

        #expect(!shows(completed, .running, true))
        #expect(!shows(completed, nil, false))
        #expect(shows(completed, .completed, true))
        #expect(shows(completed, .issues, false))
        #expect(!shows(.failed, .running, true))
        #expect(!shows(.failed, .running, false))
        #expect(!shows(.cancelled, .running, false))
        #expect(SharedAppCoordinator.shouldShowOutcomeSummary(
            state: .failed, recordState: .running, isOperationInProgress: false,
            hasJournalPersistenceError: true, lastOperationWasCompare: false
        ))
        #expect(!SharedAppCoordinator.shouldShowOutcomeSummary(
            state: completed, recordState: .completed,
            isOperationInProgress: false, hasJournalPersistenceError: false,
            lastOperationWasCompare: true
        ))
    }

}
