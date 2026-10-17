// DockTileStateTests.swift
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct DockTileStateTests {
    /// Promise 2 on the Dock: green only when the transfer succeeded.
    /// Plant: map `.completed` to `.verified` whatever `success` says.
    @Test func onlyASuccessIsGreen() {
        #expect(DockTileState.make(state: .completed(.init(success: true, message: "")), fraction: 1) == .verified)
        #expect(DockTileState.make(state: .completed(.init(success: false, message: "")), fraction: 1) == .needsReview)
        #expect(DockTileState.make(state: .failed, fraction: 0.4) == .failed)
    }

    @Test func runningShowsWholePercentAndIdleShowsTheIcon() {
        #expect(DockTileState.make(state: .copying, fraction: 0.426) == .running(percent: 42))
        #expect(DockTileState.make(state: .verifying, fraction: nil) == .running(percent: 0))
        #expect(DockTileState.make(state: .copying, fraction: 1.7) == .running(percent: 100))
        #expect(DockTileState.make(state: .notStarted, fraction: 0.5) == .appIcon)
        #expect(DockTileState.make(state: .cancelled, fraction: 0.5) == .needsReview)
    }

    @Test func executorSuccessWaitsForSavedCoverageBeforeDockTurnsGreen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dock-plan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card")
        let destination = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(),
            source: try LocalTransferResource(url: source),
            destinations: [try LocalTransferResource(url: destination)],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        record.results = [ResultRow(path: source.appendingPathComponent("clip.mov").path,
            status: ResultOutcome.verified.statusText, size: 1, checksum: "abc", destination: "Backup",
            destinationPath: destination.appendingPathComponent("clip.mov").path)]
        let engineSuccess = OperationState.completed(.init(success: true, message: "Selected files verified"))

        record.state = .running
        #expect(DockTileState.makeTransfer(state: engineSuccess, record: record, fraction: 1) != .verified)
        record.state = .completed
        #expect(DockTileState.makeTransfer(state: engineSuccess, record: record, fraction: 1) == .needsReview)
        record.plannedFileCounts = [1]
        #expect(DockTileState.makeTransfer(state: engineSuccess, record: record, fraction: 1) == .verified)
    }
}
