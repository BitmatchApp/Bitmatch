// SharedAppCoordinator.swift - Platform-agnostic app coordination
import Foundation
import BitMatchEngine

// Uses SharedLogger (shared file) for logging across platforms
import SwiftUI
import Combine

#if !os(macOS)
import UIKit
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#endif

@MainActor
class SharedAppCoordinator: ObservableObject {
    enum CancellationSettlementError: LocalizedError, Equatable {
        case journalRecordMissing
        case journalStillRunning(String)

        var errorDescription: String? {
            switch self {
            case .journalRecordMissing:
                return "The transfer stopped, but BitMatch could not confirm its saved history. Keep the app open and review Transfers."
            case .journalStillRunning(let detail):
                return "The transfer stopped, but BitMatch could not save it as interrupted. \(detail)"
            }
        }
    }
    
    // MARK: - Platform Manager
    private let platformManager: PlatformManager
    
    // MARK: - Services
    @Published var timingService = OperationTimingService()
    @Published var errorService = ErrorReportingService()
    @Published var stateService = OperationStateService()
    
    // MARK: - Published State
    @Published var currentMode: AppMode = .copyAndVerify
    @Published var verificationMode: VerificationMode = .standard {
        didSet { if oldValue != verificationMode { clearCompareOutcome() } }
    }
    /// The camera label for the next transfer: suggested from the card,
    /// remembered per camera and saved across launches (thesis decision).
    let cameraLabels: CameraLabelModel
    var cameraLabelSettings: CameraLabelSettings {
        get { cameraLabels.settings }
        set { cameraLabels.settings = newValue }
    }
    /// Camera settings for the next run only, used instead of
    /// `cameraLabelSettings` and cleared when that run starts. A prepared
    /// project card puts its job's folder recipe here, so the recipe never
    /// becomes the saved label.
    var projectRunCameraSettings: CameraLabelSettings?
    /// Saved across launches with the Mac's keys (decision: iPad and iPhone
    /// remember report settings too). A queued transfer's replay uses its
    /// record's settings for that run only and never saves them.
    @Published var reportSettings = ReportPrefs() {
        didSet { if !isReplayingQueuedTransfer { reportPrefsStore.save(reportSettings) } }
    }
    private let reportPrefsStore: ReportPrefsStore
    @Published var generateASCMHL: Bool = UserDefaults.standard.object(forKey: "BitMatchGenerateASCMHL") as? Bool ?? true {
        didSet {
            if !isReplayingQueuedTransfer {
                UserDefaults.standard.set(generateASCMHL, forKey: "BitMatchGenerateASCMHL")
            }
        }
    }
    let transferJournal: LocalTransferJournal
    @Published private(set) var queueIsRunning = false
    @Published private(set) var queueMessage: String?
    @Published private(set) var isReplayingQueuedTransfer = false
    @Published private(set) var queueSessionRecordIDs: Set<UUID> = []
    @Published private(set) var reviewedQueueAttentionIDs: Set<UUID> = []
    @Published private(set) var skippedQueueAttentionIDs: Set<UUID> = []
    @Published private(set) var ejectedQueueSourceIDs: Set<UUID> = []
    @Published private(set) var standaloneAttentionRecordIDsSinceLaunch: Set<UUID> = []
    @Published private(set) var queuePausedRecordID: UUID?
    @Published private(set) var reviewedQueueRecordID: UUID?
    @Published private(set) var queueSessionEnded = false
    private var queueSessionRecordOrder: [UUID] = []
    private var isProcessingQueue = false
    private var activeJournalRecordID: UUID?
    private var queueFinishNotificationWasPosted = false
    private var queueStopWasRequested = false
    private var queueSessionSourceVolumeIDs: Set<String> = []
    private struct ReviewedSelectionSnapshot {
        let destinations: [URL]
        let verificationMode: VerificationMode
    }
    private var reviewedSelectionSnapshot: ReviewedSelectionSnapshot?
    @Published var photographerJobViewModel: PhotographerJobViewModel
    /// Setup's Quick/Project choice. Held here, not in a view, so every
    /// Start (button, ⌘R) obeys it: choosing Project blocks Start until a
    /// card is prepared (thesis decision S-2).
    @Published var usesProjectWorkflow = false
    var photographerReportFinalizer: PhotographerReportFinalizer?

    // MARK: - Operation State
    @Published var isOperationInProgress = false
    /// Stored once, in `stateService` (Promise 2): the verdict on screen and
    /// pause/resume can never disagree. Writes are adopted as reported.
    var operationState: OperationState {
        get { stateService.currentState }
        set { stateService.adopt(newValue) }
    }
    /// Emits before each `operationState` change, as the stored property's
    /// `$operationState` publisher did.
    var operationStatePublisher: Published<OperationState>.Publisher { stateService.$currentState }
    /// The engine's latest progress. Stored in `liveProgress`, not published
    /// here: it changes about every 500 ms, and every shell observes this
    /// coordinator, so a published copy redrew each whole window per tick.
    /// Views that draw live progress observe `liveProgress` directly.
    var progress: OperationProgress? {
        get { liveProgress.progress }
        set { liveProgress.progress = newValue }
    }
    /// Deliberately not forwarded to this object's `objectWillChange`.
    let liveProgress = LiveProgressFeed()
    /// Smoothed progress for display (rolling speed, ETA, per-destination
    /// bars). Deliberately not forwarded to this object's `objectWillChange`:
    /// it ticks every 250 ms, so views observe it directly.
    let progressPresentation = ProgressPresentationModel()
    /// General workflow choices, shared by Mac, iPad and iPhone.
    let generalSettings: GeneralSettings
    /// Background transfer notifications, filtered by `generalSettings`.
    let transferNotifier: TransferNotifier
    let transferSignals = PassthroughSubject<TransferSignal, Never>()
    /// Kept as the shared outcome screen's binding while the setting itself
    /// lives with the other General settings.
    var autoEjectWhenSafe: Bool {
        get { generalSettings.autoEjectWhenSafe }
        set { generalSettings.autoEjectWhenSafe = newValue }
    }
    static let autoEjectPreferenceKey = GeneralSettings.autoEjectKey
    @Published private(set) var showsNotificationPermissionPrompt = false
    private var lastPresentedBytes: Int64 = 0
    /// Backups in the run being presented, so a later change of selection
    /// cannot mismatch the per-destination bars.
    private var presentedDestinationCount: Int?
    /// The run's per-file results. Stored in `liveResults`, the one copy the
    /// outcome screen, verdict, journal and export read. Writing the whole
    /// list here (clear, or the engine's authoritative list) announces the
    /// change on this coordinator as the published property did; a live
    /// per-file row goes through `receiveLiveResult(_:)` and does not, so
    /// the shells are not redrawn once per file per backup.
    var results: [ResultRow] {
        get { liveResults.rows }
        set {
            objectWillChange.send()
            liveResults.replace(with: newValue)
        }
    }
    /// Deliberately not forwarded to this object's `objectWillChange`.
    /// Views that list live results observe it directly.
    let liveResults = LiveResultsFeed()
    @Published var currentOperation: FileOperation?

    // MARK: - Sub-coordinators
    private lazy var copyVerifyExecutor: CopyVerifyExecutor = {
        CopyVerifyExecutor(
            platformManager: platformManager,
            timingService: timingService,
            errorService: errorService,
            stateService: stateService,
            backgroundTaskService: backgroundTaskService
        )
    }()
    private(set) lazy var comparisonCoordinator: ComparisonCoordinator = {
        ComparisonCoordinator(platformManager: platformManager)
    }()

    enum CompletionExportError: LocalizedError {
        case noFinishedTransfer
        var errorDescription: String? {
            "No finished transfer to export. Run a transfer first; completed transfers stay available under History."
        }
    }
    
    // MARK: - File Selection State
    @Published var sourceURL: URL?
    @Published var destinationURLs: [URL] = [] {
        didSet {
            destinationVolumeNames = destinationURLs.map(DestinationVolumeLabel.resolve)
        }
    }
    /// Resolved once per selection change, never once per progress tick.
    private(set) var destinationVolumeNames: [String] = []
    @Published var leftURL: URL? { // For folder comparison
        didSet { if oldValue != leftURL { clearCompareOutcome() } }
    }
    @Published var rightURL: URL? { // For folder comparison
        didSet { if oldValue != rightURL { clearCompareOutcome() } }
    }
    
    // MARK: - Camera Detection State
    @Published var detectedCamera: CameraCard?
    @Published var cameraDetectionInProgress = false
    
    // MARK: - Folder Info State (delegated to FolderInfoService)
    // One per coordinator (the app has one); a shared singleton let parallel
    // tests change each other's source analysis.
    @Published var folderInfoService = FolderInfoService()
    @Published var lastCompareStats: CompareStats?
    /// How the last compare for the current folders and mode ended. Compare
    /// reads this, not `operationState`, which transfers also write.
    @Published private(set) var lastCompareEnd: CompareRunEnd?
    /// True when the most recent operation was a compare, so the shared
    /// `operationState` it left behind is not shown as a transfer outcome.
    @Published private(set) var lastOperationWasCompare = false

    private func clearCompareOutcome() {
        lastCompareStats = nil
        lastCompareEnd = nil
    }

    // Convenience accessors for folder info (delegated to service)
    var sourceFolderInfo: EnhancedFolderInfo? { folderInfoService.sourceFolderInfo }
    var leftFolderInfo: EnhancedFolderInfo? { folderInfoService.leftFolderInfo }
    var rightFolderInfo: EnhancedFolderInfo? { folderInfoService.rightFolderInfo }
    var destinationFolderInfos: [URL: EnhancedFolderInfo] { folderInfoService.destinationFolderInfos }
    var folderInfoLoadingState: [URL: Bool] { folderInfoService.folderInfoLoadingState }
    
    private var cancellables = Set<AnyCancellable>()
    private var activeStartID: UUID?
    private var startCancellationRequested = false
    private var activeProjectCardID: UUID?

    // MARK: - iOS Background Task Service
    private let backgroundTaskService = IOSBackgroundTaskService.shared

    // Convenience accessors for iOS background state
    var backgroundTimeRemainingSeconds: Double? { backgroundTaskService.backgroundTimeRemainingSeconds }
    var isInBackground: Bool { backgroundTaskService.isInBackground }

    // MARK: - Initialization
    
    init(
        platformManager: PlatformManager,
        transferJournal: LocalTransferJournal? = nil,
        projectStore: (any PhotographerJobStore)? = nil,
        photographerJobViewModel: PhotographerJobViewModel? = nil,
        preferences: UserDefaults? = nil
    ) {
        self.platformManager = platformManager
        let environment = ProcessInfo.processInfo.environment
        let isTesting = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
        let testJournalURL = isTesting ? FileManager.default.temporaryDirectory
            .appendingPathComponent("BitMatchTestJournal-\(UUID().uuidString).json") : nil
        // Tests get a throwaway suite so they never read or change the
        // user's saved settings; pass `preferences` to test persistence.
        let selectedPreferences: UserDefaults
        if let preferences {
            selectedPreferences = preferences
        } else if isTesting, let testDefaults = UserDefaults(suiteName: Self.testPreferencesSuite) {
            testDefaults.removePersistentDomain(forName: Self.testPreferencesSuite)
            selectedPreferences = testDefaults
        } else {
            selectedPreferences = .standard
        }
        self.reportPrefsStore = ReportPrefsStore(defaults: selectedPreferences)
        let generalSettings = GeneralSettings(defaults: selectedPreferences)
        self.generalSettings = generalSettings
        self.transferNotifier = TransferNotifier(settings: generalSettings)
        self.cameraLabels = CameraLabelModel(defaults: selectedPreferences)
        let selectedJournal = transferJournal ?? LocalTransferJournal(fileURL: testJournalURL)
        self.transferJournal = selectedJournal
        let existingIDs = Set(selectedJournal.records.map(\.id))
        let persistedSession = selectedJournal.loadQueueSession()
        // Computed in locals first: self cannot be read before every stored
        // property is set.
        let recoveredOrder: [UUID]
        var skippedIDs: Set<UUID> = []
        var pausedID: UUID?
        var sessionEnded = false
        if let persistedSession {
            recoveredOrder = persistedSession.recordIDs.filter(existingIDs.contains)
            skippedIDs = persistedSession.skippedRecordIDs.intersection(existingIDs)
            pausedID = persistedSession.pausedRecordID.flatMap { existingIDs.contains($0) ? $0 : nil }
            sessionEnded = persistedSession.ended
        } else {
            // Queue membership is session state, not transfer-history state.
            // Without a session file, old queued/interrupted records remain
            // visible in History but cannot silently become today's queue.
            recoveredOrder = []
        }
        let recoveredSessionIDs = Set(recoveredOrder)
        if persistedSession == nil {
            pausedID = selectedJournal.records.first {
                recoveredSessionIDs.contains($0.id) && Self.isQueueProblem($0)
            }?.id
        } else {
            let skipped = skippedIDs
            let savedPauseIsStillValid = pausedID.flatMap { paused in
                selectedJournal.records.first {
                    $0.id == paused && Self.isQueueProblem($0) && !skipped.contains($0.id)
                }
            } != nil
            if !savedPauseIsStillValid && !sessionEnded {
                pausedID = selectedJournal.records.first {
                    recoveredSessionIDs.contains($0.id) && Self.isQueueProblem($0)
                        && !skipped.contains($0.id)
                }?.id
            }
        }
        self.skippedQueueAttentionIDs = skippedIDs
        self.queuePausedRecordID = pausedID
        self.queueSessionEnded = sessionEnded
        self.queueFinishNotificationWasPosted = sessionEnded
        self.queueSessionRecordOrder = recoveredOrder
        self.queueSessionRecordIDs = recoveredSessionIDs
        self.queueSessionSourceVolumeIDs = Set(selectedJournal.records.filter {
            recoveredSessionIDs.contains($0.id)
        }.compactMap { $0.source.volumeID })
        // The Mac passes its Core Data-backed, SFTP-capable view model so the
        // whole app has one; iPad and iPhone build a portable one here.
        if let photographerJobViewModel {
            self.photographerJobViewModel = photographerJobViewModel
        } else {
            let selectedProjectStore = projectStore ?? UserDefaultsPhotographerJobStore()
            self.photographerJobViewModel = PhotographerJobViewModel(
                store: selectedProjectStore,
                remoteBackupCoordinator: UnavailableRemoteProjectCoordinator(store: selectedProjectStore),
                workflowDefaults: selectedPreferences
            )
        }
        self.reportSettings = reportPrefsStore.load()
        setupBindings()
        self.transferJournal.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // operationState lives in stateService; views observing this
        // coordinator must still refresh when it changes.
        stateService.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        cameraLabels.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        generalSettings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Views read the job view model through this coordinator too.
        self.photographerJobViewModel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        setupProgressPresentation()
        stateService.automaticPauseHandler = { [weak self] reason in
            Task { await self?.pauseOperation(reason: reason) }
        }
        // Default first launch to checksum verification; honor last-picked thereafter.
        if let saved = UserDefaults.standard.string(forKey: "lastVerificationMode"),
           let mode = VerificationMode.allCases.first(where: { $0.rawValue == saved }) {
            verificationMode = mode
        } else {
            verificationMode = .standard
        }
    }
    
    private static let testPreferencesSuite = "BitMatchTests.SharedAppCoordinator"

    #if os(iOS)
    convenience init() {
        self.init(platformManager: IOSPlatformManager.shared)
    }
    #endif
    
    #if os(macOS)
    convenience init() {
        self.init(platformManager: MacOSPlatformManager.shared)
    }
    #endif
    
    private func setupBindings() {
        // A prepared project card is tied to its source. `dropFirst()` skips
        // the replay Combine delivers on subscribing: without it every launch
        // reports "source changed to nil" and invalidates a card prepared
        // from the persisted store before anyone touched anything. Called
        // synchronously so a changed source is refused at once.
        $sourceURL
            .dropFirst()
            .sink { [weak self] url in
                guard let self else { return }
                self.photographerJobViewModel.sourceDidChange(to: url)
                // Suggest (or clear) the label for the new card. A queued
                // transfer's replay brings its own label.
                guard !self.isReplayingQueuedTransfer else { return }
                if let url {
                    self.cameraLabels.detectCameraWithMemory(at: url)
                } else {
                    self.cameraLabels.clearCameraLabel()
                }
            }
            .store(in: &cancellables)

        // Folder info for the source, and the detected camera card iPad shows.
        // Detection no longer delays the scan.
        $sourceURL
            .sink { [weak self] url in
                Task { @MainActor [weak self] in
                    await self?.folderInfoService.updateSource(url)
                }
                Task { @MainActor [weak self] in
                    await self?.detectCameraFromSource(url)
                }
            }
            .store(in: &cancellables)

        // Monitor left folder URL changes
        $leftURL
            .sink { [weak self] url in
                Task { @MainActor [weak self] in
                    await self?.folderInfoService.updateLeft(url)
                }
            }
            .store(in: &cancellables)

        // Monitor right folder URL changes
        $rightURL
            .sink { [weak self] url in
                Task { @MainActor [weak self] in
                    await self?.folderInfoService.updateRight(url)
                }
            }
            .store(in: &cancellables)

        // Monitor destination URLs changes
        $destinationURLs
            .sink { [weak self] urls in
                Task { @MainActor [weak self] in
                    await self?.folderInfoService.updateDestinations(urls)
                }
            }
            .store(in: &cancellables)

        // Forward folder info service changes to trigger UI updates
        folderInfoService.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Persist verification mode across launches
        $verificationMode
            .sink { [weak self] mode in
                guard self?.isReplayingQueuedTransfer != true else { return }
                UserDefaults.standard.set(mode.rawValue, forKey: "lastVerificationMode")
            }
            .store(in: &cancellables)
    }

    // MARK: - Finish notification

    private func notifyIfTransferEnded(_ state: OperationState) {
        guard currentMode == .copyAndVerify else { return }
        let issueCount = results.filter { !$0.isSuccessStatus }.count
        guard let kind = TransferNotificationDecision.kind(
            state: state,
            issueCount: issueCount,
            queueIsRunning: queueIsRunning,
            isReplayingQueuedTransfer: isReplayingQueuedTransfer,
            notifyAttention: generalSettings.notifyWhenCardNeedsAttention,
            notifyFinish: generalSettings.notifyWhenTransferOrQueueFinishes,
            notifyEachQueuedCard: generalSettings.notifyForEachCardInQueue
        ) else { return }
        let finishedRecord = outcomeRecord
        guard let finishedRecord,
              let notice = TransferFinishNotice.make(
            state: state,
            record: finishedRecord,
            issueCount: issueCount,
            kind: kind
        ) else { return }
        transferNotifier.post(notice)
    }

    func enableNotificationsFromPrompt() async {
        generalSettings.markNotificationPromptAnswered()
        showsNotificationPermissionPrompt = false
        _ = await transferNotifier.enable()
    }

    func declineNotificationsFromPrompt() {
        generalSettings.markNotificationPromptAnswered()
        showsNotificationPermissionPrompt = false
    }

    private func showNotificationPermissionPromptIfNeeded() {
        guard !showsNotificationPermissionPrompt else { return }
        showsNotificationPermissionPrompt = NotificationPermissionPromptPolicy.shouldShow(
            transferWillStart: true,
            promptWasAnswered: generalSettings.notificationPromptWasAnswered,
            notifyAttention: generalSettings.notifyWhenCardNeedsAttention,
            notifyFinish: generalSettings.notifyWhenTransferOrQueueFinishes,
            notifyEachQueuedCard: generalSettings.notifyForEachCardInQueue
        )
    }

    // MARK: - Progress presentation

    /// Feeds `progressPresentation`: engine progress at most every 120 ms,
    /// and the smoothing timer while an operation runs.
    private func setupProgressPresentation() {
        operationStatePublisher
            .removeDuplicates()
            .sink { [weak self] state in self?.notifyIfTransferEnded(state) }
            .store(in: &cancellables)
        IOSBackgroundTaskService.shared.secondsRemainingProvider = { [weak self] in
            self?.progressPresentation.measuredSecondsRemaining
        }
        liveProgress.$progress.compactMap { $0 }
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] prog in self?.presentProgress(prog) }
            .store(in: &cancellables)

        operationStatePublisher
            .sink { [weak self] state in
                guard let self else { return }
                let presentation = self.progressPresentation
                switch state {
                case .inProgress, .copying, .verifying, .resuming:
                    // One run is tracked once. Resume (`.resuming` then
                    // `.inProgress`) and stage changes keep the byte totals
                    // and speed samples; a new run stops tracking first
                    // (`executeOperation`), so it starts from zero.
                    if presentation.isTracking {
                        presentation.noteResumed()
                    } else if state != .resuming {
                        presentation.startProgressTracking()
                    }
                    if presentation.progressMessage == "Ready" {
                        presentation.setProgressMessage("Preparing")
                    }
                case .paused:
                    // Paused time is left out of speed and time remaining.
                    presentation.notePaused()
                case .completed, .failed, .cancelled:
                    presentation.stopProgressTracking()
                    self.lastPresentedBytes = 0
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func presentProgress(_ prog: OperationProgress) {
        let presentation = progressPresentation
        presentation.setFileCountTotal(prog.totalFiles)
        let destinationCount = presentedDestinationCount ?? destinationURLs.count
        // Time left is measured against the copy work actually planned: the
        // scanned source once per backup. The engine's `totalBytes` covers
        // one backup, and is a 1 GB guess when the source was not scanned.
        presentation.setPlannedTotalBytes(sourceFolderInfo.map { $0.totalSize * Int64(destinationCount) })
        presentation.fileCountCompleted = prog.filesProcessed
        if let totals = prog.perDestinationTotals, let completed = prog.perDestinationCompleted,
           totals.count == destinationCount, completed.count == destinationCount {
            presentation.setPerDestinationProgress(totals: totals, completed: completed)
        }
        if let name = prog.currentFile, !name.isEmpty { presentation.setCurrentFile(name) }
        if let reused = prog.reusedCopies { presentation.setReusedFileCopies(reused) }
        if let bytes = prog.bytesProcessed {
            let delta = bytes - lastPresentedBytes
            if delta > 0 { presentation.updateBytesProcessed(delta) }
            lastPresentedBytes = bytes
        }
        var message = prog.currentStage.displayName
        if let name = prog.currentFile, !name.isEmpty { message += " — \(name)" }
        presentation.setProgressMessage(message)
    }

    // MARK: - UI Helpers
    
    func showAlert(title: String, message: String) async {
        await platformManager.presentAlert(title: title, message: message)
    }
    
    func showError(_ error: Error) async {
        await platformManager.presentError(error)
    }
    
    // MARK: - File Selection Methods
    
    func selectSourceFolder() async {
        // A cancelled picker returns nil: preserve the existing selection.
        if let url = await platformManager.fileSystem.selectSourceFolder() {
            sourceURL = url
        }
    }
    
    /// The platform's source picker, choosing nothing yet: the Setup boxes
    /// (`SetupLocationSelection`) check the pick first. Nil when cancelled.
    func pickFolderForSource() async -> URL? {
        await platformManager.fileSystem.selectSourceFolder()
    }

    /// The platform's backup picker, adding nothing yet: the Setup boxes
    /// run `DestinationSelectionPolicy`, then `addDestination`.
    func pickFoldersForBackups() async -> [URL] {
        await platformManager.fileSystem.selectDestinationFolders()
    }

    /// Adds a backup unless `BackupTargetPolicy` refuses it for `origin` or
    /// the same folder (by resolved path) is already chosen. Used by every
    /// platform's picker, Mac drag-and-drop, discovery and restore. Returns
    /// the refusal, which only a `.userChoice` caller shows; the automatic
    /// origins log it and move on.
    @discardableResult
    func addDestination(
        _ url: URL,
        origin: BackupTargetPolicy.Origin = .userChoice,
        facts: (URL) -> BackupTargetPolicy.VolumeFacts? = BackupTargetPolicy.VolumeFacts.read
    ) -> String? {
        guard !isDestinationSelectionLocked else {
            return Self.destinationSelectionLockedMessage
        }
        if let refusal = BackupTargetPolicy.refusal(for: url, origin: origin, source: sourceURL, facts: facts) {
            SharedLogger.info("Backup refused (\(origin)): \(url.path): \(refusal)", category: .transfer)
            return refusal
        }
        let path = Self.resolvedPath(url)
        guard !destinationURLs.contains(where: { Self.resolvedPath($0) == path }) else { return nil }
        destinationURLs.append(url)
        return nil
    }

    /// Replaces every backup at once (the debug tools), keeping only what
    /// `BackupTargetPolicy` allows for a user's own pick.
    func replaceDestinations(with urls: [URL]) {
        guard !isDestinationSelectionLocked else {
            SharedLogger.info(Self.destinationSelectionLockedMessage, category: .transfer)
            return
        }
        destinationURLs = urls.filter { url in
            guard let refusal = BackupTargetPolicy.refusal(for: url, origin: .userChoice, source: sourceURL) else {
                return true
            }
            SharedLogger.info("Backup refused: \(url.path): \(refusal)", category: .transfer)
            return false
        }
    }

    func removeDestinationFolder(_ url: URL) {
        guard !isDestinationSelectionLocked else {
            SharedLogger.info(Self.destinationSelectionLockedMessage, category: .transfer)
            return
        }
        destinationURLs.removeAll { $0 == url }
    }

    private static let destinationSelectionLockedMessage =
        "Destinations are locked while staged or running queue cards use them. Remove those cards or let the batch finish first."

    /// The route is immutable for the lifetime of a staged batch, including
    /// the interval when its final card is running and there are no queued
    /// records left. The current Finish screen also freezes its run context;
    /// older completed History records do not keep Setup locked.
    var isDestinationSelectionLocked: Bool {
        isOperationInProgress || showsOutcomeSummary || transferJournal.records.contains { record in
            queueSessionRecordIDs.contains(record.id)
                && record.projectID == nil
                && (record.state == .queued || record.state == .running)
        }
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksKeepingCase().path
    }

    /// True while the chosen source has not finished its folder scan. Start
    /// waits for it on every platform (the Mac's stricter rule, decided).
    var isAnalysingSource: Bool {
        guard let sourceURL else { return false }
        return folderInfoService.isAwaitingSourceInfo(for: sourceURL)
    }

    var isSelectedSourceKnownEmpty: Bool {
        guard let sourceURL, !isAnalysingSource, let info = sourceFolderInfo else { return false }
        return info.url.standardizedFileURL == sourceURL.standardizedFileURL && info.fileCount == 0
    }

    /// True while the left compare folder has not finished its scan.
    var isAnalysingLeft: Bool {
        guard let leftURL else { return false }
        return folderInfoService.isAwaitingLeftInfo(for: leftURL)
    }

    /// True while the right compare folder has not finished its scan.
    var isAnalysingRight: Bool {
        guard let rightURL else { return false }
        return folderInfoService.isAwaitingRightInfo(for: rightURL)
    }
    
    func selectLeftFolder() async {
        // A cancelled picker returns nil: preserve the existing selection.
        if let url = await platformManager.fileSystem.selectLeftFolder() {
            leftURL = url
        }
    }

    func selectRightFolder() async {
        // A cancelled picker returns nil: preserve the existing selection.
        if let url = await platformManager.fileSystem.selectRightFolder() {
            rightURL = url
        }
    }
    
    /// Completed, failed, and cancelled operations keep their (possibly
    /// partial) results visible instead of dropping back to setup.
    /// A compare shows its outcome inside the Compare screen; it is never
    /// the transfer outcome summary.
    var showsOutcomeSummary: Bool {
        guard !lastOperationWasCompare else { return false }
        switch operationState {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    // MARK: - Operation Control

    var queuedCardCount: Int {
        transferJournal.records.filter {
            queueSessionRecordIDs.contains($0.id) && $0.state == .queued && $0.projectID == nil
        }.count
    }

    /// One-time cards staged from Setup, in the order they will run. Setup
    /// presents these as sources rather than duplicating them in Queue.
    var stagedSetupTransfers: [LocalTransferRecord] {
        let recordsByID = Dictionary(uniqueKeysWithValues: transferJournal.records.map { ($0.id, $0) })
        return queueSessionRecordOrder.compactMap { recordsByID[$0] }.filter {
            $0.state == .queued && $0.projectID == nil
        }
    }

    var canEnqueueSelection: Bool {
        operationReadinessAssessment.isReady && !isOperationInProgress
            && !usesProjectWorkflow && !photographerJobViewModel.hasPreparedIngestAwaitingStart
    }

    /// One validation and bookmark path for setup, the sheet and connected cards.
    @discardableResult
    func enqueue(
        source: URL, destinations: [URL],
        verificationMode: VerificationMode? = nil,
        cameraSettings: CameraLabelSettings? = nil,
        generateASCMHL: Bool? = nil,
        reportSettings: ReportPrefs? = nil
    ) throws -> UUID {
        let scopedURLs = ([source] + destinations).filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        let settings = cameraSettings ?? self.cameraLabelSettings
        if let refusal = destinations.lazy.compactMap({
            BackupTargetPolicy.refusal(for: $0, origin: .userChoice, source: source)
        }).first {
            throw FileOperationError.unsafeOperation(refusal)
        }
        try SafetyValidator.validateResolvedDestinationRoots(source: source, destinations: destinations, settings: settings)
        guard try CardSource.containsRegularFile(base: source) else {
            throw FileOperationError.unsafeOperation("Source folder is empty. Choose a source that contains files.")
        }
        if queueSessionEnded && !hasWaitingQueueSessionRecord {
            clearQueueSessionState()
        }
        let id = try transferJournal.enqueue(
            sourceURL: source, destinationURLs: destinations,
            verificationMode: verificationMode ?? self.verificationMode,
            cameraSettings: settings, reportSettings: reportSettings ?? self.reportSettings,
            generateASCMHL: generateASCMHL ?? self.generateASCMHL
        )
        addQueueSessionRecord(id)
        if let volumeID = transferJournal.records.first(where: { $0.id == id })?.source.volumeID {
            queueSessionSourceVolumeIDs.insert(volumeID)
        }
        persistQueueSession()
        return id
    }

    func enqueueSelection() throws {
        guard canEnqueueSelection, let sourceURL else {
            throw FileOperationError.unsafeOperation("Choose a source and destinations for a one-time transfer first.")
        }
        try enqueue(source: sourceURL, destinations: destinationURLs)
        self.sourceURL = nil
    }

    /// Starts the cards assembled on Setup. If more than one card is ready,
    /// the current selection first enters the same validated journal path as
    /// every other queued card, then the existing serial queue runs them.
    func startSetupTransfers() throws {
        guard !usesProjectWorkflow, !photographerJobViewModel.hasPreparedIngestAwaitingStart else {
            throw FileOperationError.unsafeOperation("Finish setting up the project card before starting.")
        }
        if sourceURL != nil {
            try enqueueSelection()
        }
        guard !stagedSetupTransfers.isEmpty else {
            throw FileOperationError.unsafeOperation("Choose a source and destinations first.")
        }
        startQueue()
    }

    var runningOneTimeTransfer: LocalTransferRecord? {
        guard isOperationInProgress, let record = outcomeRecord,
              record.state == .running, record.projectID == nil,
              !usesProjectWorkflow else { return nil }
        return record
    }

    func queueCandidates(volumes: [ConnectedDrivesPresentation.Volume]) -> [ConnectedDrivesPresentation.Row] {
        guard let record = queueTemplateRecord else { return [] }
        return ConnectedDrivesPresentation.queueCandidates(
            volumes: volumes,
            sourceURL: record.source.url.standardizedFileURL.resolvingSymlinksKeepingCase(),
            destinationURLs: record.destinations.map { $0.url.standardizedFileURL.resolvingSymlinksKeepingCase() },
            queuedSourceURLs: transferJournal.records.filter {
                $0.state == .queued || queueSessionRecordIDs.contains($0.id)
            }
                .map { $0.source.url.standardizedFileURL.resolvingSymlinksKeepingCase() }
        )
    }

    func autoQueueCandidates(volumes: [ConnectedDrivesPresentation.Volume]) -> [ConnectedDrivesPresentation.Row] {
        guard let record = queueTemplateRecord else { return [] }
        var seen = autoQueueSeenVolumeIDs
        if let volumeID = record.source.volumeID { seen.insert(volumeID) }
        return AutoQueuePolicy.candidates(
            eligibleRows: queueCandidates(volumes: volumes),
            seenVolumeIDs: seen,
            activeDestinationVolumeIDs: Set(record.destinations.compactMap { $0.volumeID })
        )
    }

    var autoQueueSeenVolumeIDs: Set<String> { queueSessionSourceVolumeIDs }

    private var queueTemplateRecord: LocalTransferRecord? {
        if let runningOneTimeTransfer { return runningOneTimeTransfer }
        guard queueIsRunning else { return nil }
        return transferJournal.records.first {
            queueSessionRecordIDs.contains($0.id) && $0.projectID == nil
        }
    }

    func enqueueNext(source: URL) throws {
        guard let record = queueTemplateRecord else {
            throw FileOperationError.unsafeOperation("A one-time transfer or queue must be running to queue the next card.")
        }
        // The next card gets the running transfer's own settings, not
        // whatever the setup screen or Preferences hold now.
        addQueueSessionRecord(record.id)
        if let volumeID = record.source.volumeID { queueSessionSourceVolumeIDs.insert(volumeID) }
        try enqueue(
            source: source, destinations: record.destinations.map(\.url),
            verificationMode: record.verificationMode,
            cameraSettings: record.cameraSettings,
            generateASCMHL: record.generateASCMHL,
            reportSettings: record.reportSettings
        )
        persistQueueSession()
        // startQueue waits for executeOperation to unwind before advancing.
        startQueue()
    }

    /// Adds the inline Queue editor's draft through the same validated path
    /// as every other queued transfer. When a one-time transfer is already
    /// running, it becomes the first item in the queue session and the new
    /// card follows it automatically.
    func enqueueInlineCard(
        source: URL,
        destinations: [URL],
        verificationMode: VerificationMode,
        generateASCMHL: Bool
    ) throws {
        if let running = runningOneTimeTransfer {
            addQueueSessionRecord(running.id)
            if let volumeID = running.source.volumeID { queueSessionSourceVolumeIDs.insert(volumeID) }
        }
        try enqueue(
            source: source,
            destinations: destinations,
            verificationMode: verificationMode,
            generateASCMHL: generateASCMHL
        )
        if isOperationInProgress { startQueue() }
    }

    func enqueueAutomaticallyDetectedCard(source: URL) throws {
        guard let record = queueTemplateRecord else {
            throw FileOperationError.unsafeOperation("A one-time queue must be running to add the card.")
        }
        addQueueSessionRecord(record.id)
        if let volumeID = record.source.volumeID { queueSessionSourceVolumeIDs.insert(volumeID) }
        try enqueue(
            source: source, destinations: record.destinations.map(\.url),
            verificationMode: record.verificationMode,
            cameraSettings: record.cameraSettings,
            generateASCMHL: record.generateASCMHL,
            reportSettings: record.reportSettings
        )
        persistQueueSession()
        startQueue()
    }

    func startQueue() {
        guard !(isOperationInProgress && currentMode == .compareFolders) else {
            queueIsRunning = false
            queueMessage = "Finish or cancel the folder comparison, then choose Run queue."
            return
        }
        guard !hasUnresolvedQueueRecords else {
            queueIsRunning = false
            return
        }
        if queueSessionEnded && !hasWaitingQueueSessionRecord {
            clearQueueSessionState()
        }
        let allWaiting = transferJournal.records.filter { $0.state == .queued && $0.projectID == nil }
        // Legacy/test callers can explicitly run a journal assembled before
        // the coordinator exists. Once a session has membership, never pull
        // unrelated old History records into it.
        if queueSessionRecordIDs.isEmpty {
            for id in allWaiting.reversed().map(\.id) { addQueueSessionRecord(id) }
        }
        let waiting = allWaiting.filter { queueSessionRecordIDs.contains($0.id) }
        guard !waiting.isEmpty else { return }
        queueFinishNotificationWasPosted = false
        queueSessionEnded = false
        queueStopWasRequested = false
        queueMessage = nil
        queueIsRunning = true
        persistQueueSession()
        Task { await processNextQueuedTransfer() }
    }

    func stopQueueAfterCurrentTransfer() {
        queueStopWasRequested = true
        queueIsRunning = false
    }

    func skipPausedCardAndContinue(_ expectedID: UUID) {
        guard queuePausedRecordID == expectedID,
              let record = transferJournal.records.first(where: { $0.id == expectedID }),
              Self.isQueueProblem(record) else { return }
        skippedQueueAttentionIDs.insert(expectedID)
        queuePausedRecordID = nil
        queueMessage = nil
        if transferJournal.records.contains(where: {
            queueSessionRecordIDs.contains($0.id) && $0.state == .queued && $0.projectID == nil
        }) {
            persistQueueSession()
            startQueue()
        } else {
            endQueueSession()
        }
    }

    func removeQueuedTransfer(_ id: UUID) throws {
        try transferJournal.removeQueued(id: id)
        queueSessionRecordIDs.remove(id)
        queueSessionRecordOrder.removeAll { $0 == id }
        persistQueueSession()
    }

    /// Removes a stale failed/interrupted card from this queue without
    /// deleting its History record. Unlike Skip and Continue, this does not
    /// start waiting cards automatically.
    func removePausedCardFromQueue(_ expectedID: UUID) throws {
        guard queuePausedRecordID == expectedID,
              let record = transferJournal.records.first(where: { $0.id == expectedID }),
              Self.isQueueProblem(record) else {
            throw FileOperationError.unsafeOperation("Only the card pausing this queue can be removed.")
        }
        queueSessionRecordIDs.remove(expectedID)
        queueSessionRecordOrder.removeAll { $0 == expectedID }
        skippedQueueAttentionIDs.remove(expectedID)
        reviewedQueueAttentionIDs.remove(expectedID)
        queuePausedRecordID = nil
        reviewedQueueRecordID = nil
        queueMessage = nil
        queueIsRunning = false
        queueSessionEnded = false
        if activeJournalRecordID == expectedID {
            resetForNewOperation()
            sourceURL = nil
        }
        if queueSessionRecordIDs.isEmpty {
            clearQueueSessionState()
        } else {
            persistQueueSession()
        }
    }

    func moveQueuedTransferToTop(_ id: UUID) throws {
        if queueSessionRecordOrder.contains(id) {
            try moveQueuedTransfer(id: id, to: 0)
        } else {
            // Legacy queued History rows may predate durable session
            // membership. Preserve their existing journal-only action.
            try transferJournal.moveQueuedToTop(id: id)
        }
    }

    /// Moves one waiting card to a final index among the waiting rows. Active
    /// and finished records never enter `waitingIDs`, so they cannot move.
    func moveQueuedTransfer(id: UUID, to destinationIndex: Int) throws {
        let recordsByID = Dictionary(uniqueKeysWithValues: transferJournal.records.map { ($0.id, $0) })
        var waitingIDs = queueSessionRecordOrder.filter { recordsByID[$0]?.state == .queued }
        guard let sourceIndex = waitingIDs.firstIndex(of: id),
              waitingIDs.indices.contains(destinationIndex) else {
            throw FileOperationError.unsafeOperation("Only waiting cards can be reordered.")
        }
        guard sourceIndex != destinationIndex else { return }
        waitingIDs.remove(at: sourceIndex)
        waitingIDs.insert(id, at: destinationIndex)
        try transferJournal.reorderQueued(idsInRunOrder: waitingIDs)
        var reorderedWaitingIDs = waitingIDs.makeIterator()
        queueSessionRecordOrder = queueSessionRecordOrder.map { recordID in
            recordsByID[recordID]?.state == .queued
                ? (reorderedWaitingIDs.next() ?? recordID) : recordID
        }
        persistQueueSession()
    }

    func reviewQueuedTransfer(_ id: UUID) {
        guard let record = transferJournal.records.first(where: { $0.id == id }) else { return }
        let safety = TransferLibraryPresentation.safetyState(for: record)
        let state: OperationState
        switch safety {
        case .safeToErase: state = .completed(.init(success: true, message: record.summary))
        case .copiedNotVerified: state = .completed(.init(success: false, message: record.summary, copiedNotVerified: true))
        case .needsAttention: state = .completed(.init(success: false, message: record.summary))
        case .failed: state = .failed
        case .interrupted: state = .cancelled
        default: return
        }
        reviewedQueueAttentionIDs.insert(id)
        standaloneAttentionRecordIDsSinceLaunch.remove(id)
        reviewedQueueRecordID = id
        activeJournalRecordID = id
        if reviewedSelectionSnapshot == nil {
            reviewedSelectionSnapshot = ReviewedSelectionSnapshot(
                destinations: destinationURLs,
                verificationMode: verificationMode
            )
        }
        isReplayingQueuedTransfer = true
        defer { isReplayingQueuedTransfer = false }
        sourceURL = record.source.url
        destinationURLs = record.destinations.map(\.url)
        verificationMode = record.verificationMode
        results = record.results
        operationState = state
    }

    var queuePresentation: QueueSessionPresentation {
        let records = transferJournal.records.filter { queueSessionRecordIDs.contains($0.id) }
        let mounted = Set(records.compactMap { record -> UUID? in
            guard let access = try? transferJournal.prepareSourceForEjection(id: record.id) else { return nil }
            access.release()
            return record.id
        })
        return QueueSessionPresentation.make(
            records: transferJournal.records,
            sessionIDs: queueSessionRecordIDs,
            sessionRecordIDsInOrder: queueSessionRecordOrder,
            progress: progress,
            mountedSourceIDs: mounted,
            ejectedSourceIDs: ejectedQueueSourceIDs,
            pausedRecordID: queuePausedRecordID
        )
    }

    var hasUnresolvedQueueRecords: Bool {
        guard let pausedID = queuePausedRecordID,
              !skippedQueueAttentionIDs.contains(pausedID) else { return false }
        return transferJournal.records.contains {
            $0.id == pausedID && Self.isQueueProblem($0)
        }
    }

    private var hasWaitingQueueSessionRecord: Bool {
        transferJournal.records.contains {
            queueSessionRecordIDs.contains($0.id) && $0.state == .queued && $0.projectID == nil
        }
    }

    var queueRunCommandEnabled: Bool {
        QueueCommandPolicy.canRunQueue(
            isPausedOnProblem: hasUnresolvedQueueRecords,
            waitingCount: queuePresentation.rows.filter { $0.safetyState == .waiting }.count
        )
    }

    var currentTransferBelongsToQueueSession: Bool {
        activeJournalRecordID.map(queueSessionRecordIDs.contains) == true
            && queueSessionRecordIDs.count >= 2
    }

    func retryTransfer(_ id: UUID, generateASCMHL: Bool? = nil) {
        do {
            standaloneAttentionRecordIDsSinceLaunch.remove(id)
            let retryID = try transferJournal.requeue(id: id, generateASCMHL: generateASCMHL)
            queueSessionRecordIDs.remove(id)
            queueSessionRecordIDs.insert(retryID)
            if let index = queueSessionRecordOrder.firstIndex(of: id) {
                queueSessionRecordOrder[index] = retryID
            } else {
                queueSessionRecordOrder.append(retryID)
            }
            skippedQueueAttentionIDs.remove(id)
            if queuePausedRecordID == id { queuePausedRecordID = nil }
            reviewedQueueRecordID = nil
            queueMessage = nil
            persistQueueSession()
            startQueue()
        } catch { queueMessage = error.localizedDescription }
    }

    /// Indexes into `[source] + destinations` whose access expired. Empty means
    /// every location still resolves; unknown records report no stale locations.
    func reauthorizationStatus(id: UUID) -> [Int] {
        (try? transferJournal.staleResourceIndexes(id: id)) ?? []
    }

    /// Reconnects one expired location to the identical original folder.
    /// Throws when the pick is anything else, so another drive is never
    /// silently substituted. Earlier attempts and their evidence are kept.
    func reauthorizeTransfer(_ id: UUID, resourceIndex: Int, url: URL) throws {
        try transferJournal.reauthorize(id: id, resourceIndex: resourceIndex, newURL: url)
    }

    private func processNextQueuedTransfer() async {
        guard queueIsRunning, !isProcessingQueue, !isOperationInProgress, activeStartID == nil else { return }
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else {
            queueIsRunning = false
            queueMessage = "Queue paused. Open BitMatch and choose Run queue to continue."
            return
        }
        #endif
        let recordsByID = Dictionary(uniqueKeysWithValues: transferJournal.records.map { ($0.id, $0) })
        guard let record = queueSessionRecordOrder.lazy.compactMap({ recordsByID[$0] }).first(where: {
            $0.state == .queued && $0.projectID == nil
        }) else {
            endQueueSession()
            return
        }
        guard !photographerJobViewModel.hasPreparedIngestAwaitingStart else {
            queueIsRunning = false
            queueMessage = "Finish or clear the prepared project card before running the queue."
            return
        }
        isProcessingQueue = true
        defer {
            isProcessingQueue = false
            isReplayingQueuedTransfer = false
            if queueIsRunning { Task { await self.processNextQueuedTransfer() } }
        }
        // The record's settings apply to this run only; the user's return
        // when it ends (UI plan §8 item 8).
        let userReportSettings = reportSettings
        let userCameraSettings = cameraLabelSettings
        let userVerificationMode = verificationMode
        let userGenerateASCMHL = generateASCMHL
        do {
            if (try? transferJournal.staleResourceIndexes(id: record.id).contains(0)) == true {
                let message = "\(record.title) is not connected"
                try transferJournal.fail(id: record.id, summary: message)
                handleAttemptTerminal(recordID: record.id)
                return
            }
            let access = try transferJournal.prepareToRun(id: record.id)
            defer { access.release() }
            isReplayingQueuedTransfer = true
            cameraLabels.suspendsSaving = true
            defer {
                reportSettings = userReportSettings
                cameraLabelSettings = userCameraSettings
                verificationMode = userVerificationMode
                generateASCMHL = userGenerateASCMHL
                cameraLabels.suspendsSaving = false
            }
            // Queued backups were the user's picks; the rule still applies,
            // since a record can predate it.
            if let refusal = access.destinationURLs.lazy.compactMap({
                BackupTargetPolicy.refusal(for: $0, origin: .userChoice, source: access.sourceURL)
            }).first {
                throw FileOperationError.unsafeOperation(refusal)
            }
            sourceURL = access.sourceURL
            destinationURLs = access.destinationURLs
            verificationMode = record.verificationMode
            cameraLabelSettings = record.cameraSettings
            reportSettings = record.reportSettings
            generateASCMHL = record.generateASCMHL
            currentMode = .copyAndVerify
            photographerReportFinalizer = nil
            activeProjectCardID = nil
            projectRunCameraSettings = nil
            await executeOperation(journalRecordID: record.id)
        } catch {
            queueIsRunning = false
            queueMessage = error.localizedDescription
            do {
                try transferJournal.fail(id: record.id, summary: error.localizedDescription)
                handleAttemptTerminal(recordID: record.id)
            } catch {
                pauseQueueAttempt(
                    recordID: record.id,
                    message: "Queue stopped: \(error.localizedDescription)"
                )
            }
        }
    }


    private static func isQueueProblem(_ record: LocalTransferRecord) -> Bool {
        let safety = TransferLibraryPresentation.safetyState(for: record)
        return safety == .needsAttention || safety == .failed || safety == .interrupted
    }

    func startOperation() async { await executeOperation(journalRecordID: nil) }

    /// One live row from the engine while a transfer runs: replaces the row
    /// for the same file and backup, or appends it. Only `liveResults`
    /// announces the change, so the shells observing this coordinator are
    /// not redrawn per file. The engine's authoritative list replaces these
    /// rows through `results` before the verdict is set.
    func receiveLiveResult(_ row: ResultRow) {
        liveResults.upsert(row)
    }

    private func executeOperation(journalRecordID: UUID?) async {
        // The run-only override applies to this attempt and never lingers.
        let runCameraSettings = projectRunCameraSettings ?? cameraLabelSettings
        projectRunCameraSettings = nil
        guard activeStartID == nil, !isOperationInProgress else { return }
        lastOperationWasCompare = false
        guard let sourceURL = sourceURL, !destinationURLs.isEmpty else {
            operationState = .failed
            updateProjectLifecycle(for: .failed)
            await platformManager.presentAlert(
                title: "Invalid Selection",
                message: "Please select a source folder and at least one destination folder."
            )
            return
        }
        guard !isSelectedSourceKnownEmpty else {
            operationState = .failed
            updateProjectLifecycle(for: .failed)
            await platformManager.presentAlert(
                title: "Empty Source",
                message: "Choose a source that contains files."
            )
            return
        }

        let startID = UUID()
        activeStartID = startID
        startCancellationRequested = false
        isOperationInProgress = true
        activeJournalRecordID = nil
        defer {
            if activeStartID == startID {
                activeStartID = nil
                startCancellationRequested = false
                isOperationInProgress = false
                if queueIsRunning && !isProcessingQueue {
                    Task { await self.processNextQueuedTransfer() }
                } else if currentTransferBelongsToQueueSession && queueStopWasRequested {
                    endQueueSession()
                }
            }
        }

        // iOS: Acquire security-scoped access BEFORE any FileManager operations
        // This is required for document picker URLs to work with FileManager on iOS
        // On macOS, these methods return true/no-op, so this is safe cross-platform
        let didStartSourceScope = platformManager.fileSystem.startAccessing(url: sourceURL)
        var destinationScopes: [URL: Bool] = [:]
        for destinationURL in destinationURLs {
            destinationScopes[destinationURL] = platformManager.fileSystem.startAccessing(url: destinationURL)
        }
        defer {
            if didStartSourceScope { platformManager.fileSystem.stopAccessing(url: sourceURL) }
            for (url, didStart) in destinationScopes where didStart {
                platformManager.fileSystem.stopAccessing(url: url)
            }
        }

        // Commit the immutable selection before copying. Failed persistence must
        // never leave a transfer running without a recoverable record.
        let recordID: UUID
        do {
            recordID = try journalRecordID ?? transferJournal.enqueue(
                sourceURL: sourceURL, destinationURLs: destinationURLs,
                verificationMode: verificationMode, cameraSettings: runCameraSettings,
                reportSettings: reportSettings, generateASCMHL: generateASCMHL,
                projectID: photographerReportFinalizer == nil ? nil : photographerJobViewModel.activeJob?.id
            )
            try transferJournal.markRunning(id: recordID)
            activeJournalRecordID = recordID
        } catch {
            queueIsRunning = false
            let startError = error
            queueMessage = startError.localizedDescription
            if let journalRecordID, queueSessionRecordIDs.contains(journalRecordID) {
                do {
                    try transferJournal.fail(id: journalRecordID, summary: startError.localizedDescription)
                    handleAttemptTerminal(recordID: journalRecordID, belongsToQueueSession: true)
                } catch {
                    pauseQueueAttempt(
                        recordID: journalRecordID,
                        message: "Queue stopped: \(error.localizedDescription)"
                    )
                }
            }
            operationState = .failed
            updateProjectLifecycle(for: .failed)
            await platformManager.presentError(startError)
            return
        }

        // Validate resolved destination paths before starting. Source-tree and
        // capacity checks run in the file operation after its manifest is built.
        do {
            try SafetyValidator.validateResolvedDestinationRoots(
                source: sourceURL,
                destinations: destinationURLs,
                settings: runCameraSettings
            )
        } catch {
            try? transferJournal.interrupt(id: recordID, summary: error.localizedDescription)
            if isReplayingQueuedTransfer || queueSessionRecordIDs.contains(recordID) {
                pauseQueueAttempt(recordID: recordID, message: error.localizedDescription)
            } else {
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: false)
            }
            operationState = .failed
            updateProjectLifecycle(for: .failed)
            await platformManager.presentError(error)
            return
        }

        guard activeStartID == startID, !startCancellationRequested else {
            queueIsRunning = false
            do {
                try transferJournal.cancel(id: recordID, results: results)
                handleAttemptTerminal(
                    recordID: recordID,
                    belongsToQueueSession: isReplayingQueuedTransfer || queueSessionRecordIDs.contains(recordID)
                )
            } catch {
                let message = "Could not save transfer results: \(error.localizedDescription)"
                queueMessage = message
                operationState = .failed
            }
            return
        }

        // A new run starts its smoothed progress from zero, even if the last
        // run never reached a terminal state.
        showNotificationPermissionPromptIfNeeded()
        progressPresentation.stopProgressTracking()
        lastPresentedBytes = 0
        operationState = .inProgress
        results = []
        progress = nil
        presentedDestinationCount = destinationURLs.count

        let config = CopyVerifyConfig(
            operationId: startID,
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            verificationMode: verificationMode,
            cameraLabelSettings: runCameraSettings,
            reportSettings: reportSettings,
            estimatedFiles: sourceFolderInfo?.fileCount ?? 100,
            estimatedBytes: sourceFolderInfo?.totalSize ?? 1_000_000_000,
            currentMode: currentMode,
            photographerReportFinalizer: photographerReportFinalizer,
            generateASCMHL: generateASCMHL
        )

        let callbacks = CopyVerifyCallbacks(
            onProgress: { [weak self] progressUpdate in
                guard let self,
                      self.activeStartID == startID,
                      !self.startCancellationRequested else { return }
                self.progress = progressUpdate
                if self.activeProjectCardID != nil {
                    self.photographerJobViewModel.updateProgressStage(progressUpdate.currentStage)
                }
            },
            onResult: { [weak self] result in
                guard let self,
                      self.activeStartID == startID,
                      !self.startCancellationRequested else { return }
                self.receiveLiveResult(result)
            },
            onStateChange: { [weak self] state in
                guard let self,
                      self.activeStartID == startID,
                      !self.startCancellationRequested else { return }
                self.operationState = state
                self.updateProjectLifecycle(for: state)
            },
            onAuthoritativeResults: { [weak self] allResults in
                guard let self,
                      self.activeStartID == startID,
                      !self.startCancellationRequested else {
                    throw CancellationError()
                }
                self.results = allResults
            }
        )

        do {
            currentOperation = try await copyVerifyExecutor.execute(config: config, callbacks: callbacks)
            let belongsToQueueSession = isReplayingQueuedTransfer || queueSessionRecordIDs.contains(recordID)
            if startCancellationRequested {
                try transferJournal.cancel(id: recordID, results: results)
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: belongsToQueueSession)
            } else if case .completed(let info) = operationState {
                let durations = copyVerifyExecutor.completedPhaseDurations
                try transferJournal.finish(
                    id: recordID,
                    results: results,
                    summary: info.message,
                    hadIssues: !info.success,
                    copyDurationSeconds: durations.copySeconds,
                    verifyDurationSeconds: durations.verifySeconds
                )
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: belongsToQueueSession)
            } else {
                try transferJournal.interrupt(id: recordID, summary: "Transfer did not reach verified completion.", results: results)
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: belongsToQueueSession)
            }
        } catch {
            queueIsRunning = false
            do {
                if startCancellationRequested || error is CancellationError {
                    try transferJournal.cancel(id: recordID, results: results)
                } else {
                    try transferJournal.interrupt(id: recordID, summary: error.localizedDescription, results: results)
                }
                handleAttemptTerminal(recordID: recordID)
            } catch {
                let message = "Could not save transfer results: \(error.localizedDescription)"
                if isReplayingQueuedTransfer || queueSessionRecordIDs.contains(recordID) {
                    pauseQueueAttempt(recordID: recordID, message: message)
                } else {
                    queueMessage = message
                }
                operationState = .failed
            }
        }
    }

    private func finishQueueSessionIfNeeded() {
        let presentation = queuePresentation
        guard queueSessionEnded, presentation.isMultiCard, presentation.headerTitle == nil,
              !queueFinishNotificationWasPosted else { return }
        queueFinishNotificationWasPosted = true
        transferNotifier.post(.queueFinished(
            title: presentation.summaryTitle ?? "Queue",
            tally: presentation.tally.text
        ))
    }

    private func addQueueSessionRecord(_ id: UUID) {
        if queueSessionRecordIDs.insert(id).inserted {
            queueSessionRecordOrder.append(id)
        }
    }

    private func persistQueueSession() {
        guard !queueSessionRecordIDs.isEmpty else { return }
        let knownIDs = queueSessionRecordIDs
        let orderedIDs = queueSessionRecordOrder.filter(knownIDs.contains)
        do {
            try transferJournal.saveQueueSession(PersistedQueueSession(
                recordIDs: orderedIDs,
                skippedRecordIDs: skippedQueueAttentionIDs,
                pausedRecordID: queuePausedRecordID,
                ended: queueSessionEnded
            ))
        } catch {
            queueMessage = "Could not save queue session: \(error.localizedDescription)"
        }
    }

    private func clearQueueSessionState() {
        queueSessionRecordIDs.removeAll()
        queueSessionRecordOrder.removeAll()
        reviewedQueueAttentionIDs.removeAll()
        skippedQueueAttentionIDs.removeAll()
        ejectedQueueSourceIDs.removeAll()
        queueSessionSourceVolumeIDs.removeAll()
        queuePausedRecordID = nil
        reviewedQueueRecordID = nil
        queueMessage = nil
        queueSessionEnded = false
        queueFinishNotificationWasPosted = false
        queueStopWasRequested = false
        do {
            try transferJournal.clearQueueSession()
        } catch {
            queueMessage = "Could not clear queue session: \(error.localizedDescription)"
        }
    }

    private func endQueueSession() {
        queueIsRunning = false
        queueSessionEnded = true
        queueStopWasRequested = false
        persistQueueSession()
        finishQueueSessionIfNeeded()
    }

    private func handleAttemptTerminal(recordID: UUID, belongsToQueueSession: Bool? = nil) {
        guard let record = transferJournal.records.first(where: { $0.id == recordID }) else { return }
        let safety = TransferLibraryPresentation.safetyState(for: record)
        let belongs = belongsToQueueSession
            ?? (isReplayingQueuedTransfer || queueSessionRecordIDs.contains(recordID))
        switch safety {
        case .needsAttention, .failed, .interrupted:
            if belongs {
                pauseQueueAttempt(recordID: recordID, message: record.summary)
            } else {
                standaloneAttentionRecordIDsSinceLaunch.insert(recordID)
                transferSignals.send(.attention)
            }
        case .safeToErase:
            transferSignals.send(.safeToErase)
        case .copiedNotVerified:
            // Quick mode completed exactly as requested. It remains amber,
            // but it neither pauses a queue nor requests critical attention.
            break
        default:
            break
        }
    }

    private func pauseQueueAttempt(recordID: UUID, message: String) {
        queueIsRunning = false
        queuePausedRecordID = recordID
        queueMessage = message
        persistQueueSession()
        signalQueueAttentionIfNeeded(for: recordID)
    }

    private func signalQueueAttentionIfNeeded(for id: UUID) {
        guard !reviewedQueueAttentionIDs.contains(id) else { return }
        transferSignals.send(.attention)
    }

    func dismissAttention(for id: UUID) {
        standaloneAttentionRecordIDsSinceLaunch.remove(id)
    }

    func markQueueSourceEjected(_ id: UUID) {
        ejectedQueueSourceIDs.insert(id)
    }

    #if os(macOS)
    func ejectQueueSource(
        _ id: UUID,
        using ejector: @Sendable (URL) async -> String? = { await CardEjectService.eject($0) }
    ) async -> String? {
        guard let record = transferJournal.records.first(where: { $0.id == id }),
              TransferLibraryPresentation.safetyState(for: record) == .safeToErase else {
            return "Only a verified card that is safe to erase can be ejected."
        }
        let access: LocalTransferAccess
        do {
            access = try transferJournal.prepareSourceForEjection(id: id)
        } catch {
            return error.localizedDescription
        }
        defer { access.release() }
        if let error = await ejector(access.sourceURL) { return error }
        markQueueSourceEjected(id)
        return nil
    }

    /// Ejects only rows that the verified presentation currently marks as
    /// safe, mounted, and not already ejected. One failure never prevents the
    /// remaining safe cards from being attempted.
    func ejectAllSafeQueueSources(
        using ejector: @Sendable (URL) async -> String? = { await CardEjectService.eject($0) }
    ) async -> String? {
        let ids = queuePresentation.ejectableCardIDs
        var failures: [String] = []
        for id in ids {
            let name = transferJournal.records.first(where: { $0.id == id })?.title ?? "Card"
            if let error = await ejectQueueSource(id, using: ejector) {
                failures.append("\(name): \(error)")
            }
        }
        guard !failures.isEmpty else { return nil }
        return "Could not eject " + failures.joined(separator: "; ")
    }

    /// Ejects the source captured by the finished record, never the live
    /// Setup selection. The journal holds the original resource identity
    /// open for the duration of the eject request.
    func ejectOutcomeSource(
        using ejector: @Sendable (URL) async -> String? = { await CardEjectService.eject($0) }
    ) async -> String? {
        guard let id = outcomeRecord?.id else { return "No finished card is available to eject." }
        return await ejectQueueSource(id, using: ejector)
    }

    var outcomeSourceIsEjectable: Bool {
        guard let id = outcomeRecord?.id,
              let access = try? transferJournal.prepareSourceForEjection(id: id) else { return false }
        defer { access.release() }
        return CardEjectService.isEjectable(access.sourceURL)
    }
    #endif

    func finishQueueSessionAndStartNewTransfer() {
        clearQueueSessionState()
        startNewTransfer()
    }

    /// The one Start, for every platform's Start button and keyboard
    /// shortcut. A prepared project card starts through
    /// `startProjectOperation()`; with Project chosen and no card prepared
    /// nothing starts (S-2); any other transfer starts only when the
    /// readiness rule allows it; Compare runs the compare.
    func startCurrentMode() async {
        switch currentMode {
        case .copyAndVerify:
            if photographerJobViewModel.hasPreparedIngestAwaitingStart {
                await startProjectOperation()
            } else if usesProjectWorkflow {
                return
            } else if canStartOperation {
                await startOperation()
            }
        case .compareFolders:
            await compareFolders()
        case .masterReport:
            break
        }
    }

    /// Starts a prepared project ingest only after the ordinary transfer
    /// preflight is safe. The project finalizer remains attached through
    /// verification, so completion retains its local evidence on every
    /// platform, and the run uses the job's folder recipe.
    @discardableResult
    func startProjectOperation() async -> Bool {
        guard activeStartID == nil, !isOperationInProgress,
              operationReadinessAssessment.isReady,
              photographerJobViewModel.hasPreparedIngestAwaitingStart,
              let jobID = photographerJobViewModel.activeJob?.id,
              let cardID = photographerJobViewModel.activeCard?.id,
              photographerJobViewModel.preliminaryAnalysis != nil else {
            return false
        }
        guard photographerJobViewModel.beginIngest(
            destinationCount: destinationURLs.count,
            sourceURL: sourceURL,
            verificationMode: verificationMode
        ) else {
            return false
        }

        photographerReportFinalizer = { [weak photographerJobViewModel, jobID, cardID] results in
            guard let photographerJobViewModel,
                  photographerJobViewModel.activeJob?.id == jobID,
                  photographerJobViewModel.activeCard?.id == cardID,
                  let state = photographerJobViewModel.activeCard?.localState,
                  state == .copying || state == .verifying else {
                throw PhotographerReportError.cardNotReady
            }
            return try photographerJobViewModel.completeIngest(results: results)
        }
        activeProjectCardID = cardID
        // The job's folder recipe applies to this run only; the saved label
        // stays the user's. (Until now only the Mac applied it.)
        if let renderedRecipe = photographerJobViewModel.renderedRecipe {
            projectRunCameraSettings = PhotographerDestinationResolver.operationSettings(
                base: cameraLabelSettings,
                renderedRecipe: renderedRecipe
            )
        }
        await startOperation()
        // Every terminal state clears `activeProjectCardID`. A start that
        // returned without one must not leave the card copying.
        if activeProjectCardID == cardID, !isOperationInProgress {
            photographerJobViewModel.operationFailed()
            activeProjectCardID = nil
            photographerReportFinalizer = nil
        }
        return true
    }

    func cancelOperation() {
        queueIsRunning = false
        if activeStartID != nil {
            startCancellationRequested = true
        }
        copyVerifyExecutor.cancel()
        if currentMode == .compareFolders {
            comparisonCoordinator.requestCancellation()
        }

        // Report cancellation to error service
        let context = ErrorContext.general(operation: "File Operation", stage: "Cancelled")
        errorService.reportWarning("Operation cancelled by user", context: context)
        errorService.completeErrorTracking()
        stateService.cancelOperation()
        NotificationCenter.default.post(name: .operationCancelledByUser, object: nil)
        
        operationState = .cancelled
        updateProjectLifecycle(for: .cancelled)
    }

    /// Requests cancellation, then waits until the running task has unwound,
    /// released its security scopes and durably moved its journal record out
    /// of `.running`. App termination and window closure must await this.
    func cancelOperationAndWaitForSettlement() async throws {
        let startID = activeStartID
        let recordID = activeJournalRecordID

        guard startID != nil || isOperationInProgress || queueIsRunning else { return }
        // The queue can be between records: stopping it is already settled,
        // and no journal record is currently running.
        guard startID != nil || isOperationInProgress else {
            queueIsRunning = false
            return
        }
        cancelOperation()

        if let startID {
            while activeStartID == startID || isOperationInProgress {
                try await Task.sleep(for: .milliseconds(10))
            }
        } else {
            while isOperationInProgress {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        guard let recordID else {
            // A natural finish can win the race before cancellation observes
            // the active record. In that case there is no running record left.
            if !transferJournal.records.contains(where: { $0.state == .running }) { return }
            throw CancellationSettlementError.journalRecordMissing
        }
        guard let record = transferJournal.records.first(where: { $0.id == recordID }) else {
            throw CancellationSettlementError.journalRecordMissing
        }
        guard record.state != .running else {
            throw CancellationSettlementError.journalStillRunning(
                transferJournal.persistenceError ?? queueMessage ?? "The journal still marks the transfer as running."
            )
        }
    }
    
    func pauseOperation(reason: PauseInfo.PauseReason = .userRequested) async {
        guard stateService.currentState.canPause else { return }
        
        // Pause the underlying file operations
        await platformManager.fileOperations.pauseOperation()

        // The run may have finished while the engine paused; a finished run
        // stays finished and offers no Resume.
        guard stateService.currentState.canPause else { return }

        // Update state service with current progress
        stateService.pauseOperation(reason: reason, currentProgress: progress)
        
        // Update our operation state to match
        operationState = stateService.currentState
        
        // Update capabilities
        stateService.updateCapabilities(canPause: false, canResume: true)
        SharedLogger.info("Operation paused (\(reason))", category: .transfer)
    }
    
    func resumeOperation() async {
        guard stateService.currentState.canResume else { return }
        
        // Check if resume is recommended
        if let recommendation = stateService.getResumeRecommendation(),
           !recommendation.shouldResume {
            await platformManager.presentAlert(
                title: "Resume Not Recommended",
                message: recommendation.reason
            )
            return
        }
        
        // Resume the underlying file operations
        await platformManager.fileOperations.resumeOperation()
        
        // Update state service
        if stateService.resumeOperation() {
            operationState = stateService.currentState
            
            // Update capabilities
            stateService.updateCapabilities(canPause: true, canResume: false)
            SharedLogger.info("Operation resumed", category: .transfer)
        }
    }
    
    private func updateProjectLifecycle(for state: OperationState) {
        guard activeProjectCardID != nil else { return }
        switch state {
        case .verifying:
            photographerJobViewModel.updateProgressStage(.verifying)
        case .completed(let info):
            if !info.success { photographerJobViewModel.operationFailed() }
            activeProjectCardID = nil
            photographerReportFinalizer = nil
        case .failed:
            photographerJobViewModel.operationFailed()
            activeProjectCardID = nil
            photographerReportFinalizer = nil
        case .cancelled:
            photographerJobViewModel.cancelIngest()
            activeProjectCardID = nil
            photographerReportFinalizer = nil
        default:
            break
        }
    }

    // MARK: - Camera Detection
    
    /// The camera card iPad shows next to the source. The label itself comes
    /// from `cameraLabels`, the same memory-aware path as the Mac.
    private func detectCameraFromSource(_ url: URL?) async {
        guard let url else {
            detectedCamera = nil
            cameraDetectionInProgress = false
            return
        }
        cameraDetectionInProgress = true
        detectedCamera = nil

        let result = await platformManager.cameraDetection.detectCamera(from: url)

        // A newer source may have been chosen while detection ran.
        guard sourceURL == url else { return }
        detectedCamera = result.cameraCard
        cameraDetectionInProgress = false
    }
    
    // MARK: - Folder Comparison (delegated to ComparisonCoordinator)

    func compareFolders() async {
        guard currentMode == .compareFolders else { return }
        guard let left = leftURL, let right = rightURL else {
            await platformManager.presentAlert(
                title: "Invalid Selection",
                message: "Please select both folders to compare."
            )
            return
        }

        // Every entry point (buttons, ⌘R, tests) gets the same block as the
        // screen: a folder compared with itself or its own parent or child
        // would report a false match.
        if let block = CompareBlock.check(left: left, right: right) {
            await platformManager.presentAlert(title: "Can't compare these folders", message: block.message)
            return
        }

        guard !isOperationInProgress else { return }
        let comparedMode = verificationMode
        isOperationInProgress = true
        lastOperationWasCompare = true
        operationState = .inProgress
        results = []
        clearCompareOutcome()
        errorService.clearCurrentErrors()
        progress = OperationProgress(
            overallProgress: 0.0,
            currentFile: nil,
            filesProcessed: 0,
            totalFiles: 0,
            currentStage: .preparing,
            speed: nil)

        do {
            let stats = try await comparisonCoordinator.compareFolders(
                left: left,
                right: right,
                verificationMode: comparedMode,
                onProgress: { [weak self] prog in
                    self?.progress = prog
                }
            )
            if Task.isCancelled || comparisonCoordinator.isCancellationRequested {
                throw CancellationError()
            }
            guard leftURL == left, rightURL == right, verificationMode == comparedMode else {
                isOperationInProgress = false
                operationState = .notStarted
                progress = nil
                return
            }
            self.lastCompareStats = stats
            lastCompareEnd = .completed
            isOperationInProgress = false
            let message: String
            let verifiesContents = CompareCheckPlan.make(for: comparedMode).verifiesContents
            if stats.isClean {
                message = verifiesContents
                    ? "Folders match"
                    : "Sizes match, not verified"
            } else {
                var issues: [String] = []
                if stats.mismatchedCount > 0 { issues.append("\(stats.mismatchedCount) mismatched") }
                if stats.onlyInLeftCount > 0 { issues.append("\(stats.onlyInLeftCount) only in source") }
                if stats.onlyInRightCount > 0 { issues.append("\(stats.onlyInRightCount) only in destination") }
                message = "Comparison found differences: \(issues.joined(separator: ", "))"
            }
            // Success means verified (Promise 2): a size-only match is not
            // one, or the Dock tile and anything else reading `success`
            // would show it green.
            operationState = .completed(OperationCompletionInfo(success: stats.isClean && verifiesContents, message: message))
            return
        } catch is CancellationError {
            isOperationInProgress = false
            operationState = .cancelled
            lastCompareEnd = .cancelled
            return
        } catch {
            isOperationInProgress = false
            operationState = .failed
            lastCompareEnd = .failed(error.localizedDescription)
            await platformManager.presentError(error)
            return
        }
    }
    
    // MARK: - Completion Export (same record as history)

    /// Builds the completion export from the finished transfer's journal record:
    /// authoritative per-file results, verification mode, project provenance, and
    /// the ASC MHL request flag. Callers present real save/share UI and surface
    /// thrown errors instead of opening a temporary summary elsewhere.
    func completionExportDocument(asCSV: Bool) throws -> TransferHistoryDocument {
        guard let id = activeJournalRecordID,
              let record = transferJournal.records.first(where: { $0.id == id }),
              record.state != .queued, record.state != .running else {
            throw CompletionExportError.noFinishedTransfer
        }
        return try TransferHistoryDocument(record: record, asCSV: asCSV)
    }
    
    // MARK: - Mode Management

    /// Decision C-2: no mode switch while anything runs, on any platform.
    var isModeSwitchLocked: Bool {
        ModeSwitchPolicy.isLocked(isOperationInProgress: isOperationInProgress, queueIsRunning: queueIsRunning)
    }

    func switchMode(to mode: AppMode) {
        guard !isModeSwitchLocked else { return }
        currentMode = mode
    }

    /// The journal record of the transfer the outcome screen shows: it gives
    /// Retry, Export and the run's duration. Nil after `resetForNewOperation()`.
    var outcomeRecord: LocalTransferRecord? {
        guard let id = activeJournalRecordID else { return nil }
        return transferJournal.records.first { $0.id == id }
    }

    /// "New transfer" on the outcome screen, on every platform (decision
    /// O-1): the next card usually goes to the same backups, and keeping the
    /// old source risks copying the same card again by accident.
    func startNewTransfer() {
        // A stopped queue with cards still waiting keeps its session, or
        // those cards would be stranded behind a disabled Run Queue.
        let hasWaitingCards = transferJournal.records.contains {
            queueSessionRecordIDs.contains($0.id) && $0.state == .queued
        }
        if !hasWaitingCards && (queueSessionEnded || !hasUnresolvedQueueRecords) {
            clearQueueSessionState()
        }
        let reviewedSetup = reviewedSelectionSnapshot
        reviewedSelectionSnapshot = nil
        reviewedQueueRecordID = nil
        resetForNewOperation()
        sourceURL = nil
        if let reviewedSetup {
            isReplayingQueuedTransfer = true
            destinationURLs = reviewedSetup.destinations
            verificationMode = reviewedSetup.verificationMode
            isReplayingQueuedTransfer = false
        }
        standaloneAttentionRecordIDsSinceLaunch.removeAll()
    }

    func resetForNewOperation() {
        results = []
        progress = nil
        progressPresentation.reset()
        lastPresentedBytes = 0
        presentedDestinationCount = nil
        operationState = .notStarted
        currentOperation = nil
        activeJournalRecordID = nil
    }

    func togglePause() async {
        if canPause {
            await pauseOperation()
        } else if canResume {
            await resumeOperation()
        }
    }

    func saveVerificationMode() {
        guard !isReplayingQueuedTransfer else { return }
        UserDefaults.standard.set(verificationMode.rawValue, forKey: "lastVerificationMode")
    }

    // MARK: - Completion State (derived from OperationState)

    var completionState: CompletionState {
        // Master Report is its own workflow. A prior Copy outcome remains in
        // the journal and reappears when Copy is selected, but must not route
        // over the report screen while Master Report is active.
        if currentMode == .masterReport { return .idle }
        switch operationState {
        case .completed(let info):
            if info.success {
                return .success(message: info.message)
            } else {
                return .issues(message: info.message)
            }
        case .failed:
            return .failed(message: "Operation failed")
        case .inProgress, .copying, .verifying, .resuming:
            return .inProgress
        case .cancelled:
            return .cancelled(message: "Operation cancelled by user")
        case .idle, .notStarted, .paused:
            return .idle
        }
    }

    // MARK: - Computed Properties

    var canStartOperation: Bool {
        guard !hasUnresolvedQueueRecords else { return false }
        switch currentMode {
        case .copyAndVerify:
            return operationReadinessAssessment.isReady && !isOperationInProgress
        case .compareFolders:
            guard let leftURL, let rightURL, !isOperationInProgress else { return false }
            return CompareBlock.check(left: leftURL, right: rightURL) == nil
        case .masterReport:
            return currentOperation != nil && !isOperationInProgress
        }
    }
    
    // MARK: - Timing Computed Properties
    
    var operationDuration: String? {
        return timingService.currentTiming?.formattedDuration
    }
    
    // MARK: - Error Computed Properties
    
    var currentErrors: [ErrorReport] {
        return errorService.currentErrors
    }
    
    var errorSummary: ErrorSummary? {
        return errorService.errorSummary
    }
    
    var hasErrors: Bool {
        return !errorService.currentErrors.isEmpty
    }
    
    var hasCriticalErrors: Bool {
        return errorService.getCriticalErrors().count > 0
    }
    
    var errorCount: Int {
        return errorService.currentErrors.filter { $0.category != .warning }.count
    }
    
    var warningCount: Int {
        return errorService.currentErrors.filter { $0.category == .warning }.count
    }
    
    // MARK: - Pause/Resume Computed Properties
    
    var canPause: Bool {
        return stateService.currentState.canPause
    }
    
    var canResume: Bool {
        return stateService.currentState.canResume
    }
    
    var isPaused: Bool {
        return stateService.currentState.isPaused
    }
    
    var pauseResumeCapabilities: PauseResumeCapabilities {
        return stateService.pauseResumeCapabilities
    }
    
    var savedOperations: [SavedOperationState] {
        return stateService.savedOperations
    }
    
    // MARK: - Folder Info Computed Properties

    func getFolderInfo(for url: URL) -> EnhancedFolderInfo? {
        return folderInfoService.getFolderInfo(for: url)
    }

    func isFolderInfoLoading(for url: URL) -> Bool {
        return folderInfoService.isFolderInfoLoading(for: url)
    }
    
    var sourceFolderSummary: String {
        guard let info = sourceFolderInfo else { return "No folder selected" }
        return "\(info.formattedFileCount) files • \(info.formattedSize)"
    }
    
    var destinationsSummary: String {
        guard !destinationURLs.isEmpty else { return "No destinations selected" }
        let totalCapacity = destinationFolderInfos.values.compactMap { 
            getDriveCapacity(for: $0.url) 
        }.reduce(0, +)
        
        if totalCapacity > 0 {
            let formattedCapacity = ByteCountPresentation.capacity(totalCapacity)
            return "\(destinationURLs.count) destination\(destinationURLs.count == 1 ? "" : "s") • ~\(formattedCapacity) available"
        } else {
            return "\(destinationURLs.count) destination\(destinationURLs.count == 1 ? "" : "s")"
        }
    }
    
    private func getDriveCapacity(for url: URL) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            guard values.volumeAvailableCapacityForImportantUsage != nil
                    || values.volumeAvailableCapacity != nil else { return nil }
            return SafetyValidator.resolvedAvailableSpace(
                importantUsage: values.volumeAvailableCapacityForImportantUsage,
                standardCapacity: values.volumeAvailableCapacity
            )
        } catch {
            return nil
        }
    }
    
    // Get folder info with type hints for professional display
    func getFolderDisplayInfo(for url: URL) -> FolderDisplayInfo? {
        guard let enhancedInfo = getFolderInfo(for: url) else { return nil }
        
        // Convert to base FolderInfo for compatibility
        let baseInfo = FolderInfo(
            url: enhancedInfo.url,
            fileCount: enhancedInfo.fileCount,
            totalSize: enhancedInfo.totalSize,
            lastModified: enhancedInfo.lastModified,
            isInternalDrive: enhancedInfo.isInternalDrive
        )
        
        let driveType = getDriveType(for: url)
        let availableSpace = getDriveCapacity(for: url)
        let isLoading = isFolderInfoLoading(for: url)
        
        return FolderDisplayInfo(
            baseInfo: baseInfo,
            driveType: driveType,
            availableSpace: availableSpace,
            isLoading: isLoading
        )
    }
    
    private func getDriveType(for url: URL) -> DriveType {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeIsInternalKey,
                .volumeNameKey
            ])
            
            if values.volumeIsRemovable == true || values.volumeIsEjectable == true {
                // Check if it's likely a camera card based on volume name
                if let name = values.volumeName?.lowercased() {
                    if name.contains("untitled") || name.hasPrefix("no name") || 
                       name.contains("cf") || name.contains("sd") {
                        return .cameraCard
                    }
                }
                return .externalDrive
            } else if values.volumeIsInternal == false {
                return .networkDrive
            } else {
                return .internalDrive
            }
        } catch {
            return .unknown
        }
    }
    
    // MARK: - Enhanced Folder Info Helpers
    
    /// Get a detailed summary for source folder including file types
    var sourceDetailedSummary: String? {
        guard let info = sourceFolderInfo else { return nil }
        var parts = [info.formattedFileCount + " files", info.formattedSize]
        
        if let topType = info.topFileTypes.first {
            parts.append("\(topType.count) \(topType.type) files")
        }
        
        return parts.joined(separator: " • ")
    }
    
    /// Get file type breakdown for source folder
    var sourceFileTypesBreakdown: [(type: String, count: Int)] {
        return sourceFolderInfo?.topFileTypes ?? []
    }
    
    /// Whether a transfer may start, and why not. One rule on every platform
    /// (thesis decision): the Mac's stricter check, with the runtime's space
    /// margin. See `OperationReadinessAssessment.assess`.
    var operationReadinessAssessment: OperationReadinessAssessment {
        OperationReadinessAssessment(
            transferReadiness,
            hasDestinations: !destinationURLs.isEmpty
        )
    }

    /// The one readiness rule (`TransferReadiness`, UI plan step 4.5) for
    /// the current selection, with this disk's free space and writability.
    var transferReadiness: TransferReadiness {
        TransferReadiness.assess(
            source: sourceURL,
            sourceFileCount: sourceFolderInfo?.fileCount,
            sourceBytes: sourceFolderInfo?.totalSize,
            isAnalysingSource: isAnalysingSource,
            destinations: destinationURLs,
            settings: cameraLabelSettings,
            verificationMode: verificationMode,
            availableBytes: { self.getDriveCapacity(for: $0) },
            isWritable: TransferReadiness.isWritableFolder
        )
    }
    
    /// Get source folder metadata summary for professional display
    var sourceFolderMetadata: FolderMetadataSummary? {
        guard let info = sourceFolderInfo else { return nil }
        
        return FolderMetadataSummary(
            fileCount: info.fileCount,
            totalSize: info.totalSize,
            averageFileSize: info.averageFileSize,
            largestFile: info.largestFile,
            fileTypeBreakdown: info.topFileTypes,
            dateRange: info.dateRangeDescription,
            driveType: getDriveType(for: info.url),
            lastModified: info.lastModified
        )
    }
}

// MARK: - Supporting Types for Enhanced Folder Display

struct OperationReadinessAssessment {
    let isReady: Bool
    /// Everything in the way, including "not chosen yet".
    let issues: [String]
    let warnings: [String]
    /// Only real findings: `issues` without the two "not chosen yet" lines,
    /// which the setup screens show as the next step instead.
    var blockingIssues: [String] = []
    /// The source scan has not finished. Not an issue (nothing is wrong),
    /// but Start waits for it.
    var isAnalysing = false
    
    var hasIssues: Bool { !issues.isEmpty }
    var hasWarnings: Bool { !warnings.isEmpty }
    
    var statusIcon: String {
        if !isReady { return "exclamationmark.triangle.fill" }
        if hasWarnings { return "exclamationmark.triangle" }
        return "checkmark.circle.fill"
    }
    
    var statusColor: Color {
        if !isReady { return .red }
        if hasWarnings { return .orange }
        return .green
    }
    
    var statusMessage: String {
        if !isReady && issues.isEmpty && isAnalysing {
            return "Analyzing source…"
        }
        if !isReady {
            return "Cannot start: \(issues.joined(separator: ", "))"
        }
        if hasWarnings {
            return "Ready with warnings: \(warnings.joined(separator: ", "))"
        }
        return "Ready to start"
    }
}

extension OperationReadinessAssessment {
    static let noSourceIssue = TransferReadiness.noSourceIssue
    static let noDestinationIssue = TransferReadiness.noDestinationIssue

    /// The one readiness rule, `TransferReadiness.assess`, in the shape
    /// Start, ⌘R and the dev tools read. `isWritable` defaults to "yes" so
    /// callers that do not inspect the disk (tests with made-up paths) keep
    /// the rest of the rule.
    static func assess(
        source: URL?,
        sourceFileCount: Int? = nil,
        sourceBytes: Int64?,
        isAnalysingSource: Bool,
        destinations: [URL],
        settings: CameraLabelSettings,
        verificationMode: VerificationMode,
        availableBytes: (URL) -> Int64?,
        isWritable: (URL) -> Bool = { _ in true }
    ) -> OperationReadinessAssessment {
        let readiness = TransferReadiness.assess(
            source: source,
            sourceFileCount: sourceFileCount,
            sourceBytes: sourceBytes,
            isAnalysingSource: isAnalysingSource,
            destinations: destinations,
            settings: settings,
            verificationMode: verificationMode,
            availableBytes: availableBytes,
            isWritable: isWritable
        )
        return OperationReadinessAssessment(
            readiness,
            hasDestinations: !destinations.isEmpty
        )
    }

    /// "Not chosen yet" stays in `issues` (so `isReady` and the dev tools
    /// see it) but never in `blockingIssues`.
    init(_ readiness: TransferReadiness, hasDestinations: Bool) {
        let setupIssues: [String]
        switch readiness.status {
        case .needsSource:
            setupIssues = [TransferReadiness.noSourceIssue]
        default:
            setupIssues = hasDestinations ? [] : [TransferReadiness.noDestinationIssue]
        }
        let issues = setupIssues + readiness.blockers
        self.init(
            isReady: readiness.isReady,
            issues: issues,
            warnings: readiness.status == .needsSource ? [] : readiness.warnings,
            blockingIssues: readiness.blockers,
            isAnalysing: readiness.status == .analysing
        )
    }
}

struct FolderMetadataSummary {
    let fileCount: Int
    let totalSize: Int64
    let averageFileSize: Int64
    let largestFile: (name: String, size: Int64)?
    let fileTypeBreakdown: [(type: String, count: Int)]
    let dateRange: String
    let driveType: DriveType
    let lastModified: Date
    
    var formattedTotalSize: String {
        ByteCountPresentation.fileSize(totalSize)
    }
    
    var formattedAverageSize: String {
        ByteCountPresentation.fileSize(averageFileSize)
    }
    
    var formattedLargestFile: String? {
        guard let largest = largestFile else { return nil }
        let size = ByteCountPresentation.fileSize(largest.size)
        return "\(largest.name) (\(size))"
    }
    
    var primaryFileType: String? {
        return fileTypeBreakdown.first?.type
    }
    
    var diversityScore: String {
        let typeCount = fileTypeBreakdown.count
        if typeCount <= 1 { return "Uniform" }
        if typeCount <= 3 { return "Mixed" }
        return "Diverse"
    }
}
