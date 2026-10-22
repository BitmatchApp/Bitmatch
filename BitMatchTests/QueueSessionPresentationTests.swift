import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct QueueSessionPresentationTests {
    private func metaRow(_ fixture: QueuePresentationFixture, state: LocalTransferState = .completed,
                         mode: VerificationMode = .standard, fileOutcome: ResultOutcome = .verified,
                         summary: String = "Ready", ended: Bool = true,
                         files: Int? = 486, bytes: Int64 = 48_100_000_000) throws -> QueueSessionRow {
        var record = try fixture.record(name: "A7IV_CARD2", state: state, mode: mode, summary: summary,
                                        files: files, bytes: bytes, fileOutcome: fileOutcome,
                                        destinationNames: ["Shuttle A", "Shuttle B"])
        if mode == .quick { record.quickOnlyUnverified = true }
        record.endedAt = ended ? Date(timeIntervalSince1970: 1_760_992_860) : nil
        let queue = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: nil, mountedSourceIDs: [])
        return queue.rows[0]
    }

    private var newYork: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US")
        return cal
    }

    @Test func runningDetailNamesPhaseBackupFileAndRate() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(name: "B_CAM", state: .running, destinationNames: ["Shuttle A", "Shuttle B", "Shuttle C"])
        let progress = runningProgress(stage: .verifying, speed: 557_000_000, perDestination: [1, 0.4, 0])
        let row = try runningRow(record, progress)
        let detail = try #require(row.runningDetail(progress: progress, timeRemaining: "12 min", rate: "557 MB/s"))
        #expect(detail.metaLine == "Verifying Shuttle B · 2 of 3 backups · 218 GB")
        #expect(detail.currentFile == "B007C012.mov")
        #expect(detail.timeAndRate == "About 12 min · 557 MB/s")
    }

    @Test func runningDetailCoversPhasesAndFallbacks() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(name: "B_CAM", state: .running, destinationNames: ["Shuttle A", "Shuttle B"])
        func detail(_ p: OperationProgress, _ time: String?, rate: String? = nil) throws -> RunningRowDetail {
            try #require(try runningRow(record, p).runningDetail(progress: p, timeRemaining: time, rate: rate))
        }
        #expect(try detail(runningProgress(stage: .copying, speed: nil, perDestination: nil), nil).metaLine == "Copying to Shuttle A, Shuttle B · 218 GB")
        #expect(try detail(runningProgress(stage: .verifying, speed: nil, perDestination: [1, 1]), nil).metaLine == "Verifying Shuttle B · 2 of 2 backups · 218 GB")
        #expect(try detail(runningProgress(stage: .generating, speed: nil, perDestination: nil), nil).metaLine == "Finishing · 218 GB")
        #expect(try detail(runningProgress(stage: .preparing, speed: nil, perDestination: nil), nil).metaLine == "Preparing")
        #expect(try detail(runningProgress(stage: .copying, speed: nil, perDestination: nil, file: ""), nil).currentFile == nil)
        #expect(try detail(runningProgress(stage: .copying, speed: 557_000_000, perDestination: nil), TransferProgressPresentation.estimatingTimeLeft, rate: "557 MB/s").timeAndRate == "Estimating…")
        #expect(try detail(runningProgress(stage: .copying, speed: nil, perDestination: nil), "3 min").timeAndRate == "About 3 min")
        #expect(try detail(runningProgress(stage: .copying, speed: 557_000_000, perDestination: nil), nil, rate: "557 MB/s").timeAndRate == "557 MB/s")
        // The raw sample is never shown, and the averaged rate stays blank while it is still estimating.
        #expect(try detail(runningProgress(stage: .copying, speed: 557_000_000, perDestination: nil), nil).timeAndRate == nil)
        #expect(try detail(runningProgress(stage: .copying, speed: 557_000_000, perDestination: nil), "3 min",
            rate: TransferProgressPresentation.estimating).timeAndRate == "About 3 min")
        #expect(try detail(runningProgress(stage: .copying, speed: nil, perDestination: nil), nil).timeAndRate == nil)
        let waiting = try fixture.record(name: "A_CAM", state: .queued)
        let waitingRow = QueueSessionPresentation.make(records: [waiting], sessionIDs: [waiting.id], progress: nil, mountedSourceIDs: [waiting.id]).rows[0]
        #expect(waitingRow.runningDetail(progress: nil, timeRemaining: nil) == nil)
    }

    private func runningProgress(stage: ProgressStage, speed: Double?, perDestination: [Double]?, file: String = "/Volumes/B_CAM/CLIP/B007C012.mov") -> OperationProgress {
        OperationProgress(overallProgress: 0.61, currentFile: file, filesProcessed: 10, totalFiles: 20, currentStage: stage,
            speed: speed, elapsedTime: nil, averageSpeed: nil, peakSpeed: nil, bytesProcessed: nil, totalBytes: 218_000_000_000,
            perDestinationProgress: perDestination)
    }

    private func runningRow(_ record: LocalTransferRecord, _ progress: OperationProgress) throws -> QueueSessionRow {
        QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: progress, mountedSourceIDs: [record.id]).rows[0]
    }

    @Test func metaLineFollowsTheGrammar() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let row = try metaRow(fixture)
        #expect(row.metaLine(calendar: newYork) == "Verified 4:41 PM · Shuttle A, Shuttle B · 48.1 GB")
    }

    @Test func metaLineWithoutEndDateOmitsTime() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let row = try metaRow(fixture, ended: false)
        #expect(row.metaLine(calendar: newYork) == "Verified · Shuttle A, Shuttle B · 48.1 GB")
    }

    @Test func metaLineDropsSizeWhenEvidenceHasNone() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let row = try metaRow(fixture, state: .queued, ended: false, files: nil)
        #expect(row.evidence == nil)
        #expect(row.metaLine(calendar: newYork) == "Queued · Shuttle A, Shuttle B")
    }

    @Test func metaLineSaysCopiedForUnverifiedCopies() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let row = try metaRow(fixture, state: .issues, mode: .quick, fileOutcome: .copiedUnverified)
        #expect(row.safetyState == .copiedNotVerified)
        #expect(row.metaLine(calendar: newYork) == "Copied 4:41 PM · Shuttle A, Shuttle B · 48.1 GB")
    }

    @Test func metaLineUsesPlainCauseWhenStoppedOrPaused() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let cause = "Original selected-file plan was not saved; whole-card coverage cannot be confirmed. Keep the source."
        let paused = try metaRow(fixture, state: .issues, fileOutcome: .failed, summary: cause)
        #expect(paused.cause != nil)
        #expect(paused.metaLine(calendar: newYork).hasPrefix("Paused 4:41 PM · "))
        let failed = try metaRow(fixture, state: .failed, fileOutcome: .failed, summary: cause)
        let line = failed.metaLine(calendar: newYork)
        #expect(line.hasPrefix("Stopped 4:41 PM · "))
        #expect(line.split(separator: "·").count <= 3)
        #expect(!line.contains("Shuttle A"))
    }

    @Test func plainCauseReplacesEngineWords() {
        #expect(QueueSessionPresentation.plainCause(
            "Original selected-file plan was not saved; whole-card coverage cannot be confirmed. Keep the source.")
            == "can't confirm every file was copied")
        #expect(QueueSessionPresentation.plainCause("Destination is full; Source unreadable.") == "backup is full")
        #expect(QueueSessionPresentation.plainCause("Source disconnected.") == "card disconnected")
    }

    @Test func plainCauseKeepsNamesThatContainEngineWords() {
        #expect(QueueSessionPresentation.plainCause("Destination 2 is full") == "backup 2 is full")
        #expect(QueueSessionPresentation.plainCause("1 file failed on Destination 2") == "1 file failed on backup 2")
        #expect(QueueSessionPresentation.plainCause("Couldn't read resource.xml") == "Couldn't read resource.xml")
        #expect(QueueSessionPresentation.plainCause("Couldn't write to Resources and Sourcebook") == "Couldn't write to Resources and Sourcebook")
        #expect(QueueSessionPresentation.plainCause("All destinations are full") == "All backups are full")
    }

    @Test func metaLineUsesTheUsersClock() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let row = try metaRow(fixture)
        var german = newYork
        german.locale = Locale(identifier: "de_DE")
        #expect(row.metaLine(calendar: newYork).hasPrefix("Verified 4:41 PM"))
        #expect(row.metaLine(calendar: german).hasPrefix("Verified 16:41"))
    }

    @Test func everySafetyStateHasAPinnedLabelAndSymbol() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        func row(_ state: CardSafetyState, stage: QueueSessionRow.FailureStage? = nil) throws -> QueueSessionRow {
            let record = try fixture.record(name: "T", state: .completed)
            var base = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: nil, mountedSourceIDs: []).rows[0]
            base = QueueSessionRow(id: base.id, cardName: base.cardName, evidence: nil, destinations: "", safetyState: state,
                progressFraction: nil, action: nil, cause: nil, copySummary: "", outcome: nil, destinationNames: [],
                verificationModeName: "", failureStage: stage)
            return base
        }
        let table: [(CardSafetyState, QueueSessionRow.FailureStage?, String, String)] = [
            (.waiting, nil, "Queued", "clock"),
            (.preparing, nil, "Copying", "arrow.triangle.2.circlepath"),
            (.copying(progress: 10), nil, "Copying", "arrow.triangle.2.circlepath"),
            (.verifying(progress: 10), nil, "Verifying", "arrow.triangle.2.circlepath"),
            (.finishing(progress: 99), nil, "Copying", "arrow.triangle.2.circlepath"),
            (.safeToErase, nil, "Safe to erase", "checkmark.circle.fill"),
            (.copiedNotVerified, nil, "Copied, not verified", "circle.lefthalf.filled"),
            (.needsAttention, nil, "Keep the card", "exclamationmark.triangle.fill"),
            (.interrupted, nil, "Keep the card", "exclamationmark.triangle.fill"),
            (.failed, .copy, "Didn't copy", "xmark.octagon.fill"),
            (.failed, .verify, "Didn't verify", "xmark.octagon.fill"),
        ]
        for (state, stage, label, symbol) in table {
            let r = try row(state, stage: stage)
            #expect(r.queueLabel == label)
            #expect(r.queueSymbol == symbol)
            #expect((r.queueSymbol == "checkmark.circle.fill") == (state == .safeToErase))
        }
    }

    @Test func causeNamesTheBackupThatRanOutOfSpace() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let spaceless = try fixture.record(name: "A", state: .issues, results: [.failed, .failed, .failed], failureReason: "outOfSpace")
        let plain = try fixture.record(name: "B", state: .issues, results: [.failed, .failed, .failed])
        let queue = QueueSessionPresentation.make(records: [spaceless, plain], sessionIDs: [spaceless.id, plain.id],
            progress: nil, mountedSourceIDs: [])
        let spaceRow = try #require(queue.rows.first { $0.id == spaceless.id })
        let plainRow = try #require(queue.rows.first { $0.id == plain.id })
        #expect(spaceRow.cause == "Shuttle A ran out of space · 3 files failed")
        #expect(plainRow.cause == "3 files failed on Shuttle A")
    }

    @Test func queueLabelsSayWhatToDo() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let attention = try fixture.record(name: "A", state: .issues)
        let mismatch = try fixture.record(name: "B", state: .failed, results: [.checksumMismatch])
        let copyFail = try fixture.record(name: "C", state: .failed, results: [.failed])
        let interrupted = try fixture.record(name: "D", state: .interrupted)
        let queue = QueueSessionPresentation.make(records: [interrupted, copyFail, mismatch, attention],
            sessionIDs: [attention.id, mismatch.id, copyFail.id, interrupted.id],
            sessionRecordIDsInOrder: [attention.id, mismatch.id, copyFail.id, interrupted.id],
            progress: nil, mountedSourceIDs: [])
        #expect(queue.rows.map(\.queueLabel) == ["Keep the card", "Didn't verify", "Didn't copy", "Keep the card"])
        #expect(queue.rows[1].failureStage == .verify && queue.rows[2].failureStage == .copy)
        #expect(queue.rows[0].failureStage == nil)
        #expect(queue.rows.map(\.queueSymbol) == ["exclamationmark.triangle.fill", "xmark.octagon.fill", "xmark.octagon.fill", "exclamationmark.triangle.fill"])
        #expect(queue.tally.queueHeaderText == "2 keep the card · 2 didn't verify")
    }

    @Test func reviewedMetadataStaysQuietAfterEverySelectedFileVerified() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.metadataExclusionRecord()
        let queue = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
            progress: nil, mountedSourceIDs: [record.id])
        let row = try #require(queue.rows.first)
        let outcome = try #require(row.outcome)

        #expect(TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
        #expect(row.safetyState == .needsAttention)
        #expect(row.selectedFilesVerified)
        #expect(row.statusText == "Selected files verified")
        #expect(row.statusTint == .gray)
        #expect(row.statusSymbol == "checkmark.circle")
        #expect(row.queueSymbol == "checkmark.circle")
        #expect(row.action == nil && row.cause == nil)
        #expect(row.evidence?.hasPrefix("1 file ·") == true)
        let meta = row.metaLine()
        #expect(meta.hasPrefix("Verified"))
        #expect(!meta.contains("Paused") && !meta.contains("Stopped"))
        #expect(meta.contains("Shuttle A"))
        #expect(outcome.finishTitle == "Selected files verified — Card")
        #expect(outcome.verdict.title == "Selected files verified")
        #expect(outcome.verdict.detail == "1 file verified on 1 destination")
        #expect(outcome.issueLines.isEmpty && outcome.bannerGuidance == nil)
        #expect(!outcome.canRetry && outcome.primaryAction == .newTransfer)
        #expect(!outcome.canEject && !row.safetyState.isSafe)
        #expect(queue.ejectableCardIDs.isEmpty)
        #expect(queue.tally.selectedFilesVerified == 1 && queue.tally.needsAttention == 0)
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: queue.rows, reviewedIDs: []) == 0)
        #expect(QueueDockBadgePolicy.totalUnresolvedCount(
            rows: queue.rows, reviewedIDs: [], standaloneAttentionIDs: []) == 0)
        #expect(QueueDockBadgePolicy.totalUnresolvedCount(
            rows: queue.rows, reviewedIDs: [], standaloneAttentionIDs: [UUID()]) == 1)
        #expect(DockTileState.makeTransfer(state: .completed(.init(success: false, message: "Selected files verified")),
            record: record, fraction: 1) == .appIcon)
        #expect(DockTileState.makeTransfer(state: .copying, record: record, fraction: 0.4) == .running(percent: 40))
        #expect(DockTileState.makeTransfer(state: .completed(.init(success: false, message: "Review")),
            record: nil, fraction: 1) == .needsReview)
        #expect(outcome.destinations.count == 1)
        #expect(outcome.destinations.first?.needsAttention == false)
        #expect(outcome.destinations.first?.detail == "Checksums matched for 1 of 1 files")
        #expect(!row.copySummary.contains("needs attention"))
        #expect(!row.copySummary.contains("excluded"))

        let accessory = QueueAccessoryPresentation.make(queue: queue)
        #expect(accessory.title == "Selected files verified")
        #expect(accessory.tone == .neutral && accessory.attentionRecordID == nil)
        #expect(QueueAccessoryPresentation.attentionTokens(in: queue.rows).isEmpty)
        // Saved evidence still discloses the omission and never claims whole-card safety.
        #expect(record.results.count == 2)
        #expect(record.results.contains { ResultOutcome(statusText: $0.status) == .excludedAppleDouble })
        #expect(record.cameraSettings.excludedAppleDoublePaths == ["._clip.mov"])
        #expect(outcome.guidance.contains("whole card is not backed up"))
        let historyLabel = TransferLibraryPresentation.stateLabel(for: record)
        #expect(historyLabel.title == "Selected files verified" && historyLabel.tint == .gray)
        #expect(TransferLibraryPresentation.fileCount(for: record) == 1)
        #expect(MenuBarRecentTransfer.status(for: record)?.text == "Selected files verified")
        #expect(MenuBarRecentTransfer.status(for: record)?.needsAttention == false)
    }

    @Test func missingProofOrIncompleteEvidenceCannotQuietACompletedCard() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let original = try fixture.metadataExclusionRecord()
        var missingProof = original
        missingProof.expectedExclusionQueueQualification = nil
        var missingPlan = original
        missingPlan.plannedFileCounts = nil
        var missingFingerprint = original
        missingFingerprint.sourceFingerprint = nil
        var mismatchedProject = original
        mismatchedProject.expectedExclusionQueueQualification = .projectTransfer(projectID: UUID(), cardID: UUID())
        var missingRow = original
        missingRow.results.removeFirst()
        var duplicate = original
        duplicate.results.append(original.results[0])
        func replacingSelected(status: String, checksum: String?) -> ResultRow {
            let row = original.results[0]
            return ResultRow(id: row.id, path: row.path, status: status, size: row.size,
                checksum: checksum, destination: row.destination, destinationPath: row.destinationPath)
        }
        var failed = original
        failed.results[0] = replacingSelected(status: ResultOutcome.failed.statusText, checksum: nil)
        var unverified = original
        unverified.results[0] = replacingSelected(status: ResultOutcome.copiedUnverified.statusText, checksum: nil)
        var noDigest = original
        noDigest.results[0] = replacingSelected(status: ResultOutcome.verified.statusText, checksum: nil)
        var emptyDigest = original
        emptyDigest.results[0] = replacingSelected(status: ResultOutcome.verified.statusText, checksum: "")
        var cancelled = original
        cancelled.state = .cancelled
        var interrupted = original
        interrupted.state = .interrupted
        var handoffFailure = original
        handoffFailure.expectedExclusionQueueQualification = nil
        handoffFailure.summary = "ASC MHL could not be saved"
        let quick = try fixture.metadataExclusionRecord(mode: .quick)
        #expect(DockTileState.makeTransfer(state: .completed(.init(success: false, message: "Copied")),
            record: quick, fraction: 1) == .needsReview)
        for record in [missingProof, missingPlan, missingFingerprint, mismatchedProject, missingRow, duplicate, failed, unverified,
                       noDigest, emptyDigest, cancelled, interrupted, handoffFailure, quick] {
            #expect(!TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
            let row = try #require(QueueSessionPresentation.completedRow(for: record))
            #expect(!row.selectedFilesVerified)
            #expect(row.statusTint != .gray)
            #expect(row.action == .review)
            #expect(row.outcome?.canEject == false)
            #expect(TransferLibraryPresentation.stateLabel(for: record).title != "Selected files verified")
            #expect(MenuBarRecentTransfer.status(for: record)?.needsAttention == true)
        }
        for record in [missingProof, failed, handoffFailure, noDigest, emptyDigest] {
            let row = try #require(QueueSessionPresentation.completedRow(for: record))
            #expect(row.safetyState == .needsAttention)
            #expect(QueueDockBadgePolicy.unresolvedCount(rows: [row], reviewedIDs: []) == 1)
            #expect(QueueDockBadgePolicy.totalUnresolvedCount(
                rows: [row], reviewedIDs: [], standaloneAttentionIDs: []) == 1)
            #expect(DockTileState.makeTransfer(state: .completed(.init(success: false, message: "Review")),
                record: record, fraction: 1) == .needsReview)
        }
        for state in [LocalTransferState.queued, .running, .failed] {
            var record = original
            record.state = state
            #expect(!TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
        }
    }

    @Test func realFailureStillTakesPriorityBesideAQuietMetadataSelection() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let selected = try fixture.metadataExclusionRecord()
        let failed = try fixture.record(name: "B001", state: .issues, outcome: .failed, at: 2)
        let queue = QueueSessionPresentation.make(records: [failed, selected], sessionIDs: [selected.id, failed.id],
            progress: nil, mountedSourceIDs: [])
        #expect(queue.tally.selectedFilesVerified == 1)
        #expect(queue.tally.needsAttention == 1)
        #expect(queue.summaryTitle == "1 selected transfer verified · 1 keep the card")
        let accessory = QueueAccessoryPresentation.make(queue: queue)
        #expect(accessory.attentionRecordID == failed.id)
        #expect(accessory.tone == .warning)
        #expect(QueueAccessoryPresentation.attentionTokens(in: queue.rows).count == 1)
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: queue.rows, reviewedIDs: []) == 1)
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: queue.rows, reviewedIDs: [selected.id]) == 1)
        #expect(QueueDockBadgePolicy.totalUnresolvedCount(
            rows: queue.rows, reviewedIDs: [], standaloneAttentionIDs: [failed.id]) == 1)
    }

    @Test func dockBadgeShowsNothingWhenCleanAndTheCountOtherwise() {
        #expect(QueueDockBadgePolicy.badgeLabel(forCount: 0) == nil)
        #expect(QueueDockBadgePolicy.badgeLabel(forCount: 1) == "1")
        #expect(QueueDockBadgePolicy.badgeLabel(forCount: 12) == "12")
    }

    @Test func liveErrorsAndUnknownModeCannotUseTheQuietPresentation() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.metadataExclusionRecord()
        for flags in [(true, false, 0, 0), (false, true, 0, 0), (false, false, 1, 0), (false, false, 0, 1)] {
            let outcome = TransferOutcomePresentation.make(state: .completed(.init(success: false, message: "Review")),
                rows: record.results, destinations: record.destinations.map(\.url),
                hasErrors: flags.0, hasCriticalErrors: flags.1, errorCount: flags.2, warningCount: flags.3,
                duration: 1, verificationMode: .standard, canRetry: true, canExport: true,
                selectedFileVerificationQualified: true)
            #expect(!outcome.selectedFilesVerified)
            #expect(outcome.tint != .gray)
        }
        let unknownMode = TransferOutcomePresentation.make(state: .completed(.init(success: false, message: "Review")),
            rows: record.results, destinations: record.destinations.map(\.url),
            hasErrors: false, hasCriticalErrors: false, errorCount: 0, warningCount: 0,
            duration: 1, verificationMode: nil, canRetry: true, canExport: true,
            selectedFileVerificationQualified: true)
        #expect(!unknownMode.selectedFilesVerified)
    }

    @Test func rowsKeepQueueOrderAndRunningHeaderUsesFinished() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let safe = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let running = try fixture.record(name: "A002", state: .running, at: 2)
        let waiting = try fixture.record(name: "A003", state: .queued, at: 3)
        let progress = OperationProgress(
            overallProgress: 0.42, currentFile: "clip.mov", filesProcessed: 4, totalFiles: 10,
            currentStage: .copying, speed: nil, elapsedTime: nil, averageSpeed: nil,
            peakSpeed: nil, bytesProcessed: nil, totalBytes: nil, stageProgress: 0.42
        )

        let presentation = QueueSessionPresentation.make(
            records: [waiting, running, safe], sessionIDs: Set([safe.id, running.id, waiting.id]),
            progress: progress, mountedSourceIDs: Set([safe.id])
        )

        #expect(presentation.rows.map(\.cardName) == ["A001", "A002", "A003"])
        #expect(presentation.headerTitle == "Copying A002")
        #expect(presentation.headerDetail == "Card 2 of 3")
        #expect(presentation.rows[0].action == .eject)
        #expect(presentation.rows[1].safetyState == .copying(progress: 42))
        #expect(presentation.rows[1].oneLineStatus(timeRemaining: "3 min")
            .contains("A002 →"))
        #expect(presentation.rows[1].oneLineStatus(timeRemaining: "3 min")
            .contains("Copying 42% · 3 min left"))
        #expect(!presentation.rows[1].oneLineStatus(timeRemaining: "Estimating...")
            .contains("Estimating"))
        #expect(presentation.rows[2].action == nil)
        // The fixture backup lives in tmp, so its drive label is the live
        // boot-volume name (not the "Shuttle A" folder name): pin the
        // two-tier shape — compact drops the mode word, full keeps it.
        let drive = DestinationIdentityPresentation.title(for: fixture.backup)
        #expect(presentation.rows[2].compactWaitingText == "A003 → \(drive)")
        #expect(presentation.rows[2].waitingText == "A003 → \(drive) · Standard")
        #expect(presentation.rows[2].oneLineStatus().contains("· Waiting"))

        let verifyingProgress = OperationProgress(
            overallProgress: 0.7, currentFile: "clip.mov", filesProcessed: 7, totalFiles: 10,
            currentStage: .verifying, speed: nil, elapsedTime: nil, averageSpeed: nil,
            peakSpeed: nil, bytesProcessed: nil, totalBytes: nil, stageProgress: 0.4
        )
        let verifying = QueueSessionPresentation.make(
            records: [running], sessionIDs: [running.id], progress: verifyingProgress,
            mountedSourceIDs: []
        )
        #expect(verifying.rows.first?.oneLineStatus().contains("Verifying 70%") == true)
    }

    @Test func fileWorkAtOneHundredPercentIsStillFinishingWhileRecordRuns() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let running = try fixture.record(name: "A001", state: .running, at: 1)
        let progress = OperationProgress(
            overallProgress: 1, currentFile: nil, filesProcessed: 2, totalFiles: 2,
            currentStage: .completed, speed: nil, elapsedTime: nil, averageSpeed: nil,
            peakSpeed: nil, bytesProcessed: nil, totalBytes: nil, stageProgress: 1
        )

        let queue = QueueSessionPresentation.make(
            records: [running], sessionIDs: [running.id], progress: progress,
            mountedSourceIDs: []
        )
        let row = try #require(queue.rows.first)
        #expect(row.safetyState == .finishing(progress: 99))
        #expect(row.progressFraction == 0.99)
        #expect(row.oneLineStatus().contains("Finishing 99%"))
        #expect(queue.headerTitle == "Finishing A001")
        #expect(!row.safetyState.canEject)
    }

    /// Plant: filter `projectID != nil` records out of the session.
    @Test func projectRecordUsesTheSameRunningAndFinishedSafetyRows() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let projectID = UUID()
        let projectCardID = UUID()
        let running = try fixture.record(
            name: "PROJECT_CARD", state: .running, at: 1,
            projectID: projectID, projectCardID: projectCardID
        )
        let progress = OperationProgress(
            overallProgress: 0.6, currentFile: "clip.mov", filesProcessed: 1, totalFiles: 1,
            currentStage: .verifying, speed: nil, elapsedTime: nil, averageSpeed: nil,
            peakSpeed: nil, bytesProcessed: 64, totalBytes: 64, stageProgress: 0.6
        )
        let runningPresentation = QueueSessionPresentation.make(
            records: [running], sessionIDs: [running.id], progress: progress, mountedSourceIDs: []
        )
        #expect(runningPresentation.rows.first?.safetyState == .verifying(progress: 60))
        #expect(runningPresentation.rows.first?.progressFraction == 0.6)

        let safe = try fixture.record(
            name: "PROJECT_CARD", state: .completed, outcome: .verified, at: 1,
            projectID: projectID, projectCardID: projectCardID
        )
        let finishedPresentation = QueueSessionPresentation.make(
            records: [safe], sessionIDs: [safe.id], progress: nil, mountedSourceIDs: [safe.id]
        )
        let row = try #require(finishedPresentation.rows.first)
        #expect(row.safetyState == .safeToErase)
        #expect(row.outcome?.canExport == true)
    }

    @Test func waitingQueueDoesNotPretendItAlreadyStopped() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let first = try fixture.record(name: "A001", state: .queued, at: 1)
        let second = try fixture.record(name: "A002", state: .queued, at: 2)
        let presentation = QueueSessionPresentation.make(
            records: [second, first], sessionIDs: [first.id, second.id],
            progress: nil, mountedSourceIDs: [first.id, second.id]
        )

        #expect(presentation.summaryTitle == nil)
        #expect(!presentation.showsQueueSummary)
        #expect(presentation.tally.text == "2 queued")
    }

    @Test func tallyAndActionsPreserveEverySafetyClass() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let safe = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let quick = try fixture.record(
            name: "A002", state: .issues, mode: .quick, outcome: .copiedUnverified,
            quickOnlyUnverified: true, at: 2
        )
        let attention = try fixture.record(name: "A003", state: .issues, outcome: .failed, summary: "3 files failed on Shuttle B", at: 3)
        let failed = try fixture.record(name: "A004", state: .failed, summary: "A004 is not connected", at: 4)
        let interrupted = try fixture.record(name: "A005", state: .interrupted, summary: "Cancelled", at: 5)
        let waiting = try fixture.record(name: "A006", state: .queued, at: 6)
        let records = [waiting, interrupted, failed, attention, quick, safe]

        let presentation = QueueSessionPresentation.make(
            records: records, sessionIDs: Set(records.map(\.id)), progress: nil,
            mountedSourceIDs: Set([safe.id, quick.id, attention.id, failed.id, interrupted.id, waiting.id])
        )

        #expect(presentation.tally.text == "1 safe to erase · 1 copied, not verified · 1 keep the card · 1 didn't verify · 1 interrupted · 1 queued")
        #expect(presentation.summaryTitle == presentation.tally.text)
        #expect(presentation.ejectableCardIDs == [safe.id])
        #expect(presentation.rows.map(\.action) == [.eject, .review, .review, .review, .review, nil])
        #expect(!presentation.rows.dropFirst().contains { $0.safetyState.tint == .green })
    }

    @Test func finishedSummaryCopyTextAndEjectCountUseOnlyMountedSafeCards() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let first = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let second = try fixture.record(name: "A002", state: .completed, outcome: .verified, at: 2)
        let issue = try fixture.record(name: "A003", state: .issues, outcome: .failed, summary: "1 file failed on Shuttle A", at: 3)
        let records = [issue, second, first]
        let finishedAt = try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 26, hour: 18, minute: 42
        )))

        let presentation = QueueSessionPresentation.make(
            records: records, sessionIDs: Set(records.map(\.id)), progress: nil,
            mountedSourceIDs: Set([first.id, issue.id]), now: finishedAt
        )

        #expect(presentation.summaryTitle == "2 safe to erase · 1 keep the card")
        #expect(!presentation.showsEjectAllButton)
        #expect(presentation.ejectableCardIDs == [first.id])
        let lines = presentation.copySummary.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("Queue finished 18:42 ·"))
        #expect(lines[0].contains(presentation.tally.text))
        #expect(lines[1].contains("A001") && lines[1].contains("safe to erase"))
        // Backup identity deliberately prefers the volume over a temporary-folder
        // path (see backupIdentityPrefersTheVolumeAndNeverATemporaryPath), so a
        // fixture backup under the temp directory reports its volume name here.
        let expectedDrive = DestinationIdentityPresentation.title(for: fixture.backup)
        #expect(lines[3].contains("needs attention: 1 file failed on \(expectedDrive)"))
    }

    @Test func fullyReusedSafeRowSaysNothingNewWasCopied() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let repeated = try fixture.record(
            name: "A001", state: .completed, outcome: .verified,
            wasReused: true, at: 1
        )

        let row = try #require(QueueSessionPresentation.make(
            records: [repeated], sessionIDs: [repeated.id], progress: nil,
            mountedSourceIDs: [repeated.id]
        ).rows.first)

        #expect(row.safetyState == .safeToErase)
        #expect(row.copySummary.contains("verified, nothing new copied"))
        #expect(row.outcome?.verdict.detail.contains("verified, nothing new copied") == true)
    }

    @Test func pauseBannerUsesOnlyThePausedRecordAndNamesItsState() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let failed = try fixture.record(name: "A001", state: .failed, summary: "Disconnected", at: 1)
        let interrupted = try fixture.record(name: "A002", state: .interrupted, summary: "Cancelled", at: 2)
        let records = [interrupted, failed]
        let presentation = QueueSessionPresentation.make(
            records: records, sessionIDs: Set(records.map(\.id)), progress: nil,
            mountedSourceIDs: [], pausedRecordID: interrupted.id
        )
        #expect(presentation.pausedCardID == interrupted.id)
        #expect(presentation.pausedTitle == "Queue paused — A002 was interrupted")
        #expect(presentation.pausedCause == "Cancelled")
    }

    @Test func pausedCauseRemovesRepeatedEvidenceSentence() {
        let sentence = "ASC MHL history already exists"
        #expect(QueueSessionPresentation.deduplicatedCause(
            "\(sentence); \(sentence); \(sentence)"
        ) == sentence)
    }

    @Test func repeatedDestinationDriveNamesCollapseToACount() {
        #expect(QueueSessionPresentation.destinationSummary(
            ["Macintosh HD", "Macintosh HD", "Macintosh HD"]
        ) == "3 destinations on Macintosh HD")
        #expect(QueueSessionPresentation.destinationSummary(["RAID A", "RAID B"])
            == "2 destinations: RAID A, RAID B")
    }

    @Test func stoppedAndUnfinishedCopySummaryUseTheirActualTitles() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let failed = try fixture.record(name: "A001", state: .failed, summary: "Disconnected", at: 1)
        let waiting = try fixture.record(name: "A002", state: .queued, at: 2)
        let stopped = QueueSessionPresentation.make(
            records: [waiting, failed], sessionIDs: [failed.id, waiting.id], progress: nil, mountedSourceIDs: []
        )
        let waitingOnly = QueueSessionPresentation.make(
            records: [waiting], sessionIDs: [waiting.id], progress: nil, mountedSourceIDs: []
        )
        #expect(stopped.copySummary.hasPrefix("Queue stopped "))
        #expect(waitingOnly.copySummary.hasPrefix("Queue "))
        #expect(!waitingOnly.copySummary.hasPrefix("Queue finished"))
        #expect(QueueCommandPolicy.showsResume(hasSessionStarted: true, waitingCount: 1))
        #expect(!QueueCommandPolicy.showsResume(hasSessionStarted: false, waitingCount: 1))
        #expect(waitingOnly.rows.allSatisfy { $0.isEditable })
        #expect(stopped.rows.first(where: { $0.id == failed.id })?.isEditable == false)
    }

    @Test func allSafeQueueUsesCardCountAsItsSummaryTitle() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let records = try (1...4).map {
            try fixture.record(name: "A00\($0)", state: .completed, outcome: .verified, at: Double($0))
        }
        let presentation = QueueSessionPresentation.make(
            records: Array(records.reversed()), sessionIDs: Set(records.map(\.id)),
            sessionRecordIDsInOrder: records.map(\.id), progress: nil,
            mountedSourceIDs: Set(records.map(\.id))
        )

        #expect(presentation.summaryTitle == "4 cards safe to erase")
        #expect(presentation.showsEjectAllButton)
    }

    @Test func rowEjectActionRequiresSafeToEraseAndAMountedSource() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let safe = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let quick = try fixture.record(
            name: "A002", state: .issues, mode: .quick, outcome: .copiedUnverified,
            quickOnlyUnverified: true, at: 2
        )
        let attention = try fixture.record(name: "A003", state: .issues, outcome: .failed, at: 3)
        let records = [safe, quick, attention]
        let presentation = QueueSessionPresentation.make(
            records: records, sessionIDs: Set(records.map(\.id)),
            sessionRecordIDsInOrder: records.map(\.id), progress: nil,
            mountedSourceIDs: Set(records.map(\.id))
        )

        #expect(presentation.rows.map(\.action) == [.eject, .review, .review])
        #expect(presentation.ejectableCardIDs == [safe.id])
        #expect(presentation.rows[0].outcome?.finishTitle == "A001 is safe to erase")
        #expect(presentation.rows[1].outcome?.finishTitle == "A002 copied, not verified")
        #expect(presentation.rows[2].outcome?.finishTitle == "A003 needs attention")
        #expect(presentation.rows[0].showsSafeHero)
        #expect(!presentation.rows[1].showsSafeHero)
        #expect(!presentation.rows[2].showsSafeHero)
    }

    @Test func legacyCompletedRowDoesNotRepeatUnprovenSuccessInQueue() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        var record = try fixture.record(
            name: "A001", state: .completed, outcome: .verified,
            summary: "Selected files verified", at: 1
        )
        record.plannedFileCounts = nil

        let row = try #require(QueueSessionPresentation.make(
            records: [record], sessionIDs: [record.id], progress: nil,
            mountedSourceIDs: [record.id]
        ).rows.first)

        #expect(row.safetyState == .needsAttention)
        #expect(row.action == .review)
        #expect(row.cause?.contains("Original selected-file plan was not saved") == true)
        #expect(row.copySummary.contains("Original selected-file plan was not saved"))
        #expect(row.outcome?.visibleVerdictText.contains("Original selected-file plan was not saved") == true)
        #expect(!row.copySummary.contains("Selected files verified"))
        #expect(row.outcome?.visibleVerdictText.contains("Selected files verified") == false)
        #expect(record.summary == "Selected files verified")
    }

    @Test func nonSafeRowNeverOffersOrAutomaticallyTriggersEject() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let attention = try fixture.record(
            name: "A003", state: .issues, outcome: .failed, at: 1
        )
        let original = try #require(QueueSessionPresentation.make(
            records: [attention], sessionIDs: [attention.id], progress: nil,
            mountedSourceIDs: [attention.id]
        ).rows.first)
        let inconsistent = QueueSessionRow(
            id: original.id,
            cardName: original.cardName,
            evidence: original.evidence,
            destinations: original.destinations,
            safetyState: original.safetyState,
            progressFraction: original.progressFraction,
            action: .eject,
            cause: original.cause,
            copySummary: original.copySummary,
            outcome: original.outcome,
            destinationNames: original.destinationNames,
            verificationModeName: original.verificationModeName
        )

        #expect(inconsistent.safetyState != .safeToErase)
        #expect(!QueueEjectPolicy.canOfferEject(
            row: inconsistent, platformSupportsEject: true
        ))
        #expect(!QueueEjectPolicy.shouldAutoEject(
            row: inconsistent,
            platformSupportsEject: true,
            preferenceEnabled: true
        ))
    }

    @Test func heroExpansionRequiresANewSafeVerdictAndStopsForTheNextRunningCard() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let safe = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let running = try fixture.record(name: "A002", state: .running, at: 2)
        let safeRow = try #require(QueueSessionPresentation.make(
            records: [safe], sessionIDs: [safe.id], progress: nil, mountedSourceIDs: [safe.id]
        ).rows.first)
        let runningRows = QueueSessionPresentation.make(
            records: [running, safe], sessionIDs: [safe.id, running.id], progress: nil,
            mountedSourceIDs: [safe.id]
        ).rows

        #expect(QueueHeroPolicy.shouldExpand(row: safeRow, previousRows: [], currentRows: [safeRow]))
        #expect(!QueueHeroPolicy.shouldExpand(row: safeRow, previousRows: [safeRow], currentRows: [safeRow]))
        #expect(!QueueHeroPolicy.shouldExpand(row: safeRow, previousRows: [], currentRows: runningRows))
    }

    @Test func transitionObservationIgnoresProgressAndActivePhaseChanges() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let running = try fixture.record(name: "A001", state: .running, at: 1)
        let stages: [ProgressStage] = [.preparing, .copying, .copying, .verifying, .generating, .completed]
        let rows = try stages.enumerated().map { index, stage in
            let progress = OperationProgress(overallProgress: Double(index) / 6,
                currentFile: "clip-\(index).mov", filesProcessed: index, totalFiles: 6,
                currentStage: stage, speed: Double(index + 1))
            return try #require(QueueSessionPresentation.make(
                records: [running], sessionIDs: [running.id], progress: progress, mountedSourceIDs: []
            ).rows.first)
        }
        let first = try #require(rows.first)
        #expect(rows.dropFirst().allSatisfy { $0 != first })
        #expect(rows.allSatisfy { $0.isRunning && !$0.showsSafeHero })
        #expect(rows.map(QueueRowTransitionState.init).allSatisfy { $0 == QueueRowTransitionState(first) })
    }

    @Test func transitionObservationKeepsIdentityOrderRunningAndSafeVerdicts() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let waiting = try fixture.record(name: "A001", state: .queued, at: 1)
        let safe = try fixture.record(name: "A002", state: .completed, outcome: .verified, at: 2)
        func rows(_ records: [LocalTransferRecord]) -> [QueueSessionRow] {
            QueueSessionPresentation.make(records: records, sessionIDs: Set(records.map(\.id)),
                progress: nil, mountedSourceIDs: [safe.id]).rows
        }
        let initial = rows([waiting, safe]).map(QueueRowTransitionState.init)
        #expect(initial != Array(initial.reversed()))
        #expect(initial != rows([waiting]).map(QueueRowTransitionState.init))
        #expect(initial != rows([waiting, safe, try fixture.record(name: "A003", state: .queued, at: 3)])
            .map(QueueRowTransitionState.init))
        var running = waiting
        running.state = .running
        #expect(rows([waiting]).map(QueueRowTransitionState.init) != rows([running]).map(QueueRowTransitionState.init))
        var noVerdict = safe
        noVerdict.state = .issues
        noVerdict.results = []
        #expect(rows([noVerdict]).map(QueueRowTransitionState.init) != rows([safe]).map(QueueRowTransitionState.init))
        var retry = safe
        retry.state = .running
        #expect(rows([safe]).map(QueueRowTransitionState.init) != rows([retry]).map(QueueRowTransitionState.init))
    }

    @Test func projectedHeroInputsPreserveSafetyAndPreviousRowPolicy() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let safe = try fixture.record(name: "A001", state: .completed, outcome: .verified, at: 1)
        let running = try fixture.record(name: "A002", state: .running, at: 2)
        let failed = try fixture.record(name: "A003", state: .failed, outcome: .failed, at: 3)
        let quick = try fixture.record(name: "A004", state: .issues, mode: .quick,
            outcome: .copiedUnverified, quickOnlyUnverified: true, at: 4)
        let excludedOnly = try fixture.record(name: "A005", state: .issues, outcome: .excludedAppleDouble, at: 5)
        let records = [safe, running, failed, quick, excludedOnly]
        let rows = QueueSessionPresentation.make(records: records, sessionIDs: Set(records.map(\.id)),
            progress: nil, mountedSourceIDs: Set(records.map(\.id))).rows
        let safeRow = try #require(rows.first { $0.id == safe.id })
        let runningRow = try #require(rows.first { $0.id == running.id })
        #expect(rows.filter { [failed.id, quick.id, excludedOnly.id].contains($0.id) }.allSatisfy { !$0.showsSafeHero })
        for row in rows {
            for previous in [[], [row], [safeRow]] {
                for current in [[row], [row, runningRow], [row, safeRow]] {
                    let oldSemantics = row.showsSafeHero
                        && previous.first(where: { $0.id == row.id })?.showsSafeHero != true
                        && !current.contains { $0.id != row.id && $0.isRunning }
                    let prior = previous.map(QueueRowTransitionState.init)
                    #expect(QueueHeroPolicy.shouldExpand(row: row, previousRows: previous, currentRows: current) == oldSemantics)
                    #expect(QueueHeroPolicy.shouldExpand(row: row,
                        wasSafe: prior.first(where: { $0.id == row.id })?.showsSafeHero == true,
                        otherCardIsRunning: current.contains { $0.id != row.id && $0.isRunning }) == oldSemantics)
                }
            }
        }
    }

    @Test func accessibilityStatusCombinesCardStateCauseAndSafetyWarning() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let failed = try fixture.record(name: "A004", state: .failed, summary: "Card disconnected", at: 1)
        let row = try #require(QueueSessionPresentation.make(
            records: [failed], sessionIDs: [failed.id], progress: nil, mountedSourceIDs: []
        ).rows.first)
        #expect(row.accessibilityStatus == "A004, Failed, not safe to erase, Card disconnected")
    }

    @Test func zeroByteQueueEvidenceUsesEmptyWording() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(name: "A001", state: .completed, outcome: .verified, size: 0, at: 1)
        let row = try #require(QueueSessionPresentation.make(
            records: [record], sessionIDs: [record.id], progress: nil, mountedSourceIDs: [record.id]
        ).rows.first)
        #expect(row.evidence == "1 file · Empty")
        #expect(!row.evidence!.contains("Zero KB"))
    }

    @Test func pauseCommandAndDockResolutionPoliciesAreFailSafe() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let issue = try fixture.record(name: "A003", state: .failed, summary: "A003 is not connected", at: 1)
        let retry = try fixture.record(name: "A003", state: .completed, outcome: .verified, at: 2)
        let rowsBefore = QueueSessionPresentation.make(
            records: [issue], sessionIDs: [issue.id], progress: nil, mountedSourceIDs: []
        ).rows
        let rowsAfter = QueueSessionPresentation.make(
            records: [retry, issue], sessionIDs: [issue.id, retry.id], progress: nil, mountedSourceIDs: [retry.id]
        ).rows

        #expect(!QueueCommandPolicy.canRunQueue(isPausedOnProblem: true, waitingCount: 2))
        #expect(QueueCommandPolicy.canRunQueue(isPausedOnProblem: false, waitingCount: 2))
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: rowsBefore, reviewedIDs: []) == 1)
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: rowsBefore, reviewedIDs: [issue.id]) == 0)
        #expect(QueueDockBadgePolicy.unresolvedCount(rows: rowsAfter, reviewedIDs: []) == 0)
    }

    @Test func autoQueueUsesOnlyOneCandidateForEachNewVolumeIdentity() {
        let card = ConnectedDrivesPresentation.Volume(
            name: "A004", url: URL(fileURLWithPath: "/Volumes/A004"), totalBytes: 64, freeBytes: 32,
            isRemovable: true, isInternal: false, volumeID: "card-4", cameraName: "Alexa"
        )
        let backup = ConnectedDrivesPresentation.Volume(
            name: "Shuttle", url: URL(fileURLWithPath: "/Volumes/Shuttle"), totalBytes: 1_000, freeBytes: 500,
            isRemovable: true, isInternal: false, volumeID: "backup"
        )
        let remountedFirstCard = ConnectedDrivesPresentation.Volume(
            name: "A004", url: URL(fileURLWithPath: "/Volumes/A004 1"), totalBytes: 64, freeBytes: 32,
            isRemovable: true, isInternal: false, volumeID: "card-4", cameraName: "Alexa"
        )
        let rows = ConnectedDrivesPresentation.make(
            volumes: [card, backup, remountedFirstCard], sourceURL: nil, destinationURLs: []
        )
        #expect(AutoQueuePolicy.candidates(
            eligibleRows: rows, seenVolumeIDs: [], activeDestinationVolumeIDs: ["backup"]
        ).map(\.volumeID) == ["card-4"])
        #expect(AutoQueuePolicy.candidates(
            eligibleRows: rows, seenVolumeIDs: ["card-4"], activeDestinationVolumeIDs: []
        ).isEmpty)
    }

    @Test func repeatedAttemptsOfOneCardCollapseToLatestRow() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let first = try fixture.record(name: "A7IV_CARD1", state: .failed, at: 1)
        let second = try fixture.record(name: "A7IV_CARD1", state: .failed, at: 2)
        var third = try fixture.record(name: "A7IV_CARD1", state: .issues, at: 3)
        third.endedAt = Date(timeIntervalSince1970: 4)
        let queue = QueueSessionPresentation.make(
            records: [third, second, first], sessionIDs: [first.id, second.id, third.id],
            sessionRecordIDsInOrder: [first.id, second.id, third.id],
            progress: nil, mountedSourceIDs: [])
        #expect(queue.rows.count == 1)
        #expect(queue.rows[0].id == third.id)
        #expect(queue.rows[0].earlierAttemptIDs == [first.id, second.id])
        #expect(queue.rows[0].endedAt == third.endedAt)
    }

    @Test func differentCardsNeverCollapse() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let a = try fixture.record(name: "CardA", state: .failed, at: 1)
        let b = try fixture.record(name: "CardB", state: .failed, at: 2)
        let queue = QueueSessionPresentation.make(records: [b, a], sessionIDs: [a.id, b.id],
            sessionRecordIDsInOrder: [a.id, b.id], progress: nil, mountedSourceIDs: [])
        #expect(queue.rows.map(\.id) == [a.id, b.id])
    }

    @Test func queuedEarlierAttemptAndLaterEarlierNeverCollapse() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let queued = try fixture.record(name: "Card", state: .queued, at: 1)
        let later = try fixture.record(name: "Card", state: .failed, at: 2)
        let queue = QueueSessionPresentation.make(records: [later, queued], sessionIDs: [queued.id, later.id],
            sessionRecordIDsInOrder: [queued.id, later.id], progress: nil, mountedSourceIDs: [])
        #expect(queue.rows.map(\.id) == [queued.id, later.id])
        #expect(queue.rows.allSatisfy { $0.earlierAttemptIDs.isEmpty })
        // A finished attempt never absorbs the attempt before it when that one was clean.
        let done = try fixture.record(name: "Done", state: .completed, outcome: .verified, at: 3)
        let retry = try fixture.record(name: "Done", state: .failed, at: 4)
        let q2 = QueueSessionPresentation.make(records: [retry, done], sessionIDs: [done.id, retry.id],
            sessionRecordIDsInOrder: [done.id, retry.id], progress: nil, mountedSourceIDs: [])
        #expect(q2.rows.map(\.id) == [done.id, retry.id])
    }

    @Test func completedAttemptsThatNeedAttentionCollapse() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let first = try fixture.record(name: "A7IV_CARD1", state: .completed, outcome: .failed, at: 1)
        let second = try fixture.record(name: "A7IV_CARD1", state: .completed, outcome: .failed, at: 2)
        let third = try fixture.record(name: "A7IV_CARD1", state: .completed, outcome: .failed, at: 3)
        #expect(TransferLibraryPresentation.safetyState(for: first) == .needsAttention)
        let queue = QueueSessionPresentation.make(
            records: [third, second, first], sessionIDs: [first.id, second.id, third.id],
            sessionRecordIDsInOrder: [first.id, second.id, third.id],
            progress: nil, mountedSourceIDs: [])
        #expect(queue.rows.count == 1)
        #expect(queue.rows[0].id == third.id)
        #expect(queue.rows[0].earlierAttemptIDs == [first.id, second.id])
    }

    @Test func dockBadgeIncludesStandaloneAttentionSinceLaunch() {
        #expect(QueueDockBadgePolicy.totalUnresolvedCount(
            rows: [], reviewedIDs: [], standaloneAttentionIDs: [UUID(), UUID()]
        ) == 2)
    }

    @Test func ejectedRowBecomesRemovedWhenItsVolumeGoes() throws {
        let fixture = try QueuePresentationFixture()
        defer { fixture.cleanup() }
        let record = try fixture.record(name: "Card", state: .completed, outcome: .verified, at: 1)
        let ejected = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
            progress: nil, mountedSourceIDs: [], ejectedSourceIDs: [record.id])
        #expect(ejected.rows[0].action == .ejected)
        let removed = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
            progress: nil, mountedSourceIDs: [], ejectedSourceIDs: [record.id], removedSourceIDs: [record.id])
        #expect(removed.rows[0].action == .removed)
        let ejecting = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
            progress: nil, mountedSourceIDs: [record.id], ejectingSourceIDs: [record.id])
        #expect(ejecting.rows[0].action == .ejecting)
        // Removed only follows an eject; an unejected row stays on its own action.
        let notEjected = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
            progress: nil, mountedSourceIDs: [], removedSourceIDs: [record.id])
        #expect(notEjected.rows[0].action != .removed)
        // Eject All must not pick a card that is already unmounting.
        #expect(ejecting.ejectableCardIDs.isEmpty)
    }

    @Test func pausedRecordStillRunningInTheJournalIsReviewable() throws {
        let fixture = try QueuePresentationFixture(); defer { fixture.cleanup() }
        let record = try fixture.record(name: "A7IV_CARD1", state: .running)
        let queue = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: nil,
            mountedSourceIDs: [], pausedRecordID: record.id)
        let row = try #require(queue.rows.first)
        #expect(row.action == .review)
        #expect(!row.isRunning)
        #expect(row.queueLabel == "Keep the card")
        #expect(queue.pausedCardID == record.id)
        // Unpaused, the same record is still a running card.
        let live = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: nil, mountedSourceIDs: [])
        #expect(live.rows[0].isRunning)
    }

    @Test func pausedStripAndRemoveConfirmationWording() throws {
        let fixture = try QueuePresentationFixture(); defer { fixture.cleanup() }
        let record = try fixture.record(name: "A7IV_CARD1", state: .issues)
        let queue = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: nil,
            mountedSourceIDs: [], pausedRecordID: record.id)
        #expect(queue.pausedStripText == "Paused at A7IV_CARD1. Keep that card until you review it.")
        let confirm = try #require(QueueSessionPresentation.removeConfirmation(for: queue.rows[0]))
        #expect(confirm.title == "Remove A7IV_CARD1 from the queue?")
        #expect(confirm.message == "It isn't safe to erase yet. Files already copied stay on the backups.")
        let safe = try fixture.record(name: "S1", state: .completed, outcome: .verified)
        let safeQueue = QueueSessionPresentation.make(records: [safe], sessionIDs: [safe.id], progress: nil, mountedSourceIDs: [])
        let safeRow = try #require(safeQueue.rows.first)
        try #require(safeRow.safetyState.isSafe)
        #expect(QueueSessionPresentation.removeConfirmation(for: safeRow) == nil)
    }
}

private final class QueuePresentationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let backup: URL

    init() throws {
        backup = root.appendingPathComponent("Shuttle A")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func metadataExclusionRecord(mode: VerificationMode = .standard) throws -> LocalTransferRecord {
        let source = root.appendingPathComponent("Card")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var settings = CameraLabelSettings()
        settings.excludedAppleDoublePaths = ["._clip.mov"]
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: 1),
            source: try LocalTransferResource(url: source), destinations: [try LocalTransferResource(url: backup)],
            verificationMode: mode, cameraSettings: settings, reportSettings: ReportPrefs())
        record.state = .issues
        record.startedAt = Date(timeIntervalSince1970: 2)
        record.endedAt = Date(timeIntervalSince1970: 3)
        record.sourceFingerprint = "synthetic-fingerprint"
        record.plannedFileCounts = [1]
        record.expectedExclusionQueueQualification = .ordinaryTransfer
        record.summary = "Selected files verified; 1 AppleDouble file intentionally excluded. Keep the source"
        let destination = SafetyValidator.resolvedDestinationRoot(source: source, destination: backup, settings: settings)
        record.results = [ResultRow(path: source.appendingPathComponent("clip.mov").path,
            status: ResultOutcome.verified.statusText, size: 64, checksum: "abc",
            destination: backup.lastPathComponent, destinationPath: destination.appendingPathComponent("clip.mov").path),
            ResultRow(path: source.appendingPathComponent("._clip.mov").path,
            status: ResultOutcome.excludedAppleDouble.statusText, size: 42, checksum: nil,
            destination: backup.lastPathComponent, destinationPath: destination.appendingPathComponent("._clip.mov").path)]
        return record
    }

    func record(
        name: String,
        state: LocalTransferState,
        mode: VerificationMode = .standard,
        outcome: ResultOutcome? = nil,
        results outcomes: [ResultOutcome] = [],
        quickOnlyUnverified: Bool? = nil,
        size: Int64 = 64,
        summary: String = "Ready",
        wasReused: Bool = false,
        at seconds: TimeInterval = 0,
        projectID: UUID? = nil,
        projectCardID: UUID? = nil,
        files: Int? = nil,
        bytes: Int64 = 0,
        fileOutcome: ResultOutcome = .verified,
        destinationNames: [String]? = nil,
        failureReason: String? = nil
    ) throws -> LocalTransferRecord {
        let source = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let backups = try (destinationNames ?? []).map { name -> URL in
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        var record = LocalTransferRecord(
            id: UUID(), createdAt: Date(timeIntervalSince1970: seconds),
            source: try LocalTransferResource(url: source),
            destinations: try (backups.isEmpty ? [backup] : backups).map { try LocalTransferResource(url: $0) },
            verificationMode: mode, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(),
            projectID: projectID, projectCardID: projectCardID
        )
        record.state = state
        record.summary = summary
        record.quickOnlyUnverified = quickOnlyUnverified
        if let outcome {
            record.plannedFileCounts = [1]
            record.results = [ResultRow(
                path: source.appendingPathComponent("clip.mov").path,
                status: outcome.statusText, size: size, checksum: outcome == .verified ? "abc" : nil,
                destination: "Shuttle A", destinationPath: backup.appendingPathComponent("clip.mov").path,
                wasReused: wasReused
            )]
        }
        if !outcomes.isEmpty {
            record.plannedFileCounts = [outcomes.count]
            record.results = outcomes.enumerated().map { index, outcome in
                ResultRow(
                    path: source.appendingPathComponent("clip\(index).mov").path,
                    status: outcome.statusText, size: size, checksum: outcome == .verified ? "abc" : nil,
                    destination: "Shuttle A", destinationPath: backup.appendingPathComponent("clip\(index).mov").path,
                    wasReused: wasReused, failureReason: outcome == .verified ? nil : failureReason
                )
            }
        }
        if let files {
            let roots = backups.isEmpty ? [backup] : backups
            record.plannedFileCounts = roots.map { _ in files }
            record.results = roots.flatMap { destination in
                (0..<files).map { index in
                    ResultRow(
                        path: source.appendingPathComponent("clip\(index).mov").path,
                        status: fileOutcome.statusText, size: index == 0 ? bytes : 0,
                        checksum: fileOutcome == .verified ? "abc" : nil,
                        destination: destination.lastPathComponent,
                        destinationPath: destination.appendingPathComponent("clip\(index).mov").path
                    )
                }
            }
        }
        return record
    }
}
