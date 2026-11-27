import Foundation
import Synchronization
import Testing
@testable import BitMatchEngine

/// The journal, the expected-exclusion queue policy and the scope evidence
/// accept a skipped Finder view file (`.DS_Store`) only when the one
/// predicate, `TransferCompletion.finderMetadataSkipsProven`, proves it.
@Suite(.serialized) struct FinderMetadataJournalTests {
    private struct Fixture {
        let root: URL
        let source: URL
        let destinations: [URL]
        let settings = CameraLabelSettings()
        var journalURL: URL { root.appendingPathComponent("journal.json") }

        init() throws {
            root = try FinderMetadataFixtures.makeTree()
            source = root.appendingPathComponent("card")
            destinations = [root.appendingPathComponent("BackupA"), root.appendingPathComponent("BackupB")]
            for folder in [source] + destinations {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try Data("clip".utf8).write(to: source.appendingPathComponent("A001.mov"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func output(_ relative: String, on destination: URL) -> String {
            SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: settings)
                .appendingPathComponent(relative).path
        }

        func verified(_ relative: String, on destination: URL) -> ResultRow {
            ResultRow(path: source.appendingPathComponent(relative).path,
                      status: ResultOutcome.verified.statusText, size: 4, checksum: "fixture",
                      destination: destination.lastPathComponent,
                      destinationPath: output(relative, on: destination))
        }

        func skipped(_ relative: String, on destination: URL) -> ResultRow {
            ResultRow(path: source.appendingPathComponent(relative).path,
                      status: ResultOutcome.skippedFinderMetadata.statusText, size: 6148, checksum: nil,
                      destination: destination.lastPathComponent,
                      destinationPath: output(relative, on: destination))
        }

        /// One clip verified on both backups and `.DS_Store` skipped on both.
        var provenRows: [ResultRow] {
            destinations.flatMap { [verified("A001.mov", on: $0), skipped(".DS_Store", on: $0)] }
        }

        @discardableResult
        func finish(_ journal: TransferJournal, rows: [ResultRow], plan: [Int] = [1, 1],
                    proven: [String]?, fingerprint: String) throws -> LocalTransferRecord {
            let id = try journal.enqueue(sourceURL: source, destinationURLs: destinations, verificationMode: .standard,
                                         cameraSettings: settings, reportSettings: ReportPrefs(makeReport: false),
                                         generateASCMHL: false)
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: plan)
            try journal.finish(id: id, results: rows, summary: "All files copied and verified", hadIssues: false,
                               sourceFingerprint: fingerprint, skippedFinderMetadataPaths: proven)
            return try #require(journal.records.first { $0.id == id })
        }
    }

    // MARK: - Journal

    @Test func aRecordWithProvenSkipsMatchesAsVerified() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let journal = TransferJournal(fileURL: f.journalURL)
        let record = try f.finish(journal, rows: f.provenRows, proven: [".DS_Store"], fingerprint: "card")
        #expect(record.skippedFinderMetadataPaths == [".DS_Store"])
        #expect(record.state == .completed, "a proven skip is not an issue: \(record.summary)")
        #expect(journal.matchingVerifiedRecord(sourceFingerprint: "card")?.id == record.id)
    }

    @Test func aRecordWithAnUnprovenSkippedRowDoesNotMatch() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let journal = TransferJournal(fileURL: f.journalURL)

        // Hand-edited status text with no proven list.
        let unproven = try f.finish(journal, rows: f.provenRows, proven: nil, fingerprint: "no-proof")
        #expect(unproven.state == .issues)
        #expect(journal.matchingVerifiedRecord(sourceFingerprint: "no-proof") == nil)

        // The proven list names a path with no row on one backup.
        let missing = f.destinations.flatMap { [f.verified("A001.mov", on: $0)] } + [f.skipped(".DS_Store", on: f.destinations[0])]
        let partial = try f.finish(journal, rows: missing, proven: [".DS_Store"], fingerprint: "missing-row")
        #expect(partial.state == .issues)
        #expect(journal.matchingVerifiedRecord(sourceFingerprint: "missing-row") == nil)

        // A plan that counted the skipped file is not covered by the selected rows,
        // so the record's own skipped rows cannot stand in for the manifest.
        try f.finish(journal, rows: f.provenRows, plan: [2, 2], proven: [".DS_Store"], fingerprint: "long-plan")
        #expect(journal.matchingVerifiedRecord(sourceFingerprint: "long-plan") == nil)

        // A proven path whose rows the final gate turned into failures.
        let failed = f.destinations.flatMap { destination -> [ResultRow] in
            let row = ResultRow(path: f.source.appendingPathComponent(".DS_Store").path, status: "❌ Failed",
                                size: 6148, checksum: nil, destination: destination.lastPathComponent,
                                destinationPath: f.output(".DS_Store", on: destination),
                                failureReason: ResultFailureReason.sourceUnstable.rawValue)
            return [f.verified("A001.mov", on: destination), row]
        }
        try f.finish(journal, rows: failed, proven: [".DS_Store"], fingerprint: "gate-failed")
        #expect(journal.matchingVerifiedRecord(sourceFingerprint: "gate-failed") == nil)
    }

    @Test func aHandEditedCompletedRecordWithoutProofDoesNotMatch() throws {
        let f = try Fixture(); defer { f.cleanup() }
        do {
            let journal = TransferJournal(fileURL: f.journalURL)
            try f.finish(journal, rows: f.provenRows, proven: [".DS_Store"], fingerprint: "card")
            #expect(journal.matchingVerifiedRecord(sourceFingerprint: "card") != nil)
        }
        let data = try Data(contentsOf: f.journalURL)
        var objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        objects[0].removeValue(forKey: "skippedFinderMetadataPaths")
        #expect(objects[0]["state"] as? String == "completed")
        try JSONSerialization.data(withJSONObject: objects).write(to: f.journalURL)
        let edited = TransferJournal(fileURL: f.journalURL)
        #expect(edited.records.first?.state == .completed)
        #expect(edited.matchingVerifiedRecord(sourceFingerprint: "card") == nil)

        objects[0]["skippedFinderMetadataPaths"] = ["DCIM/.DS_Store"]
        try JSONSerialization.data(withJSONObject: objects).write(to: f.journalURL)
        #expect(TransferJournal(fileURL: f.journalURL).matchingVerifiedRecord(sourceFingerprint: "card") == nil)
    }

    /// A checked-in 0.2.14-era journal, written by hand from the pre-Task-2
    /// keys (no `skippedFinderMetadataPaths`, no `skipFinderViewFiles`): the
    /// `.DS_Store` was copied and verified like any file on two backups, and
    /// the record keeps its verdict.
    @Test func aZeroPointTwoFixtureKeepsItsVerdict() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let fixture = try #require(Bundle.module.resourceURL)
            .appendingPathComponent("Fixtures/JournalCompatibility/record-0.2.14-verified.json")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        #expect(!text.contains("skippedFinderMetadataPaths"))
        #expect(!text.contains("skipFinderViewFiles"))
        try FileManager.default.copyItem(at: fixture, to: f.journalURL)

        let old = TransferJournal(fileURL: f.journalURL)
        let record = try #require(old.records.first)
        #expect(record.skippedFinderMetadataPaths == nil)
        #expect(record.cameraSettings.skipFinderViewFiles, "a missing toggle decodes as on")
        #expect(record.state == .completed)
        #expect(record.plannedFileCounts == [2, 2])
        #expect(record.results.count == 4)
        #expect(record.results.allSatisfy { $0.isVerifiedStatus })
        #expect(TransferJournal.finderMetadataSkipsProven(record), "no skipped row and no list: nothing to prove")
        #expect(old.matchingVerifiedRecord(sourceFingerprint: "fixture-0.2.14-card")?.id == record.id)
    }

    /// The rebuilt-manifest gate on its own: rows and list consistent, but no
    /// saved plan, so the record's rows cannot stand in for the manifest.
    @Test func aRecordWithoutAPlanCannotProveItsSkips() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let journal = TransferJournal(fileURL: f.journalURL)
        let record = try f.finish(journal, rows: f.provenRows, proven: [".DS_Store"], fingerprint: "card")
        #expect(TransferJournal.finderMetadataSkipsProven(record))
        var withoutPlan = record
        withoutPlan.plannedFileCounts = nil
        #expect(!TransferJournal.finderMetadataSkipsProven(withoutPlan))
        var shortPlan = record
        shortPlan.plannedFileCounts = [2, 2]
        #expect(!TransferJournal.finderMetadataSkipsProven(shortPlan))
    }

    // MARK: - Real runs

    private func writeCard(_ f: Fixture, appleDouble: Bool) throws {
        try FinderMetadataFixtures.bud1(size: 6148).write(to: f.source.appendingPathComponent(".DS_Store"))
        guard appleDouble else { return }
        var bytes = [UInt8](repeating: 0, count: 42)
        func put(_ value: UInt32, _ offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
        }
        put(0x00051607, 0); put(0x00020000, 4); bytes[25] = 1
        put(2, 26); put(38, 30); put(4, 34)
        try Data(bytes).write(to: f.source.appendingPathComponent("._A001.mov"))
    }

    private func run(_ f: Fixture, settings: CameraLabelSettings) async throws -> (FileOperation, [Int]?) {
        let totals = Mutex<[Int]?>(nil)
        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            .performFileOperation(sourceURL: f.source, destinationURLs: f.destinations, verificationMode: .standard,
                                  settings: settings, estimatedTotalBytes: nil,
                                  progressCallback: { update in
                                      if let counts = update.perDestinationTotals {
                                          totals.withLock { if $0 == nil { $0 = counts } }
                                      }
                                  }, onFileResult: nil)
        return (operation, totals.withLock { $0 })
    }

    @Test func aRealRunRecordsAPlanWithoutSkippedFilesAndMatches() async throws {
        try await FileOperationsTestLock.shared.run {
            let f = try Fixture(); defer { f.cleanup() }
            try writeCard(f, appleDouble: false)
            let (operation, plan) = try await run(f, settings: f.settings)
            #expect(operation.skippedFinderMetadataPaths == [".DS_Store"])
            #expect(plan == [1, 1], "the planned counts leave out the skipped .DS_Store")

            let journal = TransferJournal(fileURL: f.journalURL)
            let id = try journal.enqueue(sourceURL: f.source, destinationURLs: f.destinations, verificationMode: .standard,
                                         cameraSettings: f.settings, reportSettings: ReportPrefs(makeReport: false),
                                         generateASCMHL: false)
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: try #require(plan))
            try journal.finish(id: id, results: TransferCompletion.rows(from: operation), summary: "Done", hadIssues: false,
                               sourceFingerprint: operation.sourceFingerprint,
                               skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths)
            let fingerprint = try #require(operation.sourceFingerprint)
            #expect(journal.records.first?.state == .completed)
            #expect(journal.matchingVerifiedRecord(sourceFingerprint: fingerprint)?.id == id)
        }
    }

    @Test func mixedAppleDoubleAndSkipsStillQualifiesTheQueue() async throws {
        try await FileOperationsTestLock.shared.run {
            let f = try Fixture(); defer { f.cleanup() }
            try writeCard(f, appleDouble: true)
            var settings = f.settings
            settings.excludedAppleDoublePaths = ["._A001.mov"]
            let (operation, plan) = try await run(f, settings: settings)
            #expect(operation.skippedFinderMetadataPaths == [".DS_Store"])
            #expect(operation.reviewedAppleDoubleExclusionPaths == ["._A001.mov"])
            #expect(plan == [1, 1])
            let ordinary = TransferCompletion.ProjectGate(
                didPersist: true, locallySafe: nil, allowsQueueContinuationForExpectedExclusions: true,
                expectedExclusionQueueIdentity: .ordinaryTransfer)
            let qualification = TransferCompletion.expectedExclusionQueueQualification(
                operation: operation, expectedMode: .standard, handoffIssues: [], reportIssue: nil, project: ordinary)
            #expect(qualification == .ordinaryTransfer)

            // Never safe: the AppleDouble rule is separate and unchanged.
            let rows = TransferCompletion.rows(from: operation)
            let verdict = TransferCompletion.verdict(
                rows: rows, sourceFiles: operation.sourceManifest, destinations: f.destinations, source: f.source,
                settings: settings, mode: .standard, generateASCMHL: false, handoffIssues: [], reportIssue: nil,
                project: ordinary, skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths)
            #expect(!verdict.success)
            #expect(verdict.message.contains("whole card is not backed up"))

            // The queue rechecks the saved record, without the card.
            let journal = TransferJournal(fileURL: f.journalURL)
            let id = try journal.enqueue(sourceURL: f.source, destinationURLs: f.destinations, verificationMode: .standard,
                                         cameraSettings: settings, reportSettings: ReportPrefs(makeReport: false),
                                         generateASCMHL: false)
            try journal.markRunning(id: id)
            try journal.recordPlan(id: id, fileCounts: try #require(plan))
            try journal.finish(id: id, results: rows, summary: verdict.message, hadIssues: !verdict.success,
                               expectedExclusionQueueQualification: qualification,
                               sourceFingerprint: operation.sourceFingerprint,
                               skippedFinderMetadataPaths: operation.skippedFinderMetadataPaths)
            let record = try #require(journal.records.first { $0.id == id })
            #expect(record.state == .issues)
            #expect(record.expectedExclusionQueueQualification == .ordinaryTransfer)
            #expect(TransferJournal.permitsExpectedExclusionQueueContinuation(record))
            #expect(journal.matchingVerifiedRecord(sourceFingerprint: try #require(operation.sourceFingerprint)) == nil)

            // Without the proven list the skipped rows do not stand.
            var unproven = record
            unproven.skippedFinderMetadataPaths = nil
            #expect(!TransferJournal.permitsExpectedExclusionQueueContinuation(unproven))
            var withoutList = operation
            withoutList.skippedFinderMetadataPaths = nil
            #expect(TransferCompletion.expectedExclusionQueueQualification(
                operation: withoutList, expectedMode: .standard, handoffIssues: [], reportIssue: nil, project: ordinary) == nil)
            var noManifest = FileOperation(
                sourceURL: operation.sourceURL, destinationURLs: operation.destinationURLs, startTime: operation.startTime,
                endTime: operation.endTime, results: operation.results, sourceManifest: operation.sourceManifest?.filter {
                    $0.lastPathComponent != ".DS_Store"
                }, sourceFingerprint: operation.sourceFingerprint, verificationMode: operation.verificationMode,
                settings: operation.settings, estimatedTotalBytes: nil)
            noManifest.reviewedAppleDoubleExclusionPaths = operation.reviewedAppleDoubleExclusionPaths
            noManifest.skippedFinderMetadataPaths = operation.skippedFinderMetadataPaths
            #expect(TransferCompletion.expectedExclusionQueueQualification(
                operation: noManifest, expectedMode: .standard, handoffIssues: [], reportIssue: nil, project: ordinary) == nil,
                "a skipped path that is not on the card's manifest is not proven")

            // Unproven skips with an AppleDouble exclusion still say the whole card is not backed up.
            let unprovenVerdict = TransferCompletion.verdict(
                rows: rows, sourceFiles: operation.sourceManifest, destinations: f.destinations, source: f.source,
                settings: settings, mode: .standard, generateASCMHL: false, handoffIssues: [], reportIssue: nil,
                project: ordinary, skippedFinderMetadataPaths: nil)
            #expect(!unprovenVerdict.success)
            #expect(unprovenVerdict.message.contains("Skipped-file records do not match this run"))
            #expect(unprovenVerdict.message.contains("Keep the source: the whole card is not backed up"))
        }
    }

    // MARK: - Scope evidence

    @Test func scopeEvidenceCountsSkips() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let rows = f.destinations.flatMap {
            [f.verified("A001.mov", on: $0), f.skipped(".DS_Store", on: $0), f.skipped("DCIM/.DS_Store", on: $0)]
        }
        let scope = VerificationScopeEvidence(selectedMode: .standard, results: rows)
        #expect(scope.recordedSkippedFinderMetadata == 2)
        #expect(scope.recordedExcludedSourceFiles == 0)
        #expect(scope.recordedSelectedSourceFiles == 1)
        #expect(scope.recordedSelectedResults == 2)
        #expect(scope.exclusionLine == nil)
        let line = try #require(scope.finderMetadataSkipLine)
        #expect(line == "2 Finder view files skipped (not card content)")
        #expect(!line.contains("whole card"))
        #expect(!line.contains("excluded"))
        #expect(scope.hasConsistentRecordedCounts)

        let one = VerificationScopeEvidence(selectedMode: .standard, results: [f.verified("A001.mov", on: f.destinations[0]),
                                                                              f.skipped(".DS_Store", on: f.destinations[0])])
        #expect(one.finderMetadataSkipLine == "1 Finder view file skipped (not card content)")
        #expect(VerificationScopeEvidence(selectedMode: .standard, results: [f.verified("A001.mov", on: f.destinations[0])])
            .finderMetadataSkipLine == nil)
    }

    @Test func scopeEvidenceFromAnOlderReportDecodesWithNoSkips() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let scope = VerificationScopeEvidence(selectedMode: .standard, results: [f.verified("A001.mov", on: f.destinations[0])])
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) as? [String: Any])
        #expect(object["recordedSkippedFinderMetadata"] == nil, "a run with no skip writes the keys it wrote before")
        let skipped = VerificationScopeEvidence(selectedMode: .standard, results: [
            f.verified("A001.mov", on: f.destinations[0]), f.skipped(".DS_Store", on: f.destinations[0])])
        let roundTrip = try JSONDecoder().decode(VerificationScopeEvidence.self, from: JSONEncoder().encode(skipped))
        #expect(roundTrip.recordedSkippedFinderMetadata == 1)
        let old = try JSONDecoder().decode(VerificationScopeEvidence.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.recordedSkippedFinderMetadata == 0)
        #expect(old.hasConsistentRecordedCounts)
        object["recordedSkippedFinderMetadata"] = -1
        let negative = try JSONDecoder().decode(VerificationScopeEvidence.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(!negative.hasConsistentRecordedCounts)
    }
}
