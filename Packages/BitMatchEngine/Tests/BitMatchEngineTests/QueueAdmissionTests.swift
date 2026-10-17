import Foundation
import Testing
@testable import BitMatchEngine

struct QueueAdmissionTests {
    private func fixture() throws -> (root: URL, source: URL, backup: URL, journal: TransferJournal) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("queue-admission-\(UUID())")
        let source = root.appendingPathComponent("reader-a/NO NAME")
        let backup = root.appendingPathComponent("Backup")
        for url in [source, backup] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("source remains untouched".utf8).write(to: source.appendingPathComponent("clip.mov"))
        return (root, source, backup, TransferJournal(fileURL: root.appendingPathComponent("journal.json")))
    }

    @Test(arguments: [true, false])
    func replacementAtStartIsRefused(replaceSource: Bool) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let id = try f.journal.enqueue(sourceURL: f.source, destinationURLs: [f.backup], verificationMode: .standard,
                                      cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        let access = try f.journal.prepareToRun(id: id)
        defer { access.release() }
        let selected = replaceSource ? access.sourceURL : access.destinationURLs[0]
        try FileManager.default.moveItem(at: selected, to: f.root.appendingPathComponent("original"))
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try f.journal.markRunning(id: id, sourceURL: access.sourceURL, destinationURLs: access.destinationURLs)
        }
        #expect(f.journal.records.first?.state == .queued)
        #expect(f.journal.records.first?.startedAt == nil)
    }

    @Test(arguments: ["NO NAME", "no name", "nested", "sibling", "same-source"])
    func queuedOutputMatrix(caseName: String) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let second = caseName == "same-source" ? f.source : f.root.appendingPathComponent("reader-b/\(caseName)")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstID = try f.journal.enqueue(sourceURL: f.source, destinationURLs: [f.backup], verificationMode: .standard,
                                           cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        var settings = CameraLabelSettings()
        if caseName == "nested" { settings.destinationPathComponents = ["NO NAME", "nested"] }
        try f.journal.enqueue(sourceURL: second, destinationURLs: [f.backup], verificationMode: .standard,
                              cameraSettings: settings, reportSettings: ReportPrefs())
        if ["sibling", "same-source"].contains(caseName) {
            try f.journal.markRunning(id: firstID)
            #expect(f.journal.records.first { $0.id == firstID }?.state == .running)
        } else {
            #expect(throws: (any Error).self) { try f.journal.markRunning(id: firstID) }
            #expect(f.journal.records.allSatisfy { $0.state == .queued })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.backup.path).isEmpty)
        #expect(try String(contentsOf: f.source.appendingPathComponent("clip.mov"), encoding: .utf8) == "source remains untouched")
    }

    @Test func finishedCardStillReservesItsOutputWithinTheCurrentSession() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try f.journal.enqueue(sourceURL: f.source, destinationURLs: [f.backup], verificationMode: .standard,
                                          cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try f.journal.markRunning(id: first)
        try f.journal.interrupt(id: first, summary: "Interrupted", results: [])
        // Renaming/ejecting the source later must not move the output reservation.
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("renamed-source"))
        let secondSource = f.root.appendingPathComponent("reader-b/NO NAME")
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)
        let second = try f.journal.enqueue(sourceURL: secondSource, destinationURLs: [f.backup], verificationMode: .standard,
                                           cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        #expect(throws: (any Error).self) { try f.journal.markRunning(id: second, sessionRecordIDs: [first, second]) }
        #expect(f.journal.records.first?.state == .queued)
    }

    @Test func retryLineageAndPlanSurviveRoundTripWithoutChangingPreviousAttempt() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var reports = ReportPrefs()
        reports.operatorName = "Alex"
        reports.notes = "Morning card"
        let id = try f.journal.enqueue(sourceURL: f.source, destinationURLs: [f.backup], verificationMode: .standard,
                                      cameraSettings: CameraLabelSettings(), reportSettings: reports)
        try f.journal.markRunning(id: id)
        try f.journal.recordPlan(id: id, fileCounts: [4])
        #expect(throws: (any Error).self) { try f.journal.recordPlan(id: id, fileCounts: [-1]) }
        #expect(throws: (any Error).self) { try f.journal.recordPlan(id: id, fileCounts: [3]) }
        try f.journal.interrupt(id: id, summary: "Interrupted", results: [])
        let original = try JSONEncoder().encode(#require(f.journal.records.first))
        let retry = try f.journal.requeue(id: id)
        try f.journal.replaceQueued(id: retry, sourceURL: f.source, destinationURLs: [f.backup],
                                   verificationMode: .thorough, cameraSettings: CameraLabelSettings(),
                                   reportSettings: reports, generateASCMHL: false)
        let decoded = try JSONDecoder().decode([LocalTransferRecord].self, from: JSONEncoder().encode(f.journal.records))
        #expect(decoded.first?.retryOf == id)
        #expect(decoded.first?.plannedFileCounts == nil)
        #expect(decoded.first?.reportSettings.notes == "Morning card")
        #expect(decoded.last?.plannedFileCounts == [4])
        // Compare decoded values through sorted JSON to avoid key-order dependence.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(decoded.last) == encoder.encode(JSONDecoder().decode(LocalTransferRecord.self, from: original)))
    }

    @Test func priorBackupHintRequiresEveryPlannedFileExactlyOnce() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        func row(_ name: String) -> ResultRow {
            ResultRow(path: name, status: ResultOutcome.verified.statusText, size: 1,
                      checksum: "fixture", destination: "Backup",
                      destinationPath: f.backup.appendingPathComponent(name).path)
        }
        func complete(plan: [Int]?, results: [ResultRow], fingerprint: String) throws {
            let id = try f.journal.enqueue(sourceURL: f.source, destinationURLs: [f.backup],
                                           verificationMode: .standard, cameraSettings: CameraLabelSettings(),
                                           reportSettings: ReportPrefs())
            try f.journal.markRunning(id: id)
            if let plan { try f.journal.recordPlan(id: id, fileCounts: plan) }
            try f.journal.finish(id: id, results: results, summary: "Done", hadIssues: false,
                                 sourceFingerprint: fingerprint)
        }
        try complete(plan: [2], results: [row("a.mov")], fingerprint: "missing")
        #expect(f.journal.matchingVerifiedRecord(sourceFingerprint: "missing") == nil)
        try complete(plan: [2], results: [row("a.mov"), row("a.mov")], fingerprint: "duplicate")
        #expect(f.journal.matchingVerifiedRecord(sourceFingerprint: "duplicate") == nil)
        try complete(plan: [2], results: [row("a.mov"), row("b.mov")], fingerprint: "complete")
        #expect(f.journal.matchingVerifiedRecord(sourceFingerprint: "complete") != nil)
        try complete(plan: nil, results: [row("a.mov")], fingerprint: "legacy")
        #expect(f.journal.matchingVerifiedRecord(sourceFingerprint: "legacy") != nil)
    }
}
