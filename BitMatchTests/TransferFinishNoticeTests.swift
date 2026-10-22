// TransferFinishNoticeTests.swift
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct TransferFinishNoticeTests {
    private let destinations = [
        URL(fileURLWithPath: "/Volumes/Shuttle A/Day 3"),
        URL(fileURLWithPath: "/Volumes/Shuttle B/Day 3"),
    ]

    private func notice(
        _ state: OperationState,
        issues: Int = 0,
        kind: TransferNotificationKind = .standaloneFinish
    ) -> TransferFinishNotice? {
        TransferFinishNotice.make(
            state: state,
            sourceName: "A001",
            destinations: destinations,
            issueCount: issues,
            kind: kind
        )
    }

    /// Promise 2: only a real success says the card is safe to erase.
    /// Plant: drop `where info.success` from the first case.
    @Test func onlySuccessSaysSafeToErase() {
        #expect(notice(.completed(.init(success: true, message: ""))) == .init(
            title: "A001 is safe to erase",
            body: "A001 is safe to erase. 2 backups verified.",
            kind: .standaloneFinish
        ))
        let quick = notice(.completed(.init(success: false, message: "", copiedNotVerified: true)))
        #expect(quick?.title == "A001 was copied without checksum verification")
        #expect(quick?.kind == .standaloneFinish)
        #expect(quick?.title.contains("safe") == false)
        let attention = notice(.completed(.init(success: false, message: "")), issues: 3)
        #expect(attention?.body == "Do not erase the card.")
        #expect(attention?.kind == .attention)
        #expect(notice(.failed)?.title == "A001: keep the card")
        #expect(notice(.failed)?.kind == .attention)
        #expect(notice(.completed(.init(success: true, message: "")), issues: 1)?.title == "A001: keep the card")
    }

    /// A Quick run whose report or project failed is not "copied, not
    /// verified": the engine leaves `copiedNotVerified` off, so it needs
    /// attention. Plant: match `.completed` on Quick mode instead of
    /// `info.copiedNotVerified`.
    @Test func safeBodyCountsBackupsAndAttentionKeepsTheCard() {
        let one = TransferFinishNotice.make(
            state: .completed(.init(success: true, message: "")), sourceName: "SD_CARD_042",
            destinations: [URL(fileURLWithPath: "/Volumes/A")], issueCount: 0, kind: .standaloneFinish)
        #expect(one?.body == "SD_CARD_042 is safe to erase. 1 backup verified.")
        let attention = TransferFinishNotice.make(
            state: .completed(.init(success: true, message: "")), sourceName: "SD_CARD_042",
            destinations: [URL(fileURLWithPath: "/Volumes/A")], issueCount: 1, kind: .standaloneFinish)
        #expect(attention?.title == "SD_CARD_042: keep the card")
        #expect(attention?.body == "Do not erase the card.")
    }

    @Test func quickWithAnotherFailureNeedsAttention() {
        #expect(notice(.completed(.init(success: false, message: "report failed")))?.title == "A001: keep the card")
    }

    @Test func interruptedIsAttentionAndIdleSendsNothing() {
        #expect(notice(.cancelled) == .init(
            title: "A001: keep the card",
            body: "Do not erase the card.",
            kind: .attention
        ))
        #expect(notice(.copying) == nil)
    }

    @Test func unqualifiedUnsafeNoticesDoNotClaimSafeOrVerifiedContents() {
        let unsafe = [
            notice(.completed(.init(success: false, message: "", copiedNotVerified: true))),
            notice(.completed(.init(success: false, message: "")), issues: 2),
            notice(.failed),
            notice(.cancelled)
        ]
        for notice in unsafe.compactMap({ $0 }) {
            let words = "\(notice.title) \(notice.body)".lowercased()
            #expect(!words.contains("safe to erase"))
            #expect(!words.contains("verified"))
        }

        let safe = notice(.completed(.init(success: true, message: "")))
        #expect(safe?.title.contains("safe to erase") == true)
        #expect(safe?.body.contains("verified") == true)
    }

    @Test func onlySafeToEraseUsesTheExplicitQueuedSuccessKind() {
        #expect(notice(
            .completed(.init(success: true, message: "")),
            kind: .queuedCardSuccess
        )?.kind == .queuedCardSuccess)
        #expect(notice(
            .completed(.init(success: false, message: "", copiedNotVerified: true)),
            kind: .queuedCardSuccess
        ) == nil)
    }

    @Test func queueFinishWordingIncludesItsTally() {
        #expect(TransferFinishNotice.queueFinished(
            title: "Queue stopped", tally: "3 safe to erase · 1 needs attention"
        ) == .init(
            title: "Queue stopped: 3 safe to erase · 1 needs attention",
            body: "",
            kind: .queueFinished
        ))
    }

    /// The settled record supplies both the card identity and the verdict;
    /// a later selection or the executor's early success cannot replace it.
    @Test func finishedRecordBuildsNotificationIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-notice-\(UUID())", isDirectory: true)
        let source = root.appendingPathComponent("A001", isDirectory: true)
        let backup = root.appendingPathComponent("Recorded Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: source),
            destinations: [try LocalTransferResource(url: backup)], verificationMode: .standard,
            cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs()
        )
        record.state = .completed
        record.plannedFileCounts = [1]
        record.results = [ResultRow(
            path: source.appendingPathComponent("clip.mov").path,
            status: ResultOutcome.verified.statusText, size: 4, checksum: "fixture",
            destination: backup.lastPathComponent,
            destinationPath: backup.appendingPathComponent("clip.mov").path
        )]

        let notice = TransferFinishNotice.make(record: record, kind: .standaloneFinish)

        #expect(notice?.title == "A001 is safe to erase")
        #expect(notice?.body == "A001 is safe to erase. 1 backup verified.")

        // No journal settlement means no notification, even if the executor
        // has already reached its in-memory success state.
        record.state = .running
        #expect(TransferFinishNotice.make(record: record, kind: .standaloneFinish) == nil)

        // A finished record without its selected-file plan is an attention
        // result, not a safe-to-erase notification.
        record.state = .completed
        record.plannedFileCounts = nil
        let settledState = try #require(TransferOutcomePresentation.recordedState(for: record))
        let kind = TransferNotificationDecision.kind(
            state: settledState, issueCount: 0, queueIsRunning: false,
            isReplayingQueuedTransfer: false, notifyAttention: true,
            notifyFinish: true, notifyEachQueuedCard: false
        )
        #expect(kind == .attention)
        #expect(TransferFinishNotice.make(record: record, kind: .standaloneFinish)?.title == "A001: keep the card")
    }

    private func selectedFileRecord(mode: VerificationMode = .standard) throws -> (URL, LocalTransferRecord) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-selected-notice-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("A001", isDirectory: true)
        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = ["._clip.mov"]
        let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: backup, settings: settings)
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: source),
            destinations: [try LocalTransferResource(url: backup)], verificationMode: mode,
            cameraSettings: settings, reportSettings: ReportPrefs(makeReport: false), generateASCMHL: false
        )
        record.state = .issues
        record.startedAt = Date().addingTimeInterval(-1)
        record.endedAt = Date()
        record.sourceFingerprint = "selected-notice-fixture"
        record.plannedFileCounts = [1]
        record.expectedExclusionQueueQualification = .ordinaryTransfer
        record.results = [
            ResultRow(path: source.appendingPathComponent("clip.mov").path,
                status: ResultOutcome.verified.statusText, size: 4, checksum: String(repeating: "a", count: 64),
                destination: backup.lastPathComponent, destinationPath: output.appendingPathComponent("clip.mov").path),
            ResultRow(path: source.appendingPathComponent("._clip.mov").path,
                status: ResultOutcome.excludedAppleDouble.statusText, size: 42, checksum: nil,
                destination: backup.lastPathComponent, destinationPath: output.appendingPathComponent("._clip.mov").path)
        ]
        return (root, record)
    }

    private func notificationKind(
        _ record: LocalTransferRecord, queue: Bool = false,
        attention: Bool = true, finish: Bool = true, eachCard: Bool = false
    ) -> TransferNotificationKind? {
        TransferNotificationDecision.kind(record: record, queueIsRunning: queue,
            isReplayingQueuedTransfer: queue, notifyAttention: attention,
            notifyFinish: finish, notifyEachQueuedCard: eachCard)
    }

    /// Plant: remove the durable selected-file branch from notification routing.
    @Test func selectedFileCompletionUsesFinishPreferencesWithoutAnAttentionNotice() throws {
        let (root, record) = try selectedFileRecord()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
        #expect(TransferLibraryPresentation.safetyState(for: record) == .needsAttention)
        #expect(notificationKind(record, attention: false) == .standaloneFinish)
        #expect(notificationKind(record, finish: false) == nil)
        #expect(notificationKind(record, queue: true, eachCard: false) == nil)
        #expect(notificationKind(record, queue: true, eachCard: true) == .queuedCardSuccess)
        let notice = try #require(TransferFinishNotice.make(record: record, kind: .standaloneFinish))
        #expect(notice.kind == .standaloneFinish)
        #expect(notice.title == "A001: selected files verified")
        #expect(!notice.body.localizedCaseInsensitiveContains("excluded"))
        #expect(!notice.title.localizedCaseInsensitiveContains("safe to erase"))
        #expect(!TransferLibraryPresentation.safetyState(for: record).canEject)
        #expect(record.state == .issues)
        #expect(record.results.count == 2)
    }

    /// Plant: accept excluded rows without the saved qualification or exact plan.
    @Test func failedMissingOrUnprovenSelectedResultsStillNeedAttention() throws {
        let (root, original) = try selectedFileRecord()
        defer { try? FileManager.default.removeItem(at: root) }
        var variants: [LocalTransferRecord] = []
        var noQualification = original
        noQualification.expectedExclusionQueueQualification = nil
        variants.append(noQualification)
        var missing = original
        missing.results.removeFirst()
        variants.append(missing)
        var failed = original
        let row = original.results[0]
        failed.results[0] = ResultRow(id: row.id, path: row.path,
            status: ResultOutcome.checksumMismatch.statusText, size: row.size, checksum: row.checksum,
            destination: row.destination, destinationPath: row.destinationPath)
        variants.append(failed)
        var noChecksum = original
        noChecksum.results[0] = ResultRow(id: row.id, path: row.path, status: row.status,
            size: row.size, checksum: nil, destination: row.destination, destinationPath: row.destinationPath)
        variants.append(noChecksum)
        var emptyChecksum = original
        emptyChecksum.results[0] = ResultRow(id: row.id, path: row.path, status: row.status,
            size: row.size, checksum: "", destination: row.destination, destinationPath: row.destinationPath)
        variants.append(emptyChecksum)
        var cancelled = original
        cancelled.state = .cancelled
        variants.append(cancelled)
        var interrupted = original
        interrupted.state = .interrupted
        variants.append(interrupted)
        for record in variants {
            #expect(!TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
            #expect(notificationKind(record) == .attention)
            #expect(TransferFinishNotice.make(record: record, kind: .standaloneFinish)?.kind == .attention)
        }
        var running = original
        running.state = .running
        #expect(notificationKind(running) == nil)
        #expect(TransferFinishNotice.make(record: running, kind: .standaloneFinish) == nil)
    }

    @Test func quickCannotUseAnExcludedMetadataProofForVerifiedFinishRouting() throws {
        let (root, quick) = try selectedFileRecord(mode: .quick)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!TransferOutcomePresentation.hasVerifiedSelectedFiles(quick))
        #expect(notificationKind(quick) == .attention)
        #expect(TransferFinishNotice.make(record: quick, kind: .standaloneFinish)?.kind == .attention)
    }
}
