import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct TransferRecoverySummaryTests {
    /// Plant: remove the saved mode's Quick check from recovery classification;
    /// a legacy match row must not become a verified copied/reused file.
    @MainActor @Test(arguments: [VerificationMode.quick, .standard, .thorough, .paranoid],
          [LocalTransferState.completed, .cancelled, .interrupted])
    func savedQuickRecoveryCountsRemainUnverified(mode: VerificationMode, state: LocalTransferState) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quick-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card")
        let backups = [root.appendingPathComponent("Backup A"), root.appendingPathComponent("Backup B")]
        for url in [source] + backups { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: source),
            destinations: try backups.map(LocalTransferResource.init(url:)), verificationMode: mode,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), retryOf: UUID())
        record.state = state
        record.plannedFileCounts = [4, 4]
        func row(_ path: String, _ status: String, _ destination: Int, reused: Bool = false) -> ResultRow {
            ResultRow(path: path, status: status, size: 10, checksum: "recorded-digest",
                destination: backups[destination].lastPathComponent,
                destinationPath: backups[destination].appendingPathComponent(path).path, wasReused: reused)
        }
        for index in backups.indices {
            record.results += [row("reused.mov", "✅ Match", index, reused: true),
                row("copied.mov", ResultOutcome.verified.statusText, index),
                row("failed.mov", ResultOutcome.failed.statusText, index),
                row("failed.mov", "✅ Match", index),
                row("._copied.mov", ResultOutcome.excludedAppleDouble.statusText, index)]
        }
        let originalIDs = record.results.map(\.id)
        let originalStatuses = record.results.map(\.status)
        let groups = TransferRecoverySummary.make(record)
        #expect(groups.count == 2)
        for group in groups {
            #expect(group.reused == (mode == .quick ? 0 : 1))
            #expect(group.copied == (mode == .quick ? 0 : 1))
            #expect(group.unverified == (mode == .quick ? 2 : 0))
            #expect(group.failed == 1)
            #expect(group.excluded == 1)
            #expect(group.pending == 1)
        }
        #expect(record.results.map(\.id) == originalIDs)
        #expect(record.results.map(\.status) == originalStatuses)
        #expect(record.results.allSatisfy { $0.checksum == "recorded-digest" })
        #expect(record.state == state)

        // Exercise the actual saved-record replay route. It reconciles the
        // overall verdict before creating the mode-aware per-backup summary.
        let session = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
            progress: nil, mountedSourceIDs: [])
        let replay = try #require(session.rows.first?.outcome)
        #expect(replay.safetyState == TransferLibraryPresentation.safetyState(for: record))
        #expect(replay.safetyState != .safeToErase)
        #expect(!replay.canEject)
        if mode == .quick {
            #expect(replay.counts.verified == 0)
            #expect(replay.counts.copiedNotVerified == 6)
            #expect(replay.bytesVerified == nil)
            #expect(replay.destinations.allSatisfy { !$0.detail.contains("files verified before the stop") })
        }
    }

    @Test func savedEvidenceSeparatesDestinationsAndDoesNotInflateDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-counts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card")
        let backups = [root.appendingPathComponent("Backup A"), root.appendingPathComponent("Backup B")]
        for url in [source] + backups { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: source),
            destinations: try backups.map(LocalTransferResource.init(url:)), verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), retryOf: UUID())
        record.state = .interrupted
        record.plannedFileCounts = [5, 5]
        func row(_ path: String, _ outcome: ResultOutcome, _ destination: Int, reused: Bool = false) -> ResultRow {
            ResultRow(path: path, status: outcome.statusText, size: 1, checksum: outcome.isVerified ? "abc" : nil,
                      destination: backups[destination].lastPathComponent,
                      destinationPath: backups[destination].appendingPathComponent("Card/\(path)").path, wasReused: reused)
        }
        record.results = [row("a", .verified, 0, reused: true), row("a", .verified, 0, reused: true),
                          row("b", .verified, 0), row("c", .failed, 0), row("._a", .excludedAppleDouble, 0),
                          row("a", .copiedUnverified, 1), row("b", .verified, 1), row("b", .checksumMismatch, 1)]
        var groups = TransferRecoverySummary.make(record)
        #expect(groups.count == 2)
        #expect(groups[0].reused == 1)
        #expect(groups[0].copied == 1)
        #expect(groups[0].failed == 1)
        #expect(groups[0].excluded == 1)
        #expect(groups[0].pending == 2)
        #expect(groups[1].reused == 0)
        #expect(groups[1].copied == 0)
        #expect(groups[1].unverified == 1)
        #expect(groups[1].failed == 1)
        #expect(groups[1].pending == 3)
        record.plannedFileCounts = nil
        #expect(TransferRecoverySummary.make(record).allSatisfy { $0.pending == nil })
        record.plannedFileCounts = [1, 5] // Inconsistent evidence cannot fabricate zero pending.
        #expect(TransferRecoverySummary.make(record)[0].pending == nil)
        record.results.append(ResultRow(path: "unknown", status: ResultOutcome.verified.statusText, size: 1,
                                        checksum: "abc", destination: "Unmatched backup"))
        groups = TransferRecoverySummary.make(record)
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.pending == nil })
        // Presentation must not mutate the unsafe terminal state or its underlying evidence.
        #expect(record.state == .interrupted)
        #expect(record.results.count == 9)
    }
}
