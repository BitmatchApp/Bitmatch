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
        SharedAppCoordinator(platformManager: MacOSPlatformManager.shared, defaults: .isolatedWorkflowDefaults())
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
        coordinator.operationState = .completed(
            OperationCompletionInfo(success: false, message: "Not verified")
        )

        #expect(coordinator.showsOutcomeSummary)
        #expect(coordinator.currentMode == .copyAndVerify)

        coordinator.switchMode(to: .masterReport)

        #expect(coordinator.showsOutcomeSummary)
        #expect(coordinator.currentMode == .masterReport)
        #expect(!(coordinator.currentMode == .copyAndVerify && coordinator.showsOutcomeSummary))
        #expect(coordinator.operationState == .completed(
            OperationCompletionInfo(success: false, message: "Not verified")
        ))

        coordinator.switchMode(to: .copyAndVerify)
        #expect(coordinator.currentMode == .copyAndVerify && coordinator.showsOutcomeSummary)
        #else
        #expect(true)
        #endif
    }

}
