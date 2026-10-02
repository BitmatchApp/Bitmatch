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

fileprivate struct ProjectRunIdentity: Sendable {
    let jobID: UUID
    let cardID: UUID
}

private struct UnresolvedPhysicalDiskIdentityProvider: PhysicalDiskIdentityProviding {
    func physicalDiskIdentity(for url: URL) -> String? { nil }
}

/// The immutable inputs and identity of one transfer attempt. Setup owns the
/// live composer; execution, evidence, and presentation own this snapshot.
struct TransferRunContext {
    let sourceURL: URL
    let destinationURLs: [URL]
    let verificationMode: VerificationMode
    let cameraLabelSettings: CameraLabelSettings
    let reportSettings: ReportPrefs
    let generateASCMHL: Bool
    let projectID: UUID?
    let projectCardID: UUID?
    let journalRecordID: UUID?
    let estimatedFiles: Int
    let estimatedBytes: Int64
    let plannedTotalBytes: Int64?
    let sourceIsKnownEmpty: Bool
    let independentDestinationCount: Int
    let photographerReportFinalizer: PhotographerReportFinalizer?

    fileprivate var projectIdentity: ProjectRunIdentity? {
        guard let projectID, let projectCardID else { return nil }
        return ProjectRunIdentity(jobID: projectID, cardID: projectCardID)
    }

    func recording(in journalRecordID: UUID) -> Self {
        Self(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            verificationMode: verificationMode,
            cameraLabelSettings: cameraLabelSettings,
            reportSettings: reportSettings,
            generateASCMHL: generateASCMHL,
            projectID: projectID,
            projectCardID: projectCardID,
            journalRecordID: journalRecordID,
            estimatedFiles: estimatedFiles,
            estimatedBytes: estimatedBytes,
            plannedTotalBytes: plannedTotalBytes,
            sourceIsKnownEmpty: sourceIsKnownEmpty,
            independentDestinationCount: independentDestinationCount,
            photographerReportFinalizer: photographerReportFinalizer
        )
    }
}

@MainActor
private final class TransferRunResults {
    private(set) var rows: [ResultRow] = []

    func upsert(_ row: ResultRow) {
        if let index = rows.firstIndex(where: {
            $0.path == row.path && $0.destinationPath == row.destinationPath
        }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    func replace(with rows: [ResultRow]) {
        self.rows = rows
    }
}

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
    private let physicalDiskIdentityProvider: any PhysicalDiskIdentityProviding
    /// The single preference store used by the coordinator and the settings
    /// models it owns. The app uses `.standard`; tests inject isolated suites.
    let defaults: UserDefaults
    
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
    @Published var generateASCMHL: Bool {
        didSet {
            if !isReplayingQueuedTransfer {
                defaults.set(generateASCMHL, forKey: "BitMatchGenerateASCMHL")
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
    @Published private(set) var queueSessionStarted = false
    @Published private(set) var editingSetupTransferID: UUID?
    private var queueSessionRecordOrder: [UUID] = []
    private var isProcessingQueue = false
    private var activeJournalRecordID: UUID?
    private(set) var activeRunContext: TransferRunContext?
    private var queueFinishNotificationWasPosted = false
    private var queueStopWasRequested = false
    private var queueSessionSourceVolumeIDs: Set<String> = []
    /// Screenshot seam (`-BitMatchDemoSlow`): journal record IDs enqueued by
    /// the DEBUG demo seeder. Only these runs copy with throttling hooks;
    /// every user run passes none. Always empty in Release: only the DEBUG
    /// seeder ever inserts.
    var demoSlowRecordIDs = Set<UUID>()
    /// Screenshot seam (`-BitMatchDemoOpenQueue`): the DEBUG seeder sets this
    /// after seeding so the queue opens itself (sheet on compact, inspector
    /// on regular). Always false in Release.
    @Published var demoQueueAutoOpen = false
    private var isClearingSnapshottedComposerSource = false
    private struct SetupComposerSnapshot {
        let source: URL?
        let destinations: [URL]
        let verificationMode: VerificationMode
        let cameraSettings: CameraLabelSettings
        let reportSettings: ReportPrefs
        let generateASCMHL: Bool
    }
    private var composerBeforeEditing: SetupComposerSnapshot?
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
    /// Read by the Mac transfer rows while the setting itself lives with the
    /// other General settings.
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
    /// finished row verdict, journal and export read. Writing the whole
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
            scheduleDestinationIndependenceAssessment()
        }
    }
    /// Resolved once per selection change, never once per progress tick.
    private(set) var destinationVolumeNames: [String] = []
    /// Resolved off the main actor when selection changes and confirmed when
    /// Start snapshots a run. SwiftUI rendering never performs disk lookup.
    @Published private(set) var destinationIndependence = BackupIndependencePolicy.assess(destinations: [])
    private var destinationIndependenceGeneration = 0

    private func scheduleDestinationIndependenceAssessment() {
        destinationIndependenceGeneration &+= 1
        let generation = destinationIndependenceGeneration
        let destinations = destinationURLs
        let names = destinations.map { DestinationIdentityPresentation.title(for: $0) }
        let provider = physicalDiskIdentityProvider
        // Preserve the lead-approved behavior until macOS positively
        // identifies a shared physical disk.
        destinationIndependence = BackupIndependencePolicy.assess(
            destinations: destinations,
            names: names,
            provider: UnresolvedPhysicalDiskIdentityProvider()
        )
        Task { [weak self] in
            let assessment = await Self.resolveDestinationIndependence(
                destinations: destinations,
                names: names,
                provider: provider
            )
            guard let self,
                  self.destinationIndependenceGeneration == generation,
                  self.destinationURLs == destinations else { return }
            self.destinationIndependence = assessment
        }
    }

    private nonisolated static func resolveDestinationIndependence(
        destinations: [URL],
        names: [String],
        provider: any PhysicalDiskIdentityProviding
    ) async -> BackupIndependenceAssessment {
        await Task.detached(priority: .userInitiated) {
            BackupIndependencePolicy.assess(
                destinations: destinations,
                names: names,
                provider: provider
            )
        }.value
    }
    var presentedSourceURL: URL? {
        // With no run at all, both IDs are nil and compare equal; only a
        // real run context may stand in for the composer.
        if let context = activeRunContext, context.journalRecordID == activeJournalRecordID {
            return context.sourceURL
        }
        return outcomeRecord?.source.url ?? sourceURL
    }
    var presentedDestinationURLs: [URL] {
        if let context = activeRunContext, context.journalRecordID == activeJournalRecordID {
            return context.destinationURLs
        }
        return outcomeRecord?.destinations.map(\.url) ?? destinationURLs
    }
    var presentedDestinationNames: [String] {
        presentedDestinationURLs.map(DestinationVolumeLabel.resolve)
    }
    @Published var leftURL: URL? { // For folder comparison
        didSet {
            if oldValue != leftURL {
                clearCompareOutcome()
                beginSavedChecksumDiscovery(at: leftURL)
            }
        }
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
    @Published var checkAgainst: CheckAgainstChoice = .anotherFolder {
        didSet { if oldValue != checkAgainst { clearCompareOutcome() } }
    }
    @Published private(set) var savedChecksumAvailability: SavedChecksumAvailability = .notFound
    @Published private(set) var lastSavedChecksumResult: SavedChecksumCheck.Result?
    private var savedChecksumDiscovery: SavedChecksumCheck.Discovery?
    private var savedChecksumDiscoveryTask: Task<Void, Never>?
    /// True when the most recent operation was a compare, so the shared
    /// `operationState` it left behind is not shown as a transfer outcome.
    @Published private(set) var lastOperationWasCompare = false

    private func clearCompareOutcome() {
        lastCompareStats = nil
        lastSavedChecksumResult = nil
        lastCompareEnd = nil
    }

    private func beginSavedChecksumDiscovery(at url: URL?) {
        savedChecksumDiscoveryTask?.cancel()
        savedChecksumDiscovery = nil
        savedChecksumAvailability = url == nil ? .notFound : .checking
        checkAgainst = .defaultChoice(for: savedChecksumAvailability)
        guard let url else { return }
        savedChecksumDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let discovery = try await comparisonCoordinator.discoverSavedChecksums(at: url)
                guard !Task.isCancelled, leftURL == url else { return }
                savedChecksumDiscovery = discovery
                savedChecksumAvailability = .found(fileCount: discovery.expectedFiles.count)
                checkAgainst = .defaultChoice(for: savedChecksumAvailability)
            } catch is CancellationError {
                return
            } catch SavedChecksumCheck.CheckError.notFound {
                guard leftURL == url else { return }
                savedChecksumAvailability = .notFound
                checkAgainst = .defaultChoice(for: savedChecksumAvailability)
            } catch {
                guard leftURL == url else { return }
                SharedLogger.warning("Could not read saved checksums at \(url.path): \(error)", category: .transfer)
                savedChecksumAvailability = .notFound
                checkAgainst = .defaultChoice(for: savedChecksumAvailability)
            }
        }
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
    private var cancellationOrigin: TransferCancelOrigin = .user
    private var activeProjectCardID: UUID?
    var isProjectRunInProgress: Bool {
        isOperationInProgress && (activeRunContext?.projectCardID ?? activeProjectCardID) != nil
    }

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
        defaults: UserDefaults = .standard,
        physicalDiskIdentityProvider: any PhysicalDiskIdentityProviding = SystemPhysicalDiskIdentityProvider()
    ) {
        self.platformManager = platformManager
        self.physicalDiskIdentityProvider = physicalDiskIdentityProvider
        self.defaults = defaults
        let environment = ProcessInfo.processInfo.environment
        let isTesting = environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
        let testJournalURL = isTesting ? FileManager.default.temporaryDirectory
            .appendingPathComponent("BitMatchTestJournal-\(UUID().uuidString).json") : nil
        self.generateASCMHL = defaults.object(forKey: "BitMatchGenerateASCMHL") as? Bool ?? true
        self.reportPrefsStore = ReportPrefsStore(defaults: defaults)
        let generalSettings = GeneralSettings(defaults: defaults)
        self.generalSettings = generalSettings
        self.transferNotifier = TransferNotifier(settings: generalSettings)
        self.cameraLabels = CameraLabelModel(defaults: defaults)
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
        var sessionStarted = false
        if let persistedSession {
            recoveredOrder = persistedSession.recordIDs.filter(existingIDs.contains)
            skippedIDs = persistedSession.skippedRecordIDs.intersection(existingIDs)
            pausedID = persistedSession.pausedRecordID.flatMap { existingIDs.contains($0) ? $0 : nil }
            sessionEnded = persistedSession.ended
            sessionStarted = persistedSession.started ?? selectedJournal.records.contains {
                recoveredOrder.contains($0.id) && $0.state != .queued
            }
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
        self.queueSessionStarted = sessionStarted
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
            let selectedProjectStore = projectStore ?? UserDefaultsPhotographerJobStore(defaults: defaults)
            self.photographerJobViewModel = PhotographerJobViewModel(
                store: selectedProjectStore,
                remoteBackupCoordinator: UnavailableRemoteProjectCoordinator(store: selectedProjectStore),
                workflowDefaults: defaults
            )
        }
        self.reportSettings = reportPrefsStore.load()
        // Default first launch to checksum verification; honor last-picked thereafter.
        if let saved = defaults.string(forKey: "lastVerificationMode"),
           let mode = VerificationMode.allCases.first(where: { $0.rawValue == saved }) {
            verificationMode = mode
        } else {
            verificationMode = .standard
        }
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
    }
    
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
                // Suggest or clear the next card's label. Stored selections
                // loaded for review already carry their own label.
                guard !self.isReplayingQueuedTransfer,
                      !self.isClearingSnapshottedComposerSource else { return }
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
                self?.defaults.set(mode.rawValue, forKey: "lastVerificationMode")
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
        let destinationCount = presentedDestinationCount ?? activeRunContext?.destinationURLs.count ?? destinationURLs.count
        // Time left is measured against the copy work actually planned: the
        // scanned source once per backup. The engine's `totalBytes` covers
        // one backup, and is a 1 GB guess when the source was not scanned.
        let plannedTotalBytes: Int64?
        if let context = activeRunContext {
            plannedTotalBytes = context.plannedTotalBytes
                ?? prog.totalBytes.map { $0 * Int64(context.destinationURLs.count) }
        } else {
            plannedTotalBytes = sourceFolderInfo.map { $0.totalSize * Int64(destinationURLs.count) }
        }
        presentation.setPlannedTotalBytes(plannedTotalBytes)
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
        "Destinations are locked while the prepared project card is waiting to start."

    /// A prepared project card has already derived its destination package
    /// from this selection, so changing it would invalidate that preparation.
    /// Ordinary running and finished transfers own immutable run snapshots and
    /// never lock the composer.
    var isDestinationSelectionLocked: Bool {
        photographerJobViewModel.hasPreparedIngestAwaitingStart
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

    /// One-time composer snapshots, in the order they will run. Each record
    /// owns its source, destinations and settings independently.
    var stagedSetupTransfers: [LocalTransferRecord] {
        let recordsByID = Dictionary(uniqueKeysWithValues: transferJournal.records.map { ($0.id, $0) })
        return queueSessionRecordOrder.compactMap { recordsByID[$0] }.filter {
            $0.state == .queued && $0.projectID == nil
        }
    }

    var canEnqueueSelection: Bool {
        operationReadinessAssessment.isReady
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
        let id = try transferJournal.enqueue(
            sourceURL: source, destinationURLs: destinations,
            verificationMode: verificationMode ?? self.verificationMode,
            cameraSettings: settings, reportSettings: reportSettings ?? self.reportSettings,
            generateASCMHL: generateASCMHL ?? self.generateASCMHL
        )
        queueSessionEnded = false
        addQueueSessionRecord(id)
        if let volumeID = transferJournal.records.first(where: { $0.id == id })?.source.volumeID {
            queueSessionSourceVolumeIDs.insert(volumeID)
        }
        persistQueueSession()
        return id
    }

    @discardableResult
    func enqueueSelection() throws -> UUID {
        guard canEnqueueSelection, let sourceURL else {
            throw FileOperationError.unsafeOperation("Choose a source and destinations for a one-time transfer first.")
        }
        let committedID: UUID
        if let id = editingSetupTransferID {
            let scopedURLs = ([sourceURL] + destinationURLs).filter { $0.startAccessingSecurityScopedResource() }
            defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            if let refusal = destinationURLs.lazy.compactMap({
                BackupTargetPolicy.refusal(for: $0, origin: .userChoice, source: sourceURL)
            }).first {
                throw FileOperationError.unsafeOperation(refusal)
            }
            try SafetyValidator.validateResolvedDestinationRoots(
                source: sourceURL, destinations: destinationURLs, settings: cameraLabelSettings
            )
            guard try CardSource.containsRegularFile(base: sourceURL) else {
                throw FileOperationError.unsafeOperation("Source folder is empty. Choose a source that contains files.")
            }
            try transferJournal.replaceQueued(
                id: id,
                sourceURL: sourceURL,
                destinationURLs: destinationURLs,
                verificationMode: verificationMode,
                cameraSettings: cameraLabelSettings,
                reportSettings: reportSettings,
                generateASCMHL: generateASCMHL
            )
            editingSetupTransferID = nil
            composerBeforeEditing = nil
            committedID = id
        } else {
            if let running = runningOneTimeTransfer {
                addQueueSessionRecord(running.id)
                if let volumeID = running.source.volumeID { queueSessionSourceVolumeIDs.insert(volumeID) }
            }
            committedID = try enqueue(source: sourceURL, destinations: destinationURLs)
        }
        isClearingSnapshottedComposerSource = true
        cameraLabels.clearDetectionPreservingSettings()
        self.sourceURL = nil
        isClearingSnapshottedComposerSource = false
        if isOperationInProgress || queueIsRunning { startQueue() }
        return committedID
    }

    func editSetupTransfer(_ id: UUID) throws {
        guard editingSetupTransferID == nil,
              let record = stagedSetupTransfers.first(where: { $0.id == id }) else {
            throw FileOperationError.unsafeOperation("Only a waiting setup transfer can be edited.")
        }
        // A stopped queue may still be showing the preceding card's outcome.
        // Return to Setup before loading the waiting snapshot into its composer.
        if queueSessionEnded && showsOutcomeSummary {
            resetForNewOperation()
            sourceURL = nil
        }
        composerBeforeEditing = SetupComposerSnapshot(
            source: sourceURL,
            destinations: destinationURLs,
            verificationMode: verificationMode,
            cameraSettings: cameraLabelSettings,
            reportSettings: reportSettings,
            generateASCMHL: generateASCMHL
        )
        editingSetupTransferID = id
        cameraLabels.clearDetectionPreservingSettings()
        isReplayingQueuedTransfer = true
        sourceURL = record.source.url
        isReplayingQueuedTransfer = false
        destinationURLs = record.destinations.map(\.url)
        verificationMode = record.verificationMode
        cameraLabelSettings = record.cameraSettings
        reportSettings = record.reportSettings
        generateASCMHL = record.generateASCMHL
    }

    func cancelSetupTransferEdit() {
        guard let snapshot = composerBeforeEditing else { return }
        cameraLabels.clearDetectionPreservingSettings()
        isReplayingQueuedTransfer = true
        sourceURL = snapshot.source
        isReplayingQueuedTransfer = false
        destinationURLs = snapshot.destinations
        verificationMode = snapshot.verificationMode
        cameraLabelSettings = snapshot.cameraSettings
        reportSettings = snapshot.reportSettings
        generateASCMHL = snapshot.generateASCMHL
        editingSetupTransferID = nil
        composerBeforeEditing = nil
    }

    /// Starts the cards assembled on Setup. If more than one card is ready,
    /// the current selection first enters the same validated journal path as
    /// every other queued card, then the existing serial queue runs them.
    @discardableResult
    func startSetupTransfers() throws -> UUID? {
        guard !usesProjectWorkflow, !photographerJobViewModel.hasPreparedIngestAwaitingStart else {
            throw FileOperationError.unsafeOperation("Finish setting up the project card before starting.")
        }
        var committedID: UUID?
        if sourceURL != nil {
            committedID = try enqueueSelection()
        }
        guard !stagedSetupTransfers.isEmpty else {
            throw FileOperationError.unsafeOperation("Choose a source and destinations first.")
        }
        startQueue()
        return committedID
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
        if isOperationInProgress || queueIsRunning { startQueue() }
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
            queueMessage = "Finish or cancel the folder comparison, then choose Resume Queue."
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
        queueSessionStarted = true
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
        if editingSetupTransferID == id { cancelSetupTransferEdit() }
        try transferJournal.removeQueued(id: id)
        queueSessionRecordIDs.remove(id)
        queueSessionRecordOrder.removeAll { $0 == id }
        persistQueueSession()
    }

    /// Removes terminal cards from the visible session only. Their journal
    /// records—and therefore History and reports—remain untouched.
    func clearFinishedQueueRows() {
        let finishedIDs = Set(queuePresentation.rows.filter(\.isFinished).map(\.id))
        guard !finishedIDs.isEmpty else { return }
        removeQueueSessionRows(finishedIDs)
    }

#if DEBUG
    /// Screenshot scenarios only (DEBUG demo seeder): drops the previous
    /// session's queue rows — finished, waiting, or paused — so a flagged
    /// demo launch counts from "1 of 3" instead of accumulating stale rows.
    /// Journal History records are untouched, matching `removeFinishedQueueRow`.
    func resetQueueSessionForDemo() {
        removeQueueSessionRows(queueSessionRecordIDs)
    }
#endif

    /// Screenshot seam (`-BitMatchDemoSlow`): throttling hooks for one of the
    /// demo seeder's own records, nil for every other run. The non-nil value
    /// is constructed in DEBUG-only code, so Release always returns nil here.
    func demoFanOutHooks(for recordID: UUID?) -> DestinationWriter.FanOutHooks? {
#if DEBUG
        guard let recordID,
              demoSlowRecordIDs.contains(recordID),
              DemoQueueSeeder.isSlowRequested else { return nil }
        return DemoQueueSeeder.slowCopyHooks
#else
        return nil
#endif
    }

    /// Removes one terminal row from this session list while leaving its
    /// journal record, report, copied files, and History entry untouched.
    func removeFinishedQueueRow(_ id: UUID) throws {
        guard queueSessionRecordIDs.contains(id),
              queuePresentation.rows.first(where: { $0.id == id })?.isFinished == true else {
            throw FileOperationError.unsafeOperation("Only finished transfers can be removed from this list.")
        }
        removeQueueSessionRows([id])
    }

    private func removeQueueSessionRows(_ ids: Set<UUID>) {
        queueSessionRecordIDs.subtract(ids)
        queueSessionRecordOrder.removeAll { ids.contains($0) }
        reviewedQueueAttentionIDs.subtract(ids)
        skippedQueueAttentionIDs.subtract(ids)
        ejectedQueueSourceIDs.subtract(ids)
        if let paused = queuePausedRecordID, ids.contains(paused) {
            queuePausedRecordID = nil
            queueMessage = nil
        }
        if let reviewed = reviewedQueueRecordID, ids.contains(reviewed) {
            reviewedQueueRecordID = nil
        }
        if queueSessionRecordIDs.isEmpty {
            clearQueueSessionState()
        } else {
            queueSessionEnded = false
            persistQueueSession()
        }
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
        guard !isOperationInProgress,
              let record = transferJournal.records.first(where: { $0.id == id }) else { return }
        let safety = TransferLibraryPresentation.safetyState(for: record)
        let state: OperationState
        switch safety {
        case .safeToErase: state = .completed(.init(success: true, message: record.summary))
        case .copiedNotVerified: state = .completed(.init(success: false, message: record.summary, copiedNotVerified: true))
        case .needsAttention: state = .completed(.init(success: false, message: record.summary))
        case .failed: state = .failed
        case .interrupted: state = record.state == .cancelled ? .cancelled : .failed
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

    /// Marks an inline row as reviewed without replacing the always-on
    /// composer with an old transfer's selection.
    func markQueueTransferReviewed(_ id: UUID) {
        guard queueSessionRecordIDs.contains(id) else { return }
        reviewedQueueAttentionIDs.insert(id)
        standaloneAttentionRecordIDsSinceLaunch.remove(id)
        persistQueueSession()
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
            && (isReplayingQueuedTransfer || queueIsRunning || queueSessionRecordIDs.count >= 2)
    }

    func retryTransfer(_ id: UUID, generateASCMHL: Bool? = nil) {
        do {
            if let record = transferJournal.records.first(where: { $0.id == id }),
               let projectID = record.projectID,
               let projectCardID = record.projectCardID {
                try photographerJobViewModel.prepareProjectCardForRetry(
                    jobID: projectID,
                    cardID: projectCardID
                )
                usesProjectWorkflow = true
                isReplayingQueuedTransfer = true
                defer { isReplayingQueuedTransfer = false }
                sourceURL = record.source.url
                destinationURLs = record.destinations.map(\.url)
                verificationMode = record.verificationMode
                cameraLabelSettings = record.cameraSettings
                reportSettings = record.reportSettings
                self.generateASCMHL = generateASCMHL ?? record.generateASCMHL
                reviewedQueueRecordID = nil
                queueMessage = nil
                return
            }
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
            queueMessage = "Queue paused. Choose Resume Queue to continue."
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
            // Queued backups were the user's picks; the rule still applies,
            // since a record can predate it.
            if let refusal = access.destinationURLs.lazy.compactMap({
                BackupTargetPolicy.refusal(for: $0, origin: .userChoice, source: access.sourceURL)
            }).first {
                throw FileOperationError.unsafeOperation(refusal)
            }
            currentMode = .copyAndVerify
            photographerReportFinalizer = nil
            activeProjectCardID = nil
            projectRunCameraSettings = nil
            let queuedSourceURL = access.sourceURL
            let sourceManifest = try await Task.detached(priority: .userInitiated) {
                try CardSource.enumerateRegularFiles(base: queuedSourceURL)
            }.value
            // An empty queued card fails its own record and stops the queue
            // (caught below); returning quietly from executeOperation left
            // the queue running with nothing to run.
            guard !sourceManifest.isEmpty else {
                throw FileOperationError.unsafeOperation("Source folder is empty. Choose a source that contains files.")
            }
            let sourceBytes = sourceManifest.reduce(into: Int64(0)) { $0 += max(0, $1.size) }
            let destinationNames = access.destinationURLs.map { DestinationIdentityPresentation.title(for: $0) }
            let independence = await Self.resolveDestinationIndependence(
                destinations: access.destinationURLs,
                names: destinationNames,
                provider: physicalDiskIdentityProvider
            )
            let context = TransferRunContext(
                sourceURL: access.sourceURL,
                destinationURLs: access.destinationURLs,
                verificationMode: record.verificationMode,
                cameraLabelSettings: record.cameraSettings,
                reportSettings: record.reportSettings,
                generateASCMHL: record.generateASCMHL,
                projectID: record.projectID,
                projectCardID: nil,
                journalRecordID: record.id,
                estimatedFiles: sourceManifest.count,
                estimatedBytes: sourceBytes,
                plannedTotalBytes: sourceBytes * Int64(access.destinationURLs.count),
                sourceIsKnownEmpty: sourceManifest.isEmpty,
                independentDestinationCount: independence.independentCopyCount,
                photographerReportFinalizer: nil
            )
            await executeOperation(context)
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

    func startOperation(
        preResolvedIndependence: BackupIndependenceAssessment? = nil
    ) async {
        // Capture every mutable composer input before execution can suspend.
        let runCameraSettings = projectRunCameraSettings ?? cameraLabelSettings
        let projectID = photographerReportFinalizer == nil ? nil : photographerJobViewModel.activeJob?.id
        let projectCardID = photographerReportFinalizer == nil ? nil : activeProjectCardID
        let projectIdentity = projectID.flatMap { jobID in
            projectCardID.map { ProjectRunIdentity(jobID: jobID, cardID: $0) }
        }
        let selectedVerificationMode = verificationMode
        let selectedReportSettings = reportSettings
        let selectedGenerateASCMHL = generateASCMHL
        let selectedReportFinalizer = photographerReportFinalizer
        projectRunCameraSettings = nil
        guard let sourceURL, !destinationURLs.isEmpty else {
            operationState = .failed
            updateProjectLifecycle(for: .failed, projectIdentity: projectIdentity)
            await platformManager.presentAlert(
                title: "Invalid Selection",
                message: "Please select a source folder and at least one destination folder."
            )
            return
        }
        let selectedDestinations = destinationURLs
        let independence: BackupIndependenceAssessment
        if let preResolvedIndependence {
            independence = preResolvedIndependence
        } else {
            independence = await Self.resolveDestinationIndependence(
                destinations: selectedDestinations,
                names: selectedDestinations.map { DestinationIdentityPresentation.title(for: $0) },
                provider: physicalDiskIdentityProvider
            )
        }
        guard self.sourceURL == sourceURL,
              destinationURLs == selectedDestinations,
              verificationMode == selectedVerificationMode else { return }
        destinationIndependence = independence
        let sourceInfo = self.sourceFolderInfo.flatMap {
            $0.url.standardizedFileURL == sourceURL.standardizedFileURL ? $0 : nil
        }
        let context = TransferRunContext(
            sourceURL: sourceURL,
            destinationURLs: destinationURLs,
            verificationMode: selectedVerificationMode,
            cameraLabelSettings: runCameraSettings,
            reportSettings: selectedReportSettings,
            generateASCMHL: selectedGenerateASCMHL,
            projectID: projectID,
            projectCardID: projectCardID,
            journalRecordID: nil,
            estimatedFiles: sourceInfo?.fileCount ?? 100,
            estimatedBytes: sourceInfo?.totalSize ?? 1_000_000_000,
            plannedTotalBytes: sourceInfo.map { $0.totalSize * Int64(destinationURLs.count) },
            sourceIsKnownEmpty: sourceInfo?.fileCount == 0,
            independentDestinationCount: independence.independentCopyCount,
            photographerReportFinalizer: selectedReportFinalizer
        )
        await executeOperation(context)
    }

    /// One live row from the engine while a transfer runs: replaces the row
    /// for the same file and backup, or appends it. Only `liveResults`
    /// announces the change, so the shells observing this coordinator are
    /// not redrawn per file. The engine's authoritative list replaces these
    /// rows through `results` before the verdict is set.
    func receiveLiveResult(_ row: ResultRow) {
        liveResults.upsert(row)
    }

    private func executeOperation(_ initialContext: TransferRunContext) async {
        guard activeStartID == nil, !isOperationInProgress else { return }
        lastOperationWasCompare = false
        guard !initialContext.sourceIsKnownEmpty else {
            operationState = .failed
            updateProjectLifecycle(for: .failed, context: initialContext)
            await platformManager.presentAlert(
                title: "Empty Source",
                message: "Choose a source that contains files."
            )
            return
        }

        let sourceURL = initialContext.sourceURL
        let destinationURLs = initialContext.destinationURLs

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
        let context: TransferRunContext
        do {
            let recordID = try initialContext.journalRecordID ?? transferJournal.enqueue(
                sourceURL: sourceURL, destinationURLs: destinationURLs,
                verificationMode: initialContext.verificationMode,
                cameraSettings: initialContext.cameraLabelSettings,
                reportSettings: initialContext.reportSettings,
                generateASCMHL: initialContext.generateASCMHL,
                projectID: initialContext.projectID,
                projectCardID: initialContext.projectCardID
            )
            try transferJournal.markRunning(
                id: recordID,
                independentDestinationCount: initialContext.independentDestinationCount
            )
            context = initialContext.recording(in: recordID)
            activeJournalRecordID = recordID
            activeRunContext = context
            // Every directly started transfer is a row in the always-visible
            // transfer session. Project cards also keep their dashboard entry.
            if initialContext.journalRecordID == nil {
                queueSessionEnded = false
                addQueueSessionRecord(recordID)
                if let volumeID = transferJournal.records.first(where: { $0.id == recordID })?.source.volumeID {
                    queueSessionSourceVolumeIDs.insert(volumeID)
                }
                persistQueueSession()
            }
        } catch {
            queueIsRunning = false
            let startError = error
            queueMessage = startError.localizedDescription
            if let journalRecordID = initialContext.journalRecordID,
               queueSessionRecordIDs.contains(journalRecordID) {
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
            updateProjectLifecycle(for: .failed, context: initialContext)
            await platformManager.presentError(startError)
            return
        }
        guard let recordID = context.journalRecordID else {
            operationState = .failed
            updateProjectLifecycle(for: .failed, context: context)
            return
        }

        // Validate resolved destination paths before starting. Source-tree and
        // capacity checks run in the file operation after its manifest is built.
        do {
            try SafetyValidator.validateResolvedDestinationRoots(
                source: sourceURL,
                destinations: destinationURLs,
                settings: context.cameraLabelSettings
            )
        } catch {
            try? transferJournal.interrupt(id: recordID, summary: error.localizedDescription)
            if currentTransferBelongsToQueueSession {
                pauseQueueAttempt(recordID: recordID, message: error.localizedDescription)
            } else {
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: false)
            }
            operationState = .failed
            updateProjectLifecycle(for: .failed, context: context)
            await platformManager.presentError(error)
            return
        }

        guard activeStartID == startID, !startCancellationRequested else {
            let belongsToQueueSession = currentTransferBelongsToQueueSession
            queueIsRunning = false
            do {
                if startCancellationRequested {
                    try transferJournal.cancel(id: recordID, summary: "Cancelled by user (\(cancellationOrigin.rawValue)).", results: [])
                    SharedLogger.transferEvent(.journalCancelled, run: startID, explicit: true)
                } else {
                    try transferJournal.interrupt(id: recordID, summary: "Transfer interrupted before admission.", results: [])
                    SharedLogger.transferEvent(.journalInterrupted, run: startID)
                }
                handleAttemptTerminal(
                    recordID: recordID,
                    belongsToQueueSession: belongsToQueueSession
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
        presentedDestinationCount = context.destinationURLs.count

        let runResults = TransferRunResults()
        let projectIdentity = context.projectIdentity
        let runBelongsToQueueSession = currentTransferBelongsToQueueSession
        let config = CopyVerifyConfig(
            operationId: startID,
            sourceURL: context.sourceURL,
            destinationURLs: context.destinationURLs,
            verificationMode: context.verificationMode,
            cameraLabelSettings: context.cameraLabelSettings,
            reportSettings: context.reportSettings,
            estimatedFiles: context.estimatedFiles,
            estimatedBytes: context.estimatedBytes,
            currentMode: .copyAndVerify,
            photographerReportFinalizer: context.photographerReportFinalizer,
            generateASCMHL: context.generateASCMHL,
            // Screenshot seam (`-BitMatchDemoSlow`): non-nil only for the
            // demo seeder's own records on a flagged DEBUG launch; nil
            // everywhere else, and always nil in Release.
            fanOutHooks: demoFanOutHooks(for: context.journalRecordID)
        )

        let callbacks = CopyVerifyCallbacks(
            onProgress: { [weak self] progressUpdate in
                guard let self,
                      self.activeStartID == startID,
                      !self.startCancellationRequested else { return }
                self.progress = progressUpdate
                if let projectIdentity {
                    self.photographerJobViewModel.updateProgressStage(
                        progressUpdate.currentStage,
                        jobID: projectIdentity.jobID,
                        cardID: projectIdentity.cardID
                    )
                }
            },
            onResult: { [weak self] result in
                guard let self,
                      self.activeStartID == startID,
                      !self.startCancellationRequested else { return }
                runResults.upsert(result)
                self.receiveLiveResult(result)
            },
            onStateChange: { [weak self] state in
                guard let self,
                      self.activeStartID == startID,
                      !self.startCancellationRequested else { return }
                self.operationState = state
                self.updateProjectLifecycle(for: state, projectIdentity: projectIdentity)
            },
            onAuthoritativeResults: { [weak self] allResults in
                guard let self else {
                    SharedLogger.transferEvent(.authoritativeRefused, run: startID, code: TransferInterruption.ownerReleased.rawValue)
                    throw TransferInterruption.ownerReleased
                }
                guard self.activeStartID == startID else {
                    SharedLogger.transferEvent(.authoritativeRefused, run: startID, code: TransferInterruption.runSuperseded.rawValue)
                    throw TransferInterruption.runSuperseded
                }
                guard !self.startCancellationRequested else {
                    SharedLogger.transferEvent(.authoritativeRefused, run: startID, code: 3, explicit: true)
                    throw CancellationError()
                }
                SharedLogger.transferEvent(.authoritativeAccepted, run: startID)
                runResults.replace(with: allResults)
                self.results = allResults
            }
        )

        // The engine and journal now own immutable copies of the active
        // selection. Clear only the one-time source so Setup becomes the
        // composer for the next card while this operation continues. Keep
        // destinations as the convenient default for that next snapshot.
        if context.photographerReportFinalizer == nil && initialContext.journalRecordID == nil {
            isClearingSnapshottedComposerSource = true
            cameraLabels.clearDetectionPreservingSettings()
            self.sourceURL = nil
            isClearingSnapshottedComposerSource = false
        }

        do {
            currentOperation = try await copyVerifyExecutor.execute(config: config, callbacks: callbacks)
            let belongsToQueueSession = runBelongsToQueueSession
            if startCancellationRequested {
                try transferJournal.cancel(id: recordID, summary: "Cancelled by user (\(cancellationOrigin.rawValue)).", results: runResults.rows)
                SharedLogger.transferEvent(.journalCancelled, run: startID, explicit: true)
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: belongsToQueueSession)
            } else if case .completed(let info) = operationState {
                let durations = copyVerifyExecutor.completedPhaseDurations
                try transferJournal.finish(
                    id: recordID,
                    results: runResults.rows,
                    summary: info.message,
                    hadIssues: !info.success,
                    copyDurationSeconds: durations.copySeconds,
                    verifyDurationSeconds: durations.verifySeconds,
                    performanceTelemetry: copyVerifyExecutor.completedPerformanceTelemetry,
                    sourceFingerprint: currentOperation?.sourceFingerprint
                )
                SharedLogger.transferEvent(.journalFinished, run: startID)
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: belongsToQueueSession)
            } else {
                try transferJournal.interrupt(id: recordID, summary: "Transfer did not reach verified completion.", results: runResults.rows)
                SharedLogger.transferEvent(.journalInterrupted, run: startID)
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: belongsToQueueSession)
            }
        } catch {
            let belongsToQueueSession = runBelongsToQueueSession
            queueIsRunning = false
            do {
                if startCancellationRequested {
                    try transferJournal.cancel(id: recordID, summary: "Cancelled by user (\(cancellationOrigin.rawValue)).", results: runResults.rows)
                    SharedLogger.transferEvent(.journalCancelled, run: startID, explicit: true)
                } else {
                    let summary = error is CancellationError || error is TransferInterruption
                        ? "Transfer interrupted unexpectedly; partial results retained. Keep source media intact."
                        : error.localizedDescription
                    try transferJournal.interrupt(id: recordID, summary: summary, results: runResults.rows)
                    SharedLogger.transferEvent(.journalInterrupted, run: startID, code: (error as NSError).code,
                                               taskCancelled: Task.isCancelled)
                }
                handleAttemptTerminal(recordID: recordID, belongsToQueueSession: belongsToQueueSession)
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
                ended: queueSessionEnded,
                started: queueSessionStarted
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
        queueSessionStarted = false
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
        if queueSessionRecordIDs.contains(id) {
            reviewedQueueAttentionIDs.insert(id)
            persistQueueSession()
        }
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
        let selectedDestinations = destinationURLs
        let independence = await Self.resolveDestinationIndependence(
            destinations: selectedDestinations,
            names: selectedDestinations.map { DestinationIdentityPresentation.title(for: $0) },
            provider: physicalDiskIdentityProvider
        )
        guard destinationURLs == selectedDestinations else { return false }
        destinationIndependence = independence
        guard activeStartID == nil, !isOperationInProgress,
              operationReadinessAssessment.isReady,
              photographerJobViewModel.hasPreparedIngestAwaitingStart,
              let jobID = photographerJobViewModel.activeJob?.id,
              let cardID = photographerJobViewModel.activeCard?.id,
              photographerJobViewModel.preliminaryAnalysis != nil else {
            return false
        }
        guard photographerJobViewModel.beginIngest(
            destinationCount: destinationIndependence.independentCopyCount,
            sourceURL: sourceURL,
            verificationMode: verificationMode
        ) else {
            return false
        }

        let analysis = photographerJobViewModel.preliminaryAnalysis
        let independentDestinationCount = destinationIndependence.independentCopyCount
        photographerReportFinalizer = { [weak photographerJobViewModel, jobID, cardID, analysis, independentDestinationCount] results in
            guard let photographerJobViewModel, let analysis,
                  let state = photographerJobViewModel.projectCardState(jobID: jobID, cardID: cardID),
                  state == .copying || state == .verifying else {
                throw PhotographerReportError.cardNotReady
            }
            return try photographerJobViewModel.completeIngest(
                jobID: jobID,
                cardID: cardID,
                analysis: analysis,
                results: results,
                independentDestinationCount: independentDestinationCount
            )
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
        await startOperation(preResolvedIndependence: independence)
        // Every terminal state clears `activeProjectCardID`. A start that
        // returned without one must not leave the card copying.
        if activeProjectCardID == cardID, !isOperationInProgress {
            photographerJobViewModel.operationFailed()
            activeProjectCardID = nil
            photographerReportFinalizer = nil
        }
        return true
    }

    func cancelOperation(origin: TransferCancelOrigin = .user) {
        cancellationOrigin = origin
        SharedLogger.cancelEvent(origin, run: activeStartID)
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
    func cancelOperationAndWaitForSettlement(origin: TransferCancelOrigin = .user) async throws {
        let startID = activeStartID
        let recordID = activeJournalRecordID

        guard startID != nil || isOperationInProgress || queueIsRunning else { return }
        // The queue can be between records: stopping it is already settled,
        // and no journal record is currently running.
        guard startID != nil || isOperationInProgress else {
            queueIsRunning = false
            return
        }
        cancelOperation(origin: origin)

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
        
        // Pause the active engine operation.
        if currentMode == .compareFolders {
            comparisonCoordinator.pause()
        } else {
            await platformManager.fileOperations.pauseOperation()
        }

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
        
        // Resume the active engine operation.
        if currentMode == .compareFolders {
            comparisonCoordinator.resume()
        } else {
            await platformManager.fileOperations.resumeOperation()
        }
        
        // Update state service
        if stateService.resumeOperation() {
            operationState = stateService.currentState
            
            // Update capabilities
            stateService.updateCapabilities(canPause: true, canResume: false)
            SharedLogger.info("Operation resumed", category: .transfer)
        }
    }
    
    private func updateProjectLifecycle(for state: OperationState) {
        updateProjectLifecycle(for: state, projectIdentity: activeRunContext?.projectIdentity)
    }

    private func updateProjectLifecycle(for state: OperationState, context: TransferRunContext) {
        updateProjectLifecycle(for: state, projectIdentity: context.projectIdentity)
    }

    private func updateProjectLifecycle(for state: OperationState, projectIdentity: ProjectRunIdentity?) {
        guard let jobID = projectIdentity?.jobID, let cardID = projectIdentity?.cardID else { return }
        switch state {
        case .verifying:
            photographerJobViewModel.updateProgressStage(.verifying, jobID: jobID, cardID: cardID)
        case .completed(let info):
            if !info.success { photographerJobViewModel.operationFailed(jobID: jobID, cardID: cardID) }
            activeProjectCardID = nil
            photographerReportFinalizer = nil
        case .failed:
            photographerJobViewModel.operationFailed(jobID: jobID, cardID: cardID)
            activeProjectCardID = nil
            photographerReportFinalizer = nil
        case .cancelled:
            photographerJobViewModel.cancelIngest(jobID: jobID, cardID: cardID)
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
        if checkAgainst == .savedChecksums {
            await checkSavedChecksums()
            return
        }
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
        let operationID = UUID()
        isOperationInProgress = true
        lastOperationWasCompare = true
        stateService.startOperation(
            id: operationID,
            sourceURL: left,
            destinationURLs: [right],
            totalFiles: leftFolderInfo?.fileCount ?? 0,
            totalBytes: leftFolderInfo?.totalSize ?? 0,
            verificationMode: comparedMode.rawValue,
            mode: "check"
        )
        stateService.updateCapabilities(canPause: true, canResume: false)
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
                stateService.cancelOperation(operationId: operationID)
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
            stateService.completeOperation(
                operationId: operationID,
                info: OperationCompletionInfo(success: stats.isClean && verifiesContents, message: message)
            )
            return
        } catch is CancellationError {
            isOperationInProgress = false
            if comparisonCoordinator.isCancellationRequested {
                stateService.cancelOperation(operationId: operationID)
                lastCompareEnd = .cancelled
            } else {
                SharedLogger.transferEvent(.parentCancelled, run: operationID, taskCancelled: Task.isCancelled)
                stateService.failOperation(operationId: operationID)
                lastCompareEnd = .failed("Comparison interrupted unexpectedly.")
            }
            return
        } catch {
            isOperationInProgress = false
            stateService.failOperation(operationId: operationID)
            lastCompareEnd = .failed(error.localizedDescription)
            await platformManager.presentError(error)
            return
        }
    }

    private func checkSavedChecksums() async {
        guard let root = leftURL,
              let discovery = savedChecksumDiscovery,
              discovery.root.path == root.standardizedFileURL.resolvingSymlinksKeepingCase().path,
              !isOperationInProgress else { return }

        let operationID = UUID()
        isOperationInProgress = true
        lastOperationWasCompare = true
        stateService.startOperation(
            id: operationID,
            sourceURL: root,
            destinationURLs: [],
            totalFiles: discovery.expectedFiles.count,
            totalBytes: 0,
            verificationMode: "saved-checksums",
            mode: "check"
        )
        stateService.updateCapabilities(canPause: true, canResume: false)
        results = []
        clearCompareOutcome()
        errorService.clearCurrentErrors()
        progress = OperationProgress(
            overallProgress: 0,
            currentFile: nil,
            filesProcessed: 0,
            totalFiles: discovery.expectedFiles.count,
            currentStage: .preparing,
            speed: nil
        )

        do {
            let result = try await comparisonCoordinator.checkSavedChecksums(
                discovery: discovery,
                onProgress: { [weak self] in self?.progress = $0 }
            )
            if Task.isCancelled || comparisonCoordinator.isCancellationRequested { throw CancellationError() }
            guard leftURL == root, checkAgainst == .savedChecksums else {
                isOperationInProgress = false
                stateService.cancelOperation(operationId: operationID)
                operationState = .notStarted
                progress = nil
                return
            }
            lastSavedChecksumResult = result
            lastCompareEnd = .completed
            isOperationInProgress = false
            let message = result.isIntact
                ? "\(root.lastPathComponent) still matches"
                : "Saved checksum check found \(result.changedPaths.count) changed and \(result.missingPaths.count) missing files"
            stateService.completeOperation(
                operationId: operationID,
                info: OperationCompletionInfo(success: result.isIntact, message: message)
            )
        } catch is CancellationError {
            isOperationInProgress = false
            if comparisonCoordinator.isCancellationRequested {
                stateService.cancelOperation(operationId: operationID)
                lastCompareEnd = .cancelled
            } else {
                SharedLogger.transferEvent(.parentCancelled, run: operationID, taskCancelled: Task.isCancelled)
                stateService.failOperation(operationId: operationID)
                lastCompareEnd = .failed("Comparison interrupted unexpectedly.")
            }
        } catch {
            isOperationInProgress = false
            stateService.failOperation(operationId: operationID)
            lastCompareEnd = .failed(error.localizedDescription)
            await platformManager.presentError(error)
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

    /// The active journal record used by transfer menu policy and presentation
    /// adapters. Nil after `resetForNewOperation()`.
    var outcomeRecord: LocalTransferRecord? {
        guard let id = activeJournalRecordID else { return nil }
        return transferJournal.records.first { $0.id == id }
    }

    /// "New transfer" on the outcome screen, on every platform (decision
    /// O-1): the next card usually goes to the same backups, and keeping the
    /// old source risks copying the same card again by accident.
    func startNewTransfer() {
        // A stopped queue with cards still waiting keeps its session, or
        // those cards would be stranded without a Resume Queue action.
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
        activeRunContext = nil
    }

    func saveVerificationMode() {
        guard !isReplayingQueuedTransfer else { return }
        defaults.set(verificationMode.rawValue, forKey: "lastVerificationMode")
    }

    // MARK: - Computed Properties

    var canStartOperation: Bool {
        guard !hasUnresolvedQueueRecords else { return false }
        switch currentMode {
        case .copyAndVerify:
            return operationReadinessAssessment.isReady && !isOperationInProgress
        case .compareFolders:
            guard let leftURL, !isOperationInProgress else { return false }
            if checkAgainst == .savedChecksums {
                return savedChecksumDiscovery != nil && savedChecksumAvailability.hasRecords
            }
            guard let rightURL else { return false }
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
    
    // MARK: - Folder Info Computed Properties

    func getFolderInfo(for url: URL) -> EnhancedFolderInfo? {
        return folderInfoService.getFolderInfo(for: url)
    }

    func isFolderInfoLoading(for url: URL) -> Bool {
        return folderInfoService.isFolderInfoLoading(for: url)
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
        let independence = destinationIndependence
        return TransferReadiness.assess(
            source: sourceURL,
            sourceFileCount: sourceFolderInfo?.fileCount,
            sourceBytes: sourceFolderInfo?.totalSize,
            isAnalysingSource: isAnalysingSource,
            destinations: destinationURLs,
            settings: cameraLabelSettings,
            verificationMode: verificationMode,
            sourceIssue: folderInfoService.sourceScanError,
            destinationWarnings: independence.warnings,
            availableBytes: { self.getDriveCapacity(for: $0) },
            isWritable: TransferReadiness.isWritableFolder
        )
    }

    var alreadyBackedUpLine: String? {
        guard let fingerprint = folderInfoService.sourceFingerprint,
              let record = transferJournal.matchingVerifiedRecord(sourceFingerprint: fingerprint),
              let endedAt = record.endedAt else { return nil }
        let names = record.destinations.map { DestinationIdentityPresentation.title(for: $0.url) }
        return Self.priorBackupLine(destinationNames: names, endedAt: endedAt)
    }

    static func priorBackupLine(
        destinationNames names: [String],
        endedAt: Date,
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDate(endedAt, equalTo: now, toGranularity: .year)
            ? "MMM d"
            : "MMM d, yyyy"
        return "Backed up before to \(Self.joinedNames(names)) on \(formatter.string(from: endedAt))"
    }

    private static func joinedNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return "a verified destination"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and \(names.last ?? "")"
        }
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
