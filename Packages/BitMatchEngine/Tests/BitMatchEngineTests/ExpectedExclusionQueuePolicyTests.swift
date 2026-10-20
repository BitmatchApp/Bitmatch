import Foundation
import XCTest
@testable import BitMatchEngine

final class ExpectedExclusionQueuePolicyTests: XCTestCase, @unchecked Sendable {
    private let ordinary = TransferCompletion.ProjectGate(
        didPersist: true, locallySafe: nil, allowsQueueContinuationForExpectedExclusions: true,
        expectedExclusionQueueIdentity: .ordinaryTransfer
    )

    private struct Fixture {
        let root: URL
        let source: URL
        let destinations: [URL]
        var settings: CameraLabelSettings {
            var value = CameraLabelSettings(); value.excludedAppleDoublePaths = ["._clip.bin"]; return value
        }
        var media: URL { source.appendingPathComponent("clip.bin") }
        var metadata: URL { source.appendingPathComponent("._clip.bin") }
        var journal: URL { root.appendingPathComponent("journal.json") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("expected-exclusion-queue-\(UUID())")
            source = root.appendingPathComponent("Card")
            destinations = [root.appendingPathComponent("BackupA"), root.appendingPathComponent("BackupB")]
            for folder in [source] + destinations { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            try Data("media".utf8).write(to: media)
            var bytes = [UInt8](repeating: 0, count: 42)
            func put(_ value: UInt32, _ offset: Int) {
                for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
            }
            put(0x00051607, 0); put(0x00020000, 4); bytes[25] = 1
            put(2, 26); put(38, 30); put(4, 34)
            try Data(bytes).write(to: metadata)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func row(source file: URL, destination: URL, excluded: Bool = false,
                 success: Bool = true, error: Error? = nil, verified: Bool = true) -> FileOperationResult {
            let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: settings)
                .appendingPathComponent(file.lastPathComponent)
            let verification = excluded || !verified ? nil : VerificationResult(
                sourceChecksum: "sha", destinationChecksum: "sha", matches: true,
                checksumType: .sha256, processingTime: 0, fileSize: 5
            )
            var value = FileOperationResult(sourceURL: file, destinationURL: output, success: success,
                error: error, fileSize: excluded ? 42 : 5, verificationResult: verification, processingTime: 0)
            value.excludedAppleDouble = excluded
            return value
        }
        func operation(rows: [FileOperationResult]? = nil, mode: VerificationMode = .standard,
                       proof: [String]? = ["._clip.bin"], manifest: [URL]? = nil,
                       fingerprint: String? = "synthetic-source-fingerprint", hasManifest: Bool = true, settings override: CameraLabelSettings? = nil) -> FileOperation {
            let values = rows ?? destinations.flatMap { [row(source: media, destination: $0), row(source: metadata, destination: $0, excluded: true, success: false)] }
            var value = FileOperation(sourceURL: source, destinationURLs: destinations, startTime: Date(), endTime: Date(),
                results: values, sourceManifest: hasManifest ? (manifest ?? [media, metadata]) : nil, sourceFingerprint: fingerprint,
                verificationMode: mode, settings: override ?? settings, estimatedTotalBytes: nil)
            value.reviewedAppleDoubleExclusionPaths = proof
            return value
        }
    }

    private func qualification(_ operation: FileOperation, handoff: [String] = [], report: String? = nil,
                               project: TransferCompletion.ProjectGate? = nil) -> ExpectedExclusionQueueQualification? {
        TransferCompletion.expectedExclusionQueueQualification(operation: operation, expectedMode: operation.verificationMode, handoffIssues: handoff,
            reportIssue: report, project: project ?? ordinary)
    }

    func testRealPipelineEarnsQueueQualificationWithoutWholeCardSuccess() async throws {
        try await FileOperationsTestLock.shared.run {
            let f = try Fixture(); defer { f.cleanup() }
            let beforeMedia = try Data(contentsOf: f.media), beforeMetadata = try Data(contentsOf: f.metadata)
            let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                .performFileOperation(sourceURL: f.source, destinationURLs: f.destinations, verificationMode: .standard,
                    settings: f.settings, progressCallback: { _ in }, onFileResult: nil)
            XCTAssertEqual(operation.reviewedAppleDoubleExclusionPaths, ["._clip.bin"])
            XCTAssertEqual(qualification(operation), .ordinaryTransfer)
            let verdict = TransferCompletion.verdict(rows: TransferCompletion.rows(from: operation),
                sourceFiles: operation.sourceManifest, destinations: f.destinations, source: f.source, settings: f.settings,
                mode: .standard, generateASCMHL: false, handoffIssues: [], reportIssue: nil, project: ordinary)
            XCTAssertFalse(verdict.success)
            XCTAssertFalse(verdict.copiedNotVerified)
            XCTAssertEqual(try Data(contentsOf: f.media), beforeMedia)
            XCTAssertEqual(try Data(contentsOf: f.metadata), beforeMetadata)
        }
    }

    func testManualStatusRowsWithoutPipelineProvenanceNeverQualify() throws {
        let f = try Fixture(); defer { f.cleanup() }
        XCTAssertNil(qualification(f.operation(proof: nil)))
        XCTAssertNil(qualification(f.operation(proof: ["._different.bin"])))
        XCTAssertNil(qualification(f.operation(fingerprint: nil)))
        XCTAssertNil(qualification(f.operation(hasManifest: false)))
        XCTAssertNil(TransferCompletion.expectedExclusionQueueQualification(operation: f.operation(), expectedMode: .thorough, handoffIssues: [], reportIssue: nil, project: ordinary))
        var settings = f.settings; settings.excludedAppleDoublePaths = nil
        XCTAssertNil(qualification(f.operation(settings: settings)))
    }

    func testMissingDuplicateUnverifiedAndUnexpectedRowsNeverQualify() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let rows = f.operation().results
        for mutated in [Array(rows.dropLast()), Array(rows.dropFirst()), rows + [rows[0]], rows + [rows[1]],
                        [f.row(source: f.media, destination: f.destinations[0], verified: false)] + Array(rows.dropFirst()),
                        [f.row(source: f.source.appendingPathComponent("unexpected.bin"), destination: f.destinations[0])] + Array(rows.dropFirst())] {
            XCTAssertNil(qualification(f.operation(rows: mutated)))
        }
    }

    func testSelectedTypedErrorsCannotHideBehindVerifiedStatus() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let rows = f.operation().results
        XCTAssertNil(qualification(f.operation(rows: [f.row(source: f.media, destination: f.destinations[0], success: false)] + Array(rows.dropFirst()))))
        XCTAssertNil(qualification(f.operation(rows: [f.row(source: f.media, destination: f.destinations[0], error: NSError(domain: "test", code: 1))] + Array(rows.dropFirst()))))
    }

    func testQuickHandoffReportAndUnknownProjectRemainBlocked() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let operation = f.operation()
        XCTAssertNil(qualification(f.operation(mode: .quick)))
        XCTAssertNil(qualification(operation, handoff: ["MHL failed"]))
        XCTAssertNil(qualification(operation, report: "Report failed"))
        XCTAssertNil(qualification(operation, project: .init(didPersist: false, locallySafe: nil)))
        XCTAssertNil(qualification(operation, project: .init(didPersist: true, locallySafe: false)))
        XCTAssertNil(qualification(operation, project: .init(didPersist: true, locallySafe: nil)))
        XCTAssertNil(qualification(operation, project: .init(didPersist: true, locallySafe: nil,
            allowsQueueContinuationForExpectedExclusions: true)))
    }

    func testExcludedOnlyChangedManifestAndUnreviewedMetadataRemainBlocked() throws {
        let f = try Fixture(); defer { f.cleanup() }
        XCTAssertNil(qualification(f.operation(rows: f.operation().results.filter(\.excludedAppleDouble), manifest: [f.metadata])))
        XCTAssertNil(qualification(f.operation(manifest: [f.media, f.metadata, f.source.appendingPathComponent("missing.bin")])))
        var settings = f.settings; settings.excludedAppleDoublePaths = ["._clip.bin", "._clip.bin"]
        XCTAssertNil(qualification(f.operation(settings: settings)))
        settings.excludedAppleDoublePaths = ["../._clip.bin"]
        XCTAssertNil(qualification(f.operation(proof: ["../._clip.bin"], settings: settings)))
    }

    func testFinalProjectScopeRequiresPositiveQualifierAndStillBlocksHandoffErrors() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let job = UUID(), card = UUID()
        let identity = ExpectedExclusionQueueQualification.projectTransfer(projectID: job, cardID: card)
        let project = TransferCompletion.ProjectGate(didPersist: true, locallySafe: false,
            allowsQueueContinuationForExpectedExclusions: true, expectedExclusionQueueIdentity: identity)
        XCTAssertFalse(project.permitsSuccess)
        XCTAssertEqual(qualification(f.operation(), project: project), identity)
        XCTAssertNil(qualification(f.operation(), handoff: ["MHL failed"], project: project))
        XCTAssertNil(qualification(f.operation(), report: "Report failed", project: project))
        XCTAssertNil(qualification(f.operation(), project: .init(didPersist: false, locallySafe: false,
            allowsQueueContinuationForExpectedExclusions: true, expectedExclusionQueueIdentity: identity)))
        XCTAssertNil(qualification(f.operation(), project: .init(didPersist: true, locallySafe: nil,
            allowsQueueContinuationForExpectedExclusions: true, expectedExclusionQueueIdentity: identity)))
    }

    private func finish(_ journal: TransferJournal, fixture f: Fixture, operation: FileOperation,
                        qualification: ExpectedExclusionQueueQualification? = .ordinaryTransfer,
                        projectID: UUID? = nil, cardID: UUID? = nil) throws -> UUID {
        let id = try journal.enqueue(sourceURL: f.source, destinationURLs: f.destinations, verificationMode: operation.verificationMode,
            cameraSettings: f.settings, reportSettings: ReportPrefs(makeReport: false), generateASCMHL: false,
            projectID: projectID, projectCardID: cardID)
        try journal.markRunning(id: id)
        try journal.recordPlan(id: id, fileCounts: [1, 1])
        try journal.finish(id: id, results: TransferCompletion.rows(from: operation), summary: "Selected scope only; keep source.",
            hadIssues: true, expectedExclusionQueueQualification: qualification, sourceFingerprint: operation.sourceFingerprint)
        return id
    }

    func testDurableQualificationSurvivesReloadAndSourceRemovalButNeverBecomesSafe() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var journal: TransferJournal? = TransferJournal(fileURL: f.journal)
        let id = try finish(journal!, fixture: f, operation: f.operation())
        let record = try XCTUnwrap(journal!.records.first { $0.id == id })
        XCTAssertEqual(record.state, .issues)
        XCTAssertTrue(TransferJournal.permitsExpectedExclusionQueueContinuation(record))
        XCTAssertNil(journal!.matchingVerifiedRecord(sourceFingerprint: "synthetic-source-fingerprint"))
        let rowIDs = record.results.map(\.id)
        journal = nil
        try FileManager.default.removeItem(at: f.source)
        let restored = TransferJournal(fileURL: f.journal)
        let saved = try XCTUnwrap(restored.records.first)
        XCTAssertEqual(saved.results.map(\.id), rowIDs)
        XCTAssertEqual(saved.state, .issues)
        XCTAssertTrue(TransferJournal.permitsExpectedExclusionQueueContinuation(saved))
    }

    func testLegacyUnknownOrStaleQualificationsFailClosed() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let journal = TransferJournal(fileURL: f.journal)
        _ = try finish(journal, fixture: f, operation: f.operation())
        let record = try XCTUnwrap(journal.records.first)
        for state in [LocalTransferState.running, .cancelled, .interrupted, .failed, .completed, .queued] {
            var changed = record; changed.state = state
            XCTAssertFalse(TransferJournal.permitsExpectedExclusionQueueContinuation(changed))
        }
        var changed = record; changed.plannedFileCounts = nil
        XCTAssertFalse(TransferJournal.permitsExpectedExclusionQueueContinuation(changed))
        changed = record; changed.results.removeLast()
        XCTAssertFalse(TransferJournal.permitsExpectedExclusionQueueContinuation(changed))
        changed = record; changed.expectedExclusionQueueQualification = nil
        XCTAssertFalse(TransferJournal.permitsExpectedExclusionQueueContinuation(changed))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        object["expectedExclusionQueueQualification"] = ["futureUnknownScope": [:]]
        let unknown = try JSONDecoder().decode(LocalTransferRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(unknown.expectedExclusionQueueQualification)
        XCTAssertEqual(unknown.results.map(\.id), record.results.map(\.id))
    }

    func testJournalRejectsWrongScopeAndMissingCoverageOrFingerprint() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let journal = TransferJournal(fileURL: f.journal)
        _ = try finish(journal, fixture: f, operation: f.operation(), qualification: .projectTransfer(projectID: UUID(), cardID: UUID()))
        XCTAssertNil(journal.records.first?.expectedExclusionQueueQualification)
        _ = try finish(journal, fixture: f, operation: f.operation(rows: Array(f.operation().results.dropLast())))
        XCTAssertNil(journal.records.first?.expectedExclusionQueueQualification)
        _ = try finish(journal, fixture: f, operation: f.operation(fingerprint: nil))
        XCTAssertNil(journal.records.first?.expectedExclusionQueueQualification)
        _ = try finish(journal, fixture: f, operation: f.operation(), projectID: UUID(), cardID: UUID())
        XCTAssertNil(journal.records.first?.expectedExclusionQueueQualification)
    }
}
