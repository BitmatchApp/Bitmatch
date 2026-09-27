import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

@MainActor
struct LocalTransferJournalTests {
    @Test func fingerprintMatchRequiresVerifiedCompletedHistory() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let fingerprint = "abc123"

        let verifiedID = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal.markRunning(id: verifiedID)
        try journal.finish(
            id: verifiedID,
            results: [ResultRow(
                path: "clip.mov", status: "✅ Verified", size: 1, checksum: "abc",
                destination: "Backup", destinationPath: f.destination.appendingPathComponent("clip.mov").path
            )],
            summary: "Done", hadIssues: false, sourceFingerprint: fingerprint
        )
        let match = try #require(journal.matchingVerifiedRecord(sourceFingerprint: fingerprint))
        #expect(match.id == verifiedID)

        let issueID = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal.markRunning(id: issueID)
        try journal.finish(
            id: issueID,
            results: [ResultRow(path: "clip.mov", status: "❌ Failed", size: 1, checksum: nil, destination: "Backup")],
            summary: "Failed", hadIssues: true, sourceFingerprint: "issues"
        )
        #expect(journal.matchingVerifiedRecord(sourceFingerprint: "issues") == nil)

        let quickID = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .quick,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal.markRunning(id: quickID)
        try journal.finish(
            id: quickID,
            results: [ResultRow(path: "clip.mov", status: "✅ Copied", size: 1, checksum: nil, destination: "Backup")],
            summary: "Done", hadIssues: false, sourceFingerprint: "quick"
        )
        #expect(journal.matchingVerifiedRecord(sourceFingerprint: "quick") == nil)

        let incompleteID = try journal.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal.markRunning(id: incompleteID)
        try journal.finish(
            id: incompleteID,
            results: [ResultRow(
                path: "clip.mov", status: "✅ Verified", size: 1, checksum: "abc",
                destination: "Somewhere else", destinationPath: "/missing/clip.mov"
            )],
            summary: "Done", hadIssues: false, sourceFingerprint: "incomplete"
        )
        #expect(journal.matchingVerifiedRecord(sourceFingerprint: "incomplete") == nil)
    }

    @Test func oldHistoryJSONDecodesWithoutNewSourceAndDiskFields() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try LocalTransferResource(url: f.source)
        let destination = try LocalTransferResource(url: f.destination)
        let record = LocalTransferRecord(
            id: UUID(), createdAt: Date(), source: source, destinations: [destination],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "sourceFingerprint")
        object.removeValue(forKey: "independentDestinationCount")

        let decoded = try JSONDecoder().decode(
            LocalTransferRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.sourceFingerprint == nil)
        #expect(decoded.independentDestinationCount == nil)
    }

    @Test func runningAttemptPersistsIndependentDestinationCount() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let journal = LocalTransferJournal(fileURL: f.journal)
            let id = try journal.enqueue(
                sourceURL: f.source,
                destinationURLs: [f.destination],
                verificationMode: .standard,
                cameraSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs()
            )
            try journal.markRunning(id: id, independentDestinationCount: 1)
        }

        let restored = LocalTransferJournal(fileURL: f.journal)
        #expect(restored.records.first?.independentDestinationCount == 1)
    }
    private func fixture() throws -> (root: URL, source: URL, destination: URL, journal: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Card")
        let destination = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (root, source, destination, root.appendingPathComponent("journal.json"))
    }

    /// Plant: delete `recovered[index].endedAt = Date()` from
    /// `TransferJournal.init`; the recovered attempt has no terminal time.
    @Test func runningAttemptBecomesInterruptedOnRelaunch() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
        let journal = LocalTransferJournal(fileURL: f.journal)
        var settings = CameraLabelSettings()
        settings.label = "A001"
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: settings, reportSettings: ReportPrefs(), generateASCMHL: false)
        settings.label = "A002"
        try journal.markRunning(id: id)
        }
        let restored = LocalTransferJournal(fileURL: f.journal)
        #expect(restored.records.first?.state == .interrupted)
        #expect(restored.records.first?.cameraSettings.label == "A001")
        #expect(restored.records.first?.generateASCMHL == false)
        #expect(restored.records.first?.results.isEmpty == true)
        #expect(restored.records.first?.endedAt != nil)

    }

    @Test func historyPreservesFullResultsAndRejectsFalseSuccess() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let row = ResultRow(path: "DCIM/file.mov", status: "❌ Checksum mismatch", size: 123, checksum: "abc",
                            destination: "Backup", destinationPath: f.destination.appendingPathComponent("DCIM/file.mov").path)
        do {
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try journal.markRunning(id: id)

        try journal.finish(id: id, results: [row], summary: "Check backup", hadIssues: false)
        }
        let restored = LocalTransferJournal(fileURL: f.journal)
        #expect(restored.records.first?.state == .issues)
        #expect(restored.records.first?.results.first?.destinationPath == row.destinationPath)
        #expect(restored.records.first?.results.first?.checksum == "abc")
        #expect(restored.records.first?.results.first?.id == row.id)
    }

    @Test func historyPersistsCopyAndVerifyDurations() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        do {
            let journal = LocalTransferJournal(fileURL: f.journal)
            let id = try journal.enqueue(
                sourceURL: f.source,
                destinationURLs: [f.destination],
                verificationMode: .standard,
                cameraSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs()
            )
            try journal.markRunning(id: id)
            try journal.finish(
                id: id,
                results: [ResultRow(path: "clip.mov", status: "✅ Verified", size: 1,
                                    checksum: "abc", destination: "Backup")],
                summary: "Done",
                hadIssues: false,
                copyDurationSeconds: 252,
                verifyDurationSeconds: 238,
                performanceTelemetry: TransferPerformanceTelemetry(
                    copyDurationSeconds: 252,
                    verifyDurationSeconds: 238,
                    overlapDurationSeconds: 90,
                    copyBytes: 1_000,
                    verifyBytes: 2_000,
                    mhlDurationSeconds: 12,
                    mhlBytes: 1_000
                )
            )
        }

        let restored = LocalTransferJournal(fileURL: f.journal)
        #expect(restored.records.first?.copyDurationSeconds == 252)
        #expect(restored.records.first?.verifyDurationSeconds == 238)
        #expect(restored.records.first?.performanceTelemetry?.overlapDurationSeconds == 90)
        #expect(restored.records.first?.performanceTelemetry?.mhlDurationSeconds == 12)
    }

    @Test func oldHistoryJSONDecodesWithoutPhaseDurations() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let source = try LocalTransferResource(url: f.source)
        let destination = try LocalTransferResource(url: f.destination)
        let record = LocalTransferRecord(
            id: UUID(), createdAt: Date(), source: source, destinations: [destination],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs()
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "copyDurationSeconds")
        object.removeValue(forKey: "verifyDurationSeconds")
        object.removeValue(forKey: "performanceTelemetry")

        let oldData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(LocalTransferRecord.self, from: oldData)
        #expect(decoded.copyDurationSeconds == nil)
        #expect(decoded.verifyDurationSeconds == nil)
        #expect(decoded.performanceTelemetry == nil)
    }

    @Test func legacyPhaseDurationsDecodeIntoTelemetry() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: f.source),
            destinations: [try LocalTransferResource(url: f.destination)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        record.copyDurationSeconds = 18
        record.verifyDurationSeconds = 27
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "performanceTelemetry")

        let decoded = try JSONDecoder().decode(
            LocalTransferRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.performanceTelemetry?.copyDurationSeconds == 18)
        #expect(decoded.performanceTelemetry?.verifyDurationSeconds == 27)
    }

    @Test func finishWithoutNewTelemetryPreservesLegacySynthesizedTelemetry() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: f.source),
            destinations: [try LocalTransferResource(url: f.destination)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        record.copyDurationSeconds = 18
        record.verifyDurationSeconds = 27
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object.removeValue(forKey: "performanceTelemetry")
        try JSONSerialization.data(withJSONObject: [object]).write(to: f.journal)

        let journal = LocalTransferJournal(fileURL: f.journal)
        try journal.markRunning(id: record.id)
        try journal.finish(
            id: record.id,
            results: [ResultRow(
                path: "clip.mov", status: "✅ Verified", size: 1,
                checksum: "abc", destination: "Backup"
            )],
            summary: "Done",
            hadIssues: false
        )

        let finished = try #require(journal.records.first)
        #expect(finished.copyDurationSeconds == 18)
        #expect(finished.verifyDurationSeconds == 27)
        #expect(finished.performanceTelemetry?.copyDurationSeconds == 18)
        #expect(finished.performanceTelemetry?.verifyDurationSeconds == 27)
    }

    @Test func retryKeepsPreviousAttemptAndChecksResources() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try journal.markRunning(id: id)
        try journal.interrupt(id: id, summary: "Disconnected")
        let retryID = try journal.requeue(id: id)
        #expect(retryID != id)
        #expect(journal.records.count == 2)
        #expect(journal.records.first?.state == .queued)
        #expect(journal.records.last?.state == .interrupted)
        let access = try journal.prepareToRun(id: retryID)
        #expect(access.sourceURL.standardizedFileURL.resolvingSymlinksInPath() == f.source.standardizedFileURL.resolvingSymlinksInPath())
        access.release()
        try FileManager.default.removeItem(at: f.destination)
        #expect(throws: (any Error).self) { try journal.prepareToRun(id: retryID) }
    }

    @Test func staleLocationsAreDetectedWhenFoldersDisappear() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        #expect(try journal.staleResourceIndexes(id: id) == [])
        try FileManager.default.removeItem(at: f.destination)
        #expect(try journal.staleResourceIndexes(id: id) == [1])
    }

    @Test func reauthorizeRejectsADifferentFolder() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try FileManager.default.removeItem(at: f.destination)
        #expect(throws: LocalTransferJournalError.self) {
            try journal.reauthorize(id: id, resourceIndex: 1, newURL: f.source)
        }
        #expect(throws: LocalTransferJournalError.self) {
            try journal.reauthorize(id: id, resourceIndex: 5, newURL: f.source)
        }
        #expect(journal.records.first?.destinations.first?.url == f.destination)
    }

    @Test func reauthorizeRejectsARecreatedImpostorAtTheSamePath() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try FileManager.default.removeItem(at: f.destination)
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: true)
        // A fresh URL instance, as a folder picker would hand over.
        let repick = URL(fileURLWithPath: f.destination.path)
        do {
            try journal.reauthorize(id: id, resourceIndex: 1, newURL: repick)
            Issue.record("A recreated folder at the same path must be rejected as a replacement")
        } catch let error as LocalTransferJournalError {
            #expect(error.localizedDescription.contains("not the original folder"))
        }
        #expect(try journal.staleResourceIndexes(id: id) == [1])
    }

    @Test func reauthorizeRejectsAResourceWithPartialIdentity() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var id = UUID()
        do {
            var journal: LocalTransferJournal? = LocalTransferJournal(fileURL: f.journal)
            id = try journal!.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
            let record = try #require(journal!.records.first)

            // Simulate a legacy journal that recorded only one identity
            // component. Reauthorization must fail closed instead of treating
            // the missing component as a wildcard.
            var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode([record])) as? [[String: Any]])
            var destinations = try #require(payload[0]["destinations"] as? [[String: Any]])
            destinations[0].removeValue(forKey: "volumeID")
            payload[0]["destinations"] = destinations
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: f.journal, options: .atomic)
            journal = nil
        }
        let restored = LocalTransferJournal(fileURL: f.journal)
        #expect(try restored.staleResourceIndexes(id: id) == [1])
        #expect(throws: LocalTransferJournalError.self) {
            try restored.reauthorize(id: id, resourceIndex: 1, newURL: f.destination)
        }
    }

    @Test func reauthorizeAcceptsTheOriginalFolderAndKeepsEvidence() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try journal.markRunning(id: id)
        let row = ResultRow(path: "clip.mov", status: "❌ Failed", size: 1, checksum: nil, destination: "Backup")
        try journal.finish(id: id, results: [row], summary: "Interrupted", hadIssues: true)
        try journal.reauthorize(id: id, resourceIndex: 0, newURL: f.source)
        let record = try #require(journal.records.first)
        #expect(record.state == .issues)
        #expect(record.results.count == 1)
        #expect(record.results.first?.id == row.id)
        #expect(record.source.url == f.source)
        #expect(try journal.staleResourceIndexes(id: id) == [])
    }

    @Test func retryCanSkipASCMHLWithoutChangingPreviousAttemptOrDefault() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), generateASCMHL: true)
        try journal.markRunning(id: id)
        let row = ResultRow(path: "clip.mov", status: "✅ Verified", size: 1, checksum: "abc", destination: "Backup")
        try journal.finish(id: id, results: [row], summary: "ASC MHL history already exists", hadIssues: true)

        let copyOnlyRetryID = try journal.requeue(id: id, generateASCMHL: false)
        let defaultRetryID = try journal.requeue(id: id)

        let original = try #require(journal.records.first { $0.id == id })
        let copyOnlyRetry = try #require(journal.records.first { $0.id == copyOnlyRetryID })
        let defaultRetry = try #require(journal.records.first { $0.id == defaultRetryID })
        #expect(original.generateASCMHL)
        #expect(original.state == .issues)
        #expect(original.results.first?.id == row.id)
        #expect(original.summary == "ASC MHL history already exists")
        #expect(!copyOnlyRetry.generateASCMHL)
        #expect(copyOnlyRetry.state == .queued)
        #expect(copyOnlyRetry.verificationMode == .standard)
        #expect(copyOnlyRetry.source.bookmark == original.source.bookmark)
        #expect(copyOnlyRetry.destinations.first?.bookmark == original.destinations.first?.bookmark)
        #expect(defaultRetry.generateASCMHL)
        let onDisk = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: f.journal))
        #expect(onDisk.first(where: { $0.id == copyOnlyRetryID })?.generateASCMHL == false)
        #expect(onDisk.first(where: { $0.id == id })?.generateASCMHL == true)
    }

    @Test func projectAttemptCannotBeRetriedAsUntrackedCopy() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let projectID = UUID()
        let projectCardID = UUID()
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(),
                                     projectID: projectID, projectCardID: projectCardID)
        try journal.markRunning(id: id)
        try journal.interrupt(id: id, summary: "Interrupted")
        #expect(journal.records.first?.canRetry == false)
        #expect(throws: LocalTransferJournalError.self) { try journal.requeue(id: id) }
        // A second journal instance cannot open live history (it is locked
        // while this one is alive), so read what was written to disk.
        let saved = try String(contentsOf: f.journal, encoding: .utf8)
        #expect(saved.contains(projectID.uuidString))
        #expect(saved.contains(projectCardID.uuidString))
    }

    @Test func corruptHistoryIsNotSilentlyOverwritten() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = Data("not valid JSON".utf8)
        try original.write(to: f.journal)
        let journal = LocalTransferJournal(fileURL: f.journal)
        #expect(journal.persistenceError != nil)
        #expect(throws: LocalTransferJournalError.self) {
            try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        }
        #expect(try Data(contentsOf: f.journal) == original)
        #expect(journal.records.isEmpty)
    }

    @Test func persistenceFailureDoesNotPublishQueuedWork() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let blockingFile = f.root.appendingPathComponent("not-a-directory")
        try Data().write(to: blockingFile)
        let journal = LocalTransferJournal(fileURL: blockingFile.appendingPathComponent("journal.json"))
        #expect(throws: (any Error).self) {
            try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        }
        #expect(journal.records.isEmpty)
        #expect(journal.persistenceError != nil)
    }

    @Test func secondInstanceCannotOverwriteLiveHistory() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = LocalTransferJournal(fileURL: f.journal)
        let id = try first.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                   cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try first.markRunning(id: id)
        let second = LocalTransferJournal(fileURL: f.journal)
        #expect(second.persistenceError?.contains("already open") == true)
        #expect(throws: LocalTransferJournalError.self) {
            try second.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                               cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        }
        let onDisk = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: f.journal))
        #expect(onDisk.first?.state == .running)
        #expect(first.records.first?.state == .running)
    }

    @Test func quickCopyNeverClaimsVerifiedCompletion() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .quick,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try journal.markRunning(id: id)
        try journal.finish(id: id, results: [ResultRow(path: "file", status: "✅ Copied", size: 1, checksum: nil, destination: "Backup")],
                           summary: "Done", hadIssues: false)
        #expect(journal.records.first?.state == .issues)
        #expect(journal.records.first?.summary.contains("Quick mode only compares file sizes") == true)
    }

    @Test func exportedHistoryPreservesUnverifiedVerdictWithoutBookmarks() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .quick,
                                     cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        try journal.markRunning(id: id)
        try journal.finish(id: id, results: [ResultRow(path: "file", status: "✅ Copied", size: 1, checksum: nil, destination: "Backup")],
                           summary: "Done", hadIssues: false)
        let record = try #require(journal.records.first)
        let csv = try TransferHistoryDocument(record: record, asCSV: true)
        let csvText = String(decoding: csv.data, as: UTF8.self)
        #expect(csvText.contains("verification,transfer_state,transfer_summary"))
        #expect(csvText.contains("\"Quick\",\"issues\""))
        #expect(csvText.contains("Quick mode only compares file sizes"))
        let json = try TransferHistoryDocument(record: record, asCSV: false)
        let payload = try #require(JSONSerialization.jsonObject(with: json.data) as? [String: Any])
        #expect(payload["state"] as? String == "issues")
        #expect(payload["source"] as? String == f.source.path)
        #expect(payload["bookmark"] == nil)
        #expect(!String(decoding: json.data, as: UTF8.self).contains(record.source.bookmark.base64EncodedString()))
    }

    @Test func exportedHistoryCarriesProjectProvenanceAndASCMHLRequest() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let journal = LocalTransferJournal(fileURL: f.journal)
        var reportSettings = ReportPrefs()
        reportSettings.projectName = "Venice Shoot"
        reportSettings.clientName = "Studio"
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
                                     cameraSettings: CameraLabelSettings(), reportSettings: reportSettings, generateASCMHL: true)
        try journal.markRunning(id: id)
        try journal.finish(id: id, results: [ResultRow(path: "clip.mov", status: "✅ Verified", size: 1, checksum: "abc", destination: "Backup")],
                           summary: "Done", hadIssues: false)
        let record = try #require(journal.records.first)

        let json = try TransferHistoryDocument(record: record, asCSV: false)
        let payload = try #require(JSONSerialization.jsonObject(with: json.data) as? [String: Any])
        #expect(payload["projectName"] as? String == "Venice Shoot")
        #expect(payload["clientName"] as? String == "Studio")
        #expect(payload["ascMHLRequested"] as? Bool == true)
        #expect((payload["results"] as? [[String: Any]])?.count == 1)

        let csv = try TransferHistoryDocument(record: record, asCSV: true)
        let csvText = String(decoding: csv.data, as: UTF8.self)
        #expect(csvText.contains("transfer_summary,project,asc_mhl"))
        #expect(csvText.contains("\"Done\",\"Venice Shoot\",\"requested\""))
        #expect(csvText.contains("\"requested\",\"Studio\""))
    }

    @Test func onlyWaitingAndRunningTransfersStayVisibleInQueue() {
        #expect(LocalTransferState.cancelled.canRetry)
        #expect(!LocalTransferState.cancelled.showsInQueue)
        #expect(LocalTransferState.queued.showsInQueue)
        #expect(LocalTransferState.running.showsInQueue)
        #expect(!LocalTransferState.interrupted.showsInQueue)
        #expect(!LocalTransferState.issues.showsInQueue)
        #expect(!LocalTransferState.failed.showsInQueue)
        #expect(!LocalTransferState.completed.showsInQueue)
    }

    @Test func failAcceptsOnlyQueuedOrRunningAndPersists() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var journal: LocalTransferJournal? = LocalTransferJournal(fileURL: f.journal)
        let failedID = try journal!.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal!.fail(id: failedID, summary: "Card missing")
        #expect(journal!.records.first?.state == .failed)
        #expect(journal!.records.first?.summary == "Card missing")
        #expect(throws: LocalTransferJournalError.self) {
            try journal!.fail(id: failedID, summary: "Again")
        }
        journal = nil
        let restored = LocalTransferJournal(fileURL: f.journal)
        #expect(restored.records.first?.id == failedID)
        #expect(restored.records.first?.state == .failed)
        #expect(restored.records.first?.endedAt != nil)
    }

    @Test func removeQueuedRejectsTerminalRecordsAndPersistsRemoval() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var journal: LocalTransferJournal? = LocalTransferJournal(fileURL: f.journal)
        let removedID = try journal!.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        let terminalID = try journal!.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal!.fail(id: terminalID, summary: "Failed")
        try journal!.removeQueued(id: removedID)
        #expect(throws: LocalTransferJournalError.self) { try journal!.removeQueued(id: terminalID) }
        #expect(journal!.records.map(\.id) == [terminalID])
        journal = nil
        let restored = LocalTransferJournal(fileURL: f.journal)
        #expect(restored.records.map(\.id) == [terminalID])
    }

    @Test func moveQueuedToTopRejectsTerminalRecordsAndPersistsOrder() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var journal: LocalTransferJournal? = LocalTransferJournal(fileURL: f.journal)
        let firstID = try journal!.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        let secondID = try journal!.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        let terminalID = try journal!.enqueue(
            sourceURL: f.source, destinationURLs: [f.destination], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        try journal!.fail(id: terminalID, summary: "Failed")
        try journal!.moveQueuedToTop(id: secondID)
        #expect(journal!.records.map(\.id) == [terminalID, firstID, secondID])
        #expect(throws: LocalTransferJournalError.self) { try journal!.moveQueuedToTop(id: terminalID) }
        journal = nil
        let restored = LocalTransferJournal(fileURL: f.journal)
        #expect(restored.records.map(\.id) == [terminalID, firstID, secondID])
        #expect(restored.records.last?.id == secondID)
    }
}
