// SharedCompareFlowTests.swift
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct SharedCompareFlowTests {

    @Test
    func testCleanCompareDoesNotInheritPriorCopyFailures() async throws {
        #if os(macOS)
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bitmatch_clean_compare_\(UUID().uuidString)")
        let left = root.appendingPathComponent("left")
        let right = root.appendingPathComponent("right")
        try fileManager.createDirectory(at: left, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let contents = Data("matching".utf8)
        try contents.write(to: left.appendingPathComponent("clip.mov"))
        try contents.write(to: right.appendingPathComponent("clip.mov"))

        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: MacOSPlatformManager.shared,
                defaults: .isolatedWorkflowDefaults()
            )
        }
        await MainActor.run {
            coordinator.results = [
                ResultRow(
                    path: "/previous/failed.mov",
                    status: "Checksum mismatch",
                    size: 8,
                    checksum: nil,
                    destination: "Previous destination"
                )
            ]
            coordinator.errorService.reportWarning(
                "Previous operation warning",
                context: .general(operation: "Copy", stage: "Verification")
            )
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = left
            coordinator.rightURL = right
        }

        await coordinator.compareFolders()

        let outcome = await MainActor.run {
            let hasErrors = coordinator.hasErrors
            return (
                coordinator.results,
                hasErrors,
                CompletionVerdict.resolve(
                    state: coordinator.operationState,
                    rows: coordinator.results,
                    hasErrors: hasErrors,
                    hasCriticalErrors: coordinator.hasCriticalErrors
                )
            )
        }
        #expect(outcome.0.isEmpty)
        #expect(!outcome.1)
        #expect(outcome.2 == .success)
        #else
        #expect(true)
        #endif
    }

    @Test
    func testCompareFoldersCompletes() async throws {
        #if os(macOS)
        // Arrange: create two small folders with overlapping and unique files
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        let left = tmp.appendingPathComponent("bitmatch_cmp_left_\(UUID().uuidString)")
        let right = tmp.appendingPathComponent("bitmatch_cmp_right_\(UUID().uuidString)")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)

        // Files: A in both (different contents), B only left, C only right
        try Data("A".utf8).write(to: left.appendingPathComponent("A.txt"))
        try Data("B".utf8).write(to: left.appendingPathComponent("B.txt"))
        try Data("X".utf8).write(to: right.appendingPathComponent("A.txt"))
        try Data("C".utf8).write(to: right.appendingPathComponent("C.txt"))

        // Act: drive compare via SharedAppCoordinator
        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: MacOSPlatformManager.shared,
                defaults: .isolatedWorkflowDefaults()
            )
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = left
            coordinator.rightURL = right
        }
        await coordinator.compareFolders()

        // Assert: operation completes successfully
        let statsAndState = await MainActor.run { () -> (CompareStats?, Bool) in
            let completed: Bool
            if case .completed = coordinator.operationState { completed = true } else { completed = false }
            return (coordinator.lastCompareStats, completed)
        }
        #expect(statsAndState.1)
        // Validate counts: common=0, onlyLeft=1 (B), onlyRight=1 (C), mismatched=1 (A)
        #expect(statsAndState.0?.commonCount == 0)
        #expect(statsAndState.0?.onlyInLeftCount == 1)
        #expect(statsAndState.0?.onlyInRightCount == 1)
        #expect(statsAndState.0?.mismatchedCount == 1)

        // Cleanup
        try? fm.removeItem(at: left)
        try? fm.removeItem(at: right)
        #else
        #expect(true)
        #endif
    }

    @Test
    func testCompareKeepsFolderScopesOpenThroughVerification() async throws {
        let left = URL(fileURLWithPath: "/scoped/left")
        let right = URL(fileURLWithPath: "/scoped/right")
        let fileSystem = ScopeTrackingFileSystem(left: left, right: right)
        let platform = ScopeTrackingPlatformManager(fileSystem: fileSystem)
        let coordinator = await MainActor.run { ComparisonCoordinator(platformManager: platform) }

        let stats = try await coordinator.compareFolders(
            left: left,
            right: right,
            verificationMode: .quick,
            onProgress: { _ in }
        )

        #expect(stats.commonCount == 1)
        #expect(fileSystem.didReadSizesWhileScoped)
        #expect(fileSystem.activeScopeCount(for: left) == 0)
        #expect(fileSystem.activeScopeCount(for: right) == 0)
    }

    @Test
    func testCancellationDuringFinalChecksumStaysCancelled() async throws {
        let left = URL(fileURLWithPath: "/cancel/left")
        let right = URL(fileURLWithPath: "/cancel/right")
        let fileSystem = CancellingCompareFileSystem(left: left, right: right)
        let checksum = CancellingChecksumService()
        let platform = ScopeTrackingPlatformManager(fileSystem: fileSystem, checksum: checksum)
        let coordinator = await MainActor.run { ComparisonCoordinator(platformManager: platform) }
        checksum.onVerify = { await coordinator.requestCancellation() }

        do {
            _ = try await coordinator.compareFolders(
                left: left,
                right: right,
                verificationMode: .standard,
                onProgress: { _ in }
            )
            Issue.record("Cancelling during the final checksum must throw instead of returning stats")
        } catch is CancellationError {
            // Expected: cancellation remains cancelled.
        }
        #expect(fileSystem.activeScopeCount(for: left) == 0)
        #expect(fileSystem.activeScopeCount(for: right) == 0)
    }

    @Test
    func testCompareRetainsDifferingPaths() async throws {
        #if os(macOS)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bitmatch_cmp_paths_\(UUID().uuidString)")
        let left = root.appendingPathComponent("left")
        let right = root.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data("A".utf8).write(to: left.appendingPathComponent("A.txt"))
        try Data("B".utf8).write(to: left.appendingPathComponent("B.txt"))
        try Data("X".utf8).write(to: right.appendingPathComponent("A.txt"))
        try Data("C".utf8).write(to: right.appendingPathComponent("C.txt"))

        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: MacOSPlatformManager.shared,
                defaults: .isolatedWorkflowDefaults()
            )
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = left
            coordinator.rightURL = right
            coordinator.lastCompareStats = CompareStats(
                onlyInLeftCount: 0,
                onlyInRightCount: 0,
                commonCount: 1,
                mismatchedCount: 0
            )
        }
        await coordinator.compareFolders()

        let stats = await MainActor.run { coordinator.lastCompareStats }
        let retained = try #require(stats)
        #expect(retained.onlyInLeftPaths == ["B.txt"])
        #expect(retained.onlyInRightPaths == ["C.txt"])
        #expect(retained.mismatchedPaths == ["A.txt"])
        #expect(retained.onlyInLeftCount == retained.onlyInLeftPaths.count)
        #expect(retained.onlyInRightCount == retained.onlyInRightPaths.count)
        #expect(retained.mismatchedCount == retained.mismatchedPaths.count)
        #else
        #expect(true)
        #endif
    }

    @Test
    func testCompareReportExportNamesEveryPath() throws {
        let stats = CompareStats(
            onlyInLeftCount: 1,
            onlyInRightCount: 1,
            commonCount: 2,
            mismatchedCount: 1,
            onlyInLeftPaths: ["DCIM/B.MOV"],
            onlyInRightPaths: ["DCIM/C.MOV"],
            mismatchedPaths: ["DCIM/A,B.MOV"]
        )
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let csv = try CompareReportDocument(
            stats: stats,
            leftName: "Card",
            rightName: "Backup",
            verificationMode: .standard,
            exportedAt: exportedAt,
            asCSV: true
        )
        #expect(String(decoding: csv.data, as: UTF8.self) == """
            category,path
            "only-in-source","DCIM/B.MOV"
            "only-in-destination","DCIM/C.MOV"
            "content-differs","DCIM/A,B.MOV"

            """)

        let json = try CompareReportDocument(
            stats: stats,
            leftName: "Card",
            rightName: "Backup",
            verificationMode: .standard,
            exportedAt: exportedAt,
            asCSV: false
        )
        let payload = try #require(JSONSerialization.jsonObject(with: json.data) as? [String: Any])
        #expect(payload["left"] as? String == "Card")
        #expect(payload["right"] as? String == "Backup")
        #expect(payload["verificationMode"] as? String == VerificationMode.standard.rawValue)
        #expect(payload["clean"] as? Bool == false)
        #expect(payload["onlyInSource"] as? [String] == ["DCIM/B.MOV"])
        #expect(payload["onlyInDestination"] as? [String] == ["DCIM/C.MOV"])
        #expect(payload["mismatched"] as? [String] == ["DCIM/A,B.MOV"])

        let quickCSV = try CompareReportDocument(
            stats: stats,
            leftName: "Card",
            rightName: "Backup",
            verificationMode: .quick,
            exportedAt: exportedAt,
            asCSV: true
        )
        #expect(String(decoding: quickCSV.data, as: UTF8.self).contains("\"size-differs\",\"DCIM/A,B.MOV\""))
    }

    @Test
    func testChangingVerificationModeDiscardsInFlightCompare() async throws {
        let left = URL(fileURLWithPath: "/stale-mode/left")
        let right = URL(fileURLWithPath: "/stale-mode/right")
        let checksum = BlockingChecksumService()
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right),
            checksum: checksum
        )
        let coordinator = await MainActor.run {
            SharedAppCoordinator(platformManager: platform, defaults: .isolatedWorkflowDefaults())
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = left
            coordinator.rightURL = right
            coordinator.lastCompareStats = CompareStats(
                onlyInLeftCount: 0,
                onlyInRightCount: 0,
                commonCount: 1,
                mismatchedCount: 0
            )
        }

        let compareTask = Task { @MainActor in
            await coordinator.compareFolders()
        }
        await checksum.waitUntilVerificationStarts()
        await MainActor.run { coordinator.verificationMode = .quick }
        await checksum.release()
        await compareTask.value

        let stats = await MainActor.run { coordinator.lastCompareStats }
        #expect(stats == nil)
    }

    @Test
    func testChangingFolderSelectionDiscardsInFlightCompare() async throws {
        let left = URL(fileURLWithPath: "/stale-selection/left")
        let right = URL(fileURLWithPath: "/stale-selection/right")
        let replacement = URL(fileURLWithPath: "/stale-selection/replacement")
        let checksum = BlockingChecksumService()
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right),
            checksum: checksum
        )
        let coordinator = await MainActor.run {
            SharedAppCoordinator(platformManager: platform, defaults: .isolatedWorkflowDefaults())
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = left
            coordinator.rightURL = right
            coordinator.lastCompareStats = CompareStats(
                onlyInLeftCount: 0,
                onlyInRightCount: 0,
                commonCount: 1,
                mismatchedCount: 0
            )
        }

        let compareTask = Task { @MainActor in
            await coordinator.compareFolders()
        }
        await checksum.waitUntilVerificationStarts()
        await MainActor.run { coordinator.leftURL = replacement }
        await checksum.release()
        await compareTask.value

        let stats = await MainActor.run { coordinator.lastCompareStats }
        #expect(stats == nil)
    }

    // MARK: - UI plan steps 4.1 / 4.2 (each names its plantable bug)

    /// THESIS decision: Paranoid Compare runs a byte-by-byte comparison and
    /// SHA-256, on every platform, whatever `checksumTypes` lists.
    /// Plant: in `FolderComparer.contentsMatch`, change
    /// `if !identical { return false }` to `return identical`.
    @Test
    func testParanoidCompareRunsByteComparisonAndSHA256() async throws {
        let left = URL(fileURLWithPath: "/paranoid/left")
        let right = URL(fileURLWithPath: "/paranoid/right")
        let checksum = RecordingChecksumService()
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right),
            checksum: checksum
        )
        let coordinator = await MainActor.run { ComparisonCoordinator(platformManager: platform) }

        let stats = try await coordinator.compareFolders(
            left: left, right: right, verificationMode: .paranoid, onProgress: { _ in }
        )

        #expect(stats.isClean)
        #expect(checksum.byteComparisons == 1)
        #expect(checksum.verifiedTypes == [.sha256])
    }

    /// Bytes that agree do not excuse a SHA-256 mismatch in Paranoid mode.
    /// Plant: same as `testParanoidCompareRunsByteComparisonAndSHA256`.
    @Test
    func testParanoidCompareReportsChecksumMismatchEvenWhenBytesAgree() async throws {
        let left = URL(fileURLWithPath: "/paranoid-sha/left")
        let right = URL(fileURLWithPath: "/paranoid-sha/right")
        let checksum = RecordingChecksumService()
        checksum.checksumMatches = false
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right),
            checksum: checksum
        )
        let coordinator = await MainActor.run { ComparisonCoordinator(platformManager: platform) }

        let stats = try await coordinator.compareFolders(
            left: left, right: right, verificationMode: .paranoid, onProgress: { _ in }
        )

        #expect(stats.mismatchedPaths == ["clip.mov"])
    }

    /// A byte difference is a mismatch, and SHA-256 is not needed to find it.
    /// Plant: in `FolderComparer.contentsMatch`, delete
    /// `if !identical { return false }`.
    @Test
    func testParanoidCompareReportsByteMismatch() async throws {
        let left = URL(fileURLWithPath: "/paranoid-bytes/left")
        let right = URL(fileURLWithPath: "/paranoid-bytes/right")
        let checksum = RecordingChecksumService()
        checksum.bytesMatch = false
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right),
            checksum: checksum
        )
        let coordinator = await MainActor.run { ComparisonCoordinator(platformManager: platform) }

        let stats = try await coordinator.compareFolders(
            left: left, right: right, verificationMode: .paranoid, onProgress: { _ in }
        )

        #expect(stats.mismatchedPaths == ["clip.mov"])
        #expect(checksum.verifiedTypes.isEmpty)
    }

    /// Decision C-1, enforced below the screen too: ⌘R, tests or any other
    /// caller cannot compare a folder with itself and get "Folders match".
    /// Plant: in `SharedAppCoordinator.compareFolders`, delete the
    /// `if let block = CompareBlock.check(left: left, right: right) { … }` guard.
    @Test
    func testCoordinatorRefusesSameFolderCompare() async throws {
        let folder = URL(fileURLWithPath: "/same-folder/card")
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: folder, right: folder)
        )
        let coordinator = await MainActor.run {
            SharedAppCoordinator(platformManager: platform, defaults: .isolatedWorkflowDefaults())
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = folder
            coordinator.rightURL = folder
        }

        await coordinator.compareFolders()

        let (stats, end, completed) = await MainActor.run { () -> (CompareStats?, CompareRunEnd?, Bool) in
            if case .completed = coordinator.operationState {
                return (coordinator.lastCompareStats, coordinator.lastCompareEnd, true)
            }
            return (coordinator.lastCompareStats, coordinator.lastCompareEnd, false)
        }
        #expect(stats == nil)
        #expect(end == nil)
        #expect(!completed)
    }

    /// Plant: in `SharedAppCoordinator.canStartOperation`, restore the compare
    /// branch to `leftURL != nil && rightURL != nil && !isOperationInProgress`.
    @Test
    func testCanStartOperationRefusesNestedCompare() async throws {
        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: ScopeTrackingPlatformManager(fileSystem: FakeFileSystemService()),
                defaults: .isolatedWorkflowDefaults()
            )
        }
        let canStart = await MainActor.run { () -> (nested: Bool, separate: Bool) in
            coordinator.currentMode = .compareFolders
            coordinator.leftURL = URL(fileURLWithPath: "/nested/card")
            coordinator.rightURL = URL(fileURLWithPath: "/nested/card/DCIM")
            let nested = coordinator.canStartOperation
            coordinator.rightURL = URL(fileURLWithPath: "/nested/backup")
            return (nested, coordinator.canStartOperation)
        }
        #expect(!canStart.nested)
        #expect(canStart.separate)
    }

    /// A finished compare shows in the Compare screen, never as the transfer
    /// outcome summary (iPad used to show the transfer completion for it).
    /// Plant: in `SharedAppCoordinator.showsOutcomeSummary`, delete
    /// `guard !lastOperationWasCompare else { return false }`.
    @Test
    func testFinishedCompareIsNotTransferOutcome() async throws {
        let left = URL(fileURLWithPath: "/outcome/left")
        let right = URL(fileURLWithPath: "/outcome/right")
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right)
        )
        let coordinator = await MainActor.run {
            SharedAppCoordinator(platformManager: platform, defaults: .isolatedWorkflowDefaults())
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = left
            coordinator.rightURL = right
        }

        await coordinator.compareFolders()

        let (showsTransferOutcome, end) = await MainActor.run {
            (coordinator.showsOutcomeSummary, coordinator.lastCompareEnd)
        }
        #expect(end == .completed)
        #expect(!showsTransferOutcome)
    }

    /// A cancelled compare says so on the Compare screen instead of silently
    /// returning to selection (the old iPhone behaviour).
    /// Plant: in `SharedAppCoordinator.compareFolders`, delete
    /// `lastCompareEnd = .cancelled` from the `CancellationError` branch.
    @Test
    func testCancelledCompareRecordsCancelledOutcome() async throws {
        let left = URL(fileURLWithPath: "/cancel-outcome/left")
        let right = URL(fileURLWithPath: "/cancel-outcome/right")
        let checksum = CancellingChecksumService()
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right),
            checksum: checksum
        )
        let coordinator = await MainActor.run {
            SharedAppCoordinator(platformManager: platform, defaults: .isolatedWorkflowDefaults())
        }
        checksum.onVerify = {
            await MainActor.run {
                let run = coordinator.stateService.currentOperationId
                coordinator.cancelOperation()
                // Plant: log only activeStartID in cancelOperation. Compare has no
                // copy start ID, so its user-cancel event would lose this run.
                do {
                    let data = try TransferDiagnosticStore.shared.exportData()
                    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    let events = try #require(root["events"] as? [[String: Any]])
                    let id = try #require(run)
                    #expect(events.contains {
                        $0["run"] as? String == id.uuidString
                            && $0["event"] as? String == "cancelOrigin"
                            && $0["origin"] as? String == "user"
                    })
                } catch { Issue.record(error) }
            }
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = left
            coordinator.rightURL = right
        }

        await coordinator.compareFolders()

        let (end, stats) = await MainActor.run { (coordinator.lastCompareEnd, coordinator.lastCompareStats) }
        #expect(end == .cancelled)
        #expect(stats == nil)
        let outcome = CompareOutcome.resolve(stats: stats, end: end, mode: .standard)
        #expect(outcome == .cancelled)
    }

    /// Changing a folder after a compare drops the old outcome with the stats.
    /// Plant: in `SharedAppCoordinator.clearCompareOutcome`, delete `lastCompareEnd = nil`.
    @Test
    func testChangingFolderClearsCompareOutcome() async throws {
        let left = URL(fileURLWithPath: "/clear-outcome/left")
        let right = URL(fileURLWithPath: "/clear-outcome/right")
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right)
        )
        let coordinator = await MainActor.run {
            SharedAppCoordinator(platformManager: platform, defaults: .isolatedWorkflowDefaults())
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .standard
            coordinator.leftURL = left
            coordinator.rightURL = right
        }
        await coordinator.compareFolders()
        let before = await MainActor.run { coordinator.lastCompareEnd }
        #expect(before == .completed)

        let after = await MainActor.run { () -> CompareRunEnd? in
            coordinator.rightURL = URL(fileURLWithPath: "/clear-outcome/other")
            return coordinator.lastCompareEnd
        }
        #expect(after == nil)
    }

    /// THESIS decision: a clean Quick compare is recorded as "Sizes match,
    /// not verified", not "Folders match".
    /// Plant: in `SharedAppCoordinator.compareFolders`, replace the clean-stats
    /// message with `message = "Folders match"`.
    @Test
    func testQuickCompareMessageSaysNotVerified() async throws {
        let left = URL(fileURLWithPath: "/quick-message/left")
        let right = URL(fileURLWithPath: "/quick-message/right")
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right)
        )
        let coordinator = await MainActor.run {
            SharedAppCoordinator(platformManager: platform, defaults: .isolatedWorkflowDefaults())
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .quick
            coordinator.leftURL = left
            coordinator.rightURL = right
        }

        await coordinator.compareFolders()

        let message = await MainActor.run { () -> String? in
            if case .completed(let info) = coordinator.operationState { return info.message }
            return nil
        }
        #expect(message == "Sizes match, not verified")
    }

    /// Promise 2: a clean Quick compare is not a success, so nothing that
    /// reads `success` (the Dock tile's green check) can call it verified.
    /// Plant: in `SharedAppCoordinator.compareFolders`, pass
    /// `success: stats.isClean`.
    @Test
    func testQuickCompareIsNotRecordedAsVerified() async throws {
        let left = URL(fileURLWithPath: "/quick-success/left")
        let right = URL(fileURLWithPath: "/quick-success/right")
        let platform = ScopeTrackingPlatformManager(
            fileSystem: CancellingCompareFileSystem(left: left, right: right)
        )
        let coordinator = await MainActor.run {
            SharedAppCoordinator(platformManager: platform, defaults: .isolatedWorkflowDefaults())
        }
        await MainActor.run {
            coordinator.currentMode = .compareFolders
            coordinator.verificationMode = .quick
            coordinator.leftURL = left
            coordinator.rightURL = right
        }

        await coordinator.compareFolders()

        let state = await MainActor.run { coordinator.operationState }
        guard case .completed(let info) = state else {
            Issue.record("Expected a completed compare, got \(state)")
            return
        }
        #expect(!info.success)
        #expect(DockTileState.make(state: state, fraction: 1) != .verified)
    }

    /// Decision C-2: no mode switch while an operation runs.
    /// Plant: in `SharedAppCoordinator.switchMode`, delete
    /// `guard !isModeSwitchLocked else { return }`.
    @Test
    func testModeSwitchIsLockedWhileRunning() async throws {
        let coordinator = await MainActor.run {
            SharedAppCoordinator(
                platformManager: ScopeTrackingPlatformManager(fileSystem: FakeFileSystemService()),
                defaults: .isolatedWorkflowDefaults()
            )
        }
        let (whileRunning, afterwards) = await MainActor.run { () -> (AppMode, AppMode) in
            coordinator.currentMode = .compareFolders
            coordinator.isOperationInProgress = true
            coordinator.switchMode(to: .copyAndVerify)
            let whileRunning = coordinator.currentMode
            coordinator.isOperationInProgress = false
            coordinator.switchMode(to: .copyAndVerify)
            return (whileRunning, coordinator.currentMode)
        }
        #expect(whileRunning == .compareFolders)
        #expect(afterwards == .copyAndVerify)
    }
}

/// Records which content checks Compare ran.
private final class RecordingChecksumService: ChecksumService, @unchecked Sendable {
    private let lock = NSLock()
    private var _byteComparisons = 0
    private var _verifiedTypes: [ChecksumAlgorithm] = []
    var bytesMatch = true
    var checksumMatches = true

    var byteComparisons: Int { lock.withLock { _byteComparisons } }
    var verifiedTypes: [ChecksumAlgorithm] { lock.withLock { _verifiedTypes } }

    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String {
        "hash"
    }

    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        lock.withLock { _verifiedTypes.append(type) }
        return VerificationResult(
            sourceChecksum: "hash",
            destinationChecksum: checksumMatches ? "hash" : "other",
            matches: checksumMatches,
            checksumType: type,
            processingTime: 0,
            fileSize: 10
        )
    }

    func performByteComparison(
        sourceURL: URL,
        destinationURL: URL,
        progressCallback: ProgressCallback?
    ) async throws -> Bool {
        lock.withLock { _byteComparisons += 1 }
        return bytesMatch
    }
}

private final class CancellingCompareFileSystem: FakeFileSystemService {
    init(left: URL, right: URL) {
        super.init()
        leftResult = left
        rightResult = right
        freeSpaceResult = 1_000_000_000
    }

    override func getFileList(from folderURL: URL) async throws -> [URL] {
        [folderURL.appendingPathComponent("clip.mov")]
    }

    override nonisolated func getFileSize(for url: URL) throws -> Int64 { 10 }
}

/// `@unchecked Sendable`: `onVerify` is set once, before the compare runs.
private final class CancellingChecksumService: ChecksumService, @unchecked Sendable {
    var onVerify: (() async -> Void)?

    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String {
        "hash"
    }

    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        await onVerify?()
        return VerificationResult(
            sourceChecksum: "hash",
            destinationChecksum: "hash",
            matches: true,
            checksumType: type,
            processingTime: 0,
            fileSize: 10
        )
    }

    func performByteComparison(
        sourceURL: URL,
        destinationURL: URL,
        progressCallback: ProgressCallback?
    ) async throws -> Bool {
        await onVerify?()
        return true
    }
}

private enum ScopeTrackingError: Error {
    case missingScope(String)
}

private final class ScopeTrackingFileSystem: FakeFileSystemService {
    private let left: URL
    private let right: URL
    private let leftFile: URL
    private let rightFile: URL
    private let lock = NSLock()
    private(set) var didReadSizesWhileScoped = false

    init(left: URL, right: URL) {
        self.left = left
        self.right = right
        self.leftFile = left.appendingPathComponent("clip.mov")
        self.rightFile = right.appendingPathComponent("clip.mov")
        super.init()
        leftResult = left
        rightResult = right
        freeSpaceResult = 1_000_000_000
    }

    override func getFileList(from folderURL: URL) async throws -> [URL] {
        guard activeScopeCount(for: folderURL) > 0 else {
            throw ScopeTrackingError.missingScope("enumerating \(folderURL.path)")
        }
        if folderURL == left { return [leftFile] }
        if folderURL == right { return [rightFile] }
        return []
    }

    override nonisolated func getFileSize(for url: URL) throws -> Int64 {
        guard let base = baseURL(containing: url), activeScopeCount(for: base) > 0 else {
            throw ScopeTrackingError.missingScope("sizing \(url.path)")
        }
        lock.lock()
        didReadSizesWhileScoped = true
        lock.unlock()
        return 10
    }

    private nonisolated func baseURL(containing url: URL) -> URL? {
        if url.path.hasPrefix(left.path + "/") { return left }
        if url.path.hasPrefix(right.path + "/") { return right }
        return nil
    }
}

private final class ScopeTrackingChecksumService: ChecksumService {
    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String {
        "hash"
    }

    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        VerificationResult(
            sourceChecksum: "hash",
            destinationChecksum: "hash",
            matches: true,
            checksumType: type,
            processingTime: 0,
            fileSize: 10
        )
    }

    func performByteComparison(
        sourceURL: URL,
        destinationURL: URL,
        progressCallback: ProgressCallback?
    ) async throws -> Bool {
        true
    }
}

private actor ComparisonVerificationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func enter() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class BlockingChecksumService: ChecksumService {
    private let gate = ComparisonVerificationGate()

    func waitUntilVerificationStarts() async {
        await gate.waitUntilStarted()
    }

    func release() async {
        await gate.release()
    }

    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String {
        "hash"
    }

    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        await gate.enter()
        return VerificationResult(
            sourceChecksum: "hash",
            destinationChecksum: "hash",
            matches: true,
            checksumType: type,
            processingTime: 0,
            fileSize: 10
        )
    }

    func performByteComparison(
        sourceURL: URL,
        destinationURL: URL,
        progressCallback: ProgressCallback?
    ) async throws -> Bool {
        true
    }
}

private final class ScopeTrackingFileOperationsService: FileOperationsService {
    func performFileOperation(
        sourceURL: URL,
        destinationURLs: [URL],
        verificationMode: VerificationMode,
        settings: CameraLabelSettings,
        estimatedTotalBytes: Int64?,
        progressCallback: @escaping ProgressCallback,
        onFileResult: FileResultCallback?
    ) async throws -> FileOperation {
        FileOperation(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            startTime: Date(),
            endTime: Date(),
            results: [],
            verificationMode: verificationMode,
            settings: settings,
            estimatedTotalBytes: estimatedTotalBytes
        )
    }

    func cancelOperation() {}
    func pauseOperation() async {}
    func resumeOperation() async {}
}

private final class ScopeTrackingCameraDetectionService: CameraDetectionService {
    func detectCamera(from folderURL: URL) async -> CameraDetectionResult {
        CameraDetectionResult(
            cameraCard: nil,
            confidence: 0,
            metadata: [:],
            detectionMethod: "test",
            processingTime: 0
        )
    }

    func analyzeFolderStructure(at url: URL) async throws -> [String: Any] { [:] }
    func extractVideoMetadata(from fileURL: URL) async throws -> [String: Any] { [:] }
    func parseXMLMetadata(from fileURL: URL) async throws -> [String: Any] { [:] }
}

private final class ScopeTrackingPlatformManager: PlatformManager {
    nonisolated let fileSystem: FileSystemService
    nonisolated let checksum: ChecksumService
    nonisolated let fileOperations: FileOperationsService = ScopeTrackingFileOperationsService()
    nonisolated let cameraDetection: CameraDetectionService = ScopeTrackingCameraDetectionService()
    nonisolated let supportsDragAndDrop = false

    init(fileSystem: FileSystemService, checksum: ChecksumService = ScopeTrackingChecksumService()) {
        self.fileSystem = fileSystem
        self.checksum = checksum
    }

    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}
