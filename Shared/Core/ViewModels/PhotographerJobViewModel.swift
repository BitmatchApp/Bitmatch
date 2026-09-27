import Combine
import Foundation
import BitMatchEngine

struct DuplicateCardWarning: Equatable, Sendable {
    let jobID: UUID
    let cardIngestID: UUID
    let fingerprint: String
    let message: String

    var priorJobID: UUID { jobID }
    var priorCardIngestID: UUID { cardIngestID }
}

enum FolderLayerMoveDirection: Sendable {
    case up
    case down
}

@MainActor
final class PhotographerJobViewModel: ObservableObject {
    typealias PreliminaryAnalyzer = @Sendable ([FileEntry]) throws -> CardAnalysis
    typealias ConfirmedAnalyzer = @Sendable ([ResultRow]) throws -> String
    typealias EntryEnumerator = @Sendable (URL) throws -> [FileEntry]

    @Published private(set) var jobs: [PhotographerJob] = []
    @Published private(set) var presets: [PhotographerPreset] = []
    @Published private(set) var remoteProfiles: [RemoteDestinationProfile] = []
    @Published var activeJob: PhotographerJob?
    @Published var selectedPhotographerID: UUID?
    @Published var cameraName = ""
    @Published private(set) var activeCardDraft: CardIngest?
    @Published private(set) var renderedRecipe: RenderedFolderRecipe?
    @Published private(set) var preliminaryAnalysis: CardAnalysis?
    @Published private(set) var duplicateWarning: DuplicateCardWarning?
    @Published private(set) var lastError: String?
    @Published var draftRecipe = FolderRecipe.wedding
    @Published private(set) var selectedWorkflow: ProjectWorkflow = .photography
    @Published var focusedCardIngestID: UUID?
    @Published private(set) var dashboardJobID: UUID?
    @Published private(set) var isPreparing = false
    @Published private(set) var preparationError: String?

    var activeCard: CardIngest? {
        guard let id = activeCardDraft?.id else { return nil }
        return activeJob?.cardIngests.first { $0.id == id }
    }

    func projectCardState(jobID: UUID, cardID: UUID) -> PhotographerLocalState? {
        jobForRun(jobID)?.cardIngests.first(where: { $0.id == cardID })?.localState
    }

    /// A photographer card changes the transfer contract only while it is
    /// deliberately prepared and waiting to begin. Completed or failed cards
    /// remain visible in the dashboard, but never block ordinary transfers.
    var hasPreparedIngestAwaitingStart: Bool {
        activeCard?.localState == .notStarted
    }

    /// A project type describes the evidence already recorded for its media.
    /// It remains editable until the first package is prepared.
    var isWorkflowLocked: Bool {
        !(activeJob?.cardIngests.isEmpty ?? true)
    }

    var dashboardJob: PhotographerJob? {
        guard let dashboardJobID else { return activeJob }
        if activeJob?.id == dashboardJobID { return activeJob }
        return jobs.first { $0.id == dashboardJobID }
    }

    private let store: any PhotographerJobStore
    private let now: () -> Date
    private let preliminaryAnalyzer: PreliminaryAnalyzer
    private let confirmedAnalyzer: ConfirmedAnalyzer
    private let entryEnumerator: EntryEnumerator
    private let remoteBackupCoordinator: any ProjectRemoteCoordinator
    private var preparedSourcePath: String?
    private var currentSourcePath: String?
    private var preparedSetupSignature: PhotographerSetupSignature?
    private var currentSetupSignature: PhotographerSetupSignature?
    private var sourcePreparationInvalidated = false
    private var setupPreparationInvalidated = false
    private var setupTask: Task<Void, Never>?
    private var setupGeneration = UUID()

    init(
        store: any PhotographerJobStore,
        now: @escaping () -> Date = Date.init,
        preliminaryAnalyzer: @escaping PreliminaryAnalyzer = { try PhotographerCardAnalyzer.preliminaryAnalysis(entries: $0) },
        confirmedAnalyzer: @escaping ConfirmedAnalyzer = { try PhotographerCardAnalyzer.confirmedFingerprint(results: $0) },
        entryEnumerator: @escaping EntryEnumerator = { try CardSource.enumerateRegularFiles(base: $0) },
        remoteBackupCoordinator: (any ProjectRemoteCoordinator)? = nil,
        workflowDefaults: UserDefaults = .standard
    ) {
        self.store = store
        self.workflowDefaults = workflowDefaults
        self.now = now
        self.preliminaryAnalyzer = preliminaryAnalyzer
        self.confirmedAnalyzer = confirmedAnalyzer
        self.entryEnumerator = entryEnumerator
        #if os(macOS)
        self.remoteBackupCoordinator = remoteBackupCoordinator ?? RemoteBackupCoordinator(store: store)
        #else
        self.remoteBackupCoordinator = remoteBackupCoordinator ?? UnavailableRemoteProjectCoordinator(store: store)
        #endif
        loadJobs()
        loadPresets()
        loadRemoteProfiles()
        if !store.isAvailable {
            store.whenAvailable { [weak self] in
                guard let self else { return }
                self.loadJobs()
                self.loadPresets()
                self.loadRemoteProfiles()
            }
        }
    }

    func createWeddingJob(clientName: String, jobName: String, eventDate: Date) {
        let timestamp = now()
        let job = PhotographerJob(
            id: UUID(),
            eventDate: eventDate,
            clientName: clientName,
            jobName: jobName,
            eventType: .wedding,
            photographers: [],
            recipe: draftRecipe,
            requiredLocalCopyCount: 2,
            cardIngests: [],
            workflow: selectedWorkflow,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        do {
            try persistThrowing(job)
            clearCardPreparation()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private let workflowDefaults: UserDefaults
    nonisolated static let lastWorkflowKey = "BitMatchLastProjectWorkflow"

    /// Most people use one project type: the last one chosen, or the first
    /// option on a first launch. An open project's own workflow still wins.
    private var rememberedWorkflow: ProjectWorkflow {
        workflowDefaults.string(forKey: Self.lastWorkflowKey)
            .flatMap(ProjectWorkflow.init(rawValue:)) ?? ProjectWorkflow.allCases[0]
    }

    func selectWorkflow(_ workflow: ProjectWorkflow) {
        guard selectedWorkflow != workflow else { return }

        guard !isWorkflowLocked else {
            preparationError = "Project type is fixed after the first media package is prepared."
            return
        }
        selectedWorkflow = workflow
        workflowDefaults.set(workflow.rawValue, forKey: Self.lastWorkflowKey)
        draftRecipe = workflow.defaultRecipe
        setupPreparationInvalidated = true
        setupTask?.cancel()
        setupTask = nil
        isPreparing = false
        activeCardDraft = nil
        renderedRecipe = nil
        preliminaryAnalysis = nil
        preparationError = nil

        if var job = activeJob {
            job.workflow = workflow
            job.recipe = draftRecipe
            do {
                try persistThrowing(job)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func prepareCard(
        photographerName: String,
        cameraName: String,
        sourceDisplayName: String? = nil,
        analysis: CardAnalysis
    ) throws {
        guard var job = activeJob else {
            throw PhotographerJobViewModelError.noActiveJob
        }

        let photographer = identity(named: photographerName, in: job)
        if !job.photographers.contains(where: { $0.id == photographer.id }) {
            job.photographers.append(photographer)
        }

        let pendingIndex = activeCardDraft.flatMap { draft in
            job.cardIngests.firstIndex { $0.id == draft.id && $0.localState == .notStarted }
        }
        let pendingCard = pendingIndex.map { job.cardIngests[$0] }
        let cardNumber = pendingCard?.provenance.cardNumber
            ?? nextCardNumber(cameraName: cameraName, in: job)
        let rendered = try FolderRecipeRenderer.render(
            job.recipe,
            context: FolderRecipeContext(
                eventDate: job.eventDate,
                jobName: job.jobName,
                photographer: photographer.name,
                camera: cameraName,
                cardNumber: cardNumber
            )
        )
        if job.cardIngests.contains(where: { card in
            card.id != pendingCard?.id
                && portablePackageRoute(card.renderedRelativePath)
                    == portablePackageRoute(rendered.relativePath)
        }) {
            throw PhotographerJobViewModelError.duplicatePackageRoute(rendered.relativePath)
        }
        let warning = duplicateWarning(
            for: analysis.fingerprint,
            excludingCardID: pendingCard?.id
        )
        let card = CardIngest(
            id: pendingCard?.id ?? UUID(),
            provenance: CardProvenance(
                photographerID: photographer.id,
                photographerName: photographer.name,
                cameraName: cameraName,
                cardNumber: cardNumber,
                preliminaryFingerprint: analysis.fingerprint,
                confirmedFingerprint: nil
            ),
            sourceDisplayName: sourceDisplayName ?? "Card " + String(cardNumber),
            renderedRelativePath: rendered.relativePath,
            localState: .notStarted,
            startedAt: nil,
            locallySafeAt: nil,
            fileCount: analysis.fileCount,
            totalBytes: analysis.totalBytes
        )

        if let pendingIndex {
            job.cardIngests[pendingIndex] = card
        } else {
            job.cardIngests.append(card)
        }
        try persistThrowing(job)
        selectedPhotographerID = photographer.id
        self.cameraName = cameraName
        activeCardDraft = card
        renderedRecipe = rendered
        preliminaryAnalysis = analysis
        duplicateWarning = warning
        let signature = PhotographerSetupSignature(
            clientName: job.clientName,
            jobName: job.jobName,
            eventDate: job.eventDate,
            photographerName: photographer.name,
            cameraName: cameraName,
            cardNumber: cardNumber,
            recipe: job.recipe
        )
        currentSetupSignature = signature
        preparedSetupSignature = signature
    }

    func prepareCard(
        photographerName: String,
        cameraName: String,
        sourceURL: URL,
        setupSignature: PhotographerSetupSignature,
        analysis: CardAnalysis
    ) throws {
        currentSetupSignature = setupSignature
        currentSourcePath = standardizedPath(sourceURL)
        try prepareCard(
            photographerName: photographerName,
            cameraName: cameraName,
            sourceDisplayName: sourceURL.lastPathComponent,
            analysis: analysis
        )
        preparedSourcePath = standardizedPath(sourceURL)
        let actualSignature = preparedSetupSignature ?? setupSignature
        preparedSetupSignature = actualSignature
        currentSetupSignature = actualSignature
        sourcePreparationInvalidated = false
        setupPreparationInvalidated = false
    }

    func prepareDraftCard(
        clientName: String,
        jobName: String,
        eventDate: Date,
        photographerName: String,
        cameraName: String,
        sourceDisplayName: String,
        entries: [FileEntry]
    ) throws {
        if var job = activeJob,
           job.clientName == clientName,
           job.jobName == jobName,
           job.eventDate == eventDate,
           job.eventType == .wedding {
            job.recipe = draftRecipe
            job.workflow = selectedWorkflow
            try persistThrowing(job)
        } else {
            createWeddingJob(clientName: clientName, jobName: jobName, eventDate: eventDate)
        }
        try prepareCard(
            photographerName: photographerName,
            cameraName: cameraName,
            sourceDisplayName: sourceDisplayName,
            entries: entries
        )
    }

    func startPreparingDraftCard(sourceURL: URL, setupSignature: PhotographerSetupSignature) {
        guard !isPreparing else { return }
        setupTask?.cancel()
        let generation = UUID()
        setupGeneration = generation
        isPreparing = true
        preparationError = nil
        currentSetupSignature = setupSignature
        let enumerator = entryEnumerator
        let analyzer = preliminaryAnalyzer
        let standardizedSource = sourceURL.standardizedFileURL
        currentSourcePath = standardizedPath(standardizedSource)
        setupTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    let entries = try enumerator(standardizedSource)
                    try Task.checkCancellation()
                    return Result<CardAnalysis, Error>.success(try analyzer(entries))
                } catch {
                    return .failure(error)
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, self.setupGeneration == generation else { return }
            self.isPreparing = false
            self.setupTask = nil
            guard self.currentSetupSignature == setupSignature,
                  self.standardizedPath(standardizedSource) == self.currentSourcePath else { return }
            switch result {
            case .success(let analysis):
                do {
                    try self.prepareDraftCard(analysis: analysis, sourceURL: standardizedSource, setupSignature: setupSignature)
                    self.preparationError = nil
                } catch {
                    self.preparationError = error.localizedDescription
                }
            case .failure(let error):
                if !(error is CancellationError) { self.preparationError = error.localizedDescription }
            }
        }
    }

    /// Stops the current source enumeration/analysis without changing the
    /// photographer's setup fields. Any late worker result is ignored.
    func cancelPreparingDraftCard() {
        guard isPreparing else { return }

        setupGeneration = UUID()
        setupTask?.cancel()
        setupTask = nil
        isPreparing = false
        preparationError = nil
    }

    private func prepareDraftCard(
        analysis: CardAnalysis,
        sourceURL: URL,
        setupSignature: PhotographerSetupSignature
    ) throws {
        if var job = activeJob, activeCard?.localState == .notStarted {
            job.clientName = setupSignature.clientName
            job.jobName = setupSignature.jobName
            job.eventDate = setupSignature.eventDate
            job.eventType = .wedding
            job.recipe = setupSignature.recipe
            job.workflow = selectedWorkflow
            try persistThrowing(job)
        } else if var job = activeJob,
                  job.clientName == setupSignature.clientName,
                  job.jobName == setupSignature.jobName,
                  job.eventDate == setupSignature.eventDate,
                  job.eventType == .wedding {
            job.recipe = setupSignature.recipe
            job.workflow = selectedWorkflow
            try persistThrowing(job)
        } else {
            draftRecipe = setupSignature.recipe
            createWeddingJob(clientName: setupSignature.clientName, jobName: setupSignature.jobName, eventDate: setupSignature.eventDate)
        }
        try prepareCard(
            photographerName: setupSignature.photographerName,
            cameraName: setupSignature.cameraName,
            sourceURL: sourceURL,
            setupSignature: setupSignature,
            analysis: analysis
        )
    }

    func waitForSetupForTesting() async {
        let task = setupTask
        await task?.value
    }

    func proposedCardNumber(cameraName: String) -> Int {
        if let activeCardDraft {
            return activeCardDraft.provenance.cardNumber
        }
        guard let activeJob else { return 1 }
        return nextCardNumber(cameraName: cameraName, in: activeJob)
    }

    func prepareCard(
        photographerName: String,
        cameraName: String,
        sourceDisplayName: String? = nil,
        entries: [FileEntry]
    ) throws {
        try prepareCard(
            photographerName: photographerName,
            cameraName: cameraName,
            sourceDisplayName: sourceDisplayName,
            analysis: preliminaryAnalyzer(entries)
        )
    }

    @discardableResult
    func beginIngest(
        destinationCount: Int,
        sourceURL: URL? = nil,
        verificationMode: VerificationMode = .standard
    ) -> Bool {
        guard activeJob != nil else { return false }
        let presentation = startPresentation(
            preflightReady: true,
            sourceURL: sourceURL,
            destinationCount: destinationCount,
            verificationMode: verificationMode
        )
        guard presentation.canStart else {
            lastError = presentation.blocker
            return false
        }
        transitionActiveCard(to: .copying) { card in
            if card.startedAt == nil { card.startedAt = self.now() }
            card.locallySafeAt = nil
        }
        lastError = nil
        return activeCard?.localState == .copying
    }

    func updateSetupSignature(_ signature: PhotographerSetupSignature) {
        if let preparedSetupSignature, preparedSetupSignature != signature {
            setupPreparationInvalidated = true
        }
        currentSetupSignature = signature
    }

    func sourceDidChange(to sourceURL: URL?) {
        let newPath = sourceURL.map(standardizedPath)
        currentSourcePath = newPath
        if let preparedSourcePath, preparedSourcePath != newPath {
            sourcePreparationInvalidated = true
        }
        if isPreparing || (preparedSourcePath != nil && preparedSourcePath != newPath) {
            setupGeneration = UUID()
            setupTask?.cancel()
            isPreparing = false
        }
    }

    func startPresentation(
        preflightReady: Bool,
        sourceURL: URL?,
        destinationCount: Int,
        verificationMode: VerificationMode = .standard
    ) -> PhotographerStartPresentation {
        let sourceMatches = !sourcePreparationInvalidated && (preparedSourcePath == sourceURL.map(standardizedPath)
            || (preparedSourcePath == nil && sourceURL == nil)
        )
        return PhotographerStartPresentation.make(context: PhotographerStartContext(
            preflightReady: preflightReady,
            isPreparing: isPreparing,
            activeCardState: activeCard?.localState,
            sourceMatches: sourceMatches,
            setupMatches: !setupPreparationInvalidated
                && preparedSetupSignature != nil
                && preparedSetupSignature == currentSetupSignature,
            destinationCount: destinationCount,
            requiredDestinationCount: activeJob?.requiredLocalCopyCount ?? 0,
            verificationMode: verificationMode
        ))
    }

    func isStartEligible(
        preflightReady: Bool,
        sourceURL: URL?,
        destinationCount: Int,
        verificationMode: VerificationMode = .standard
    ) -> Bool {
        startPresentation(
            preflightReady: preflightReady,
            sourceURL: sourceURL,
            destinationCount: destinationCount,
            verificationMode: verificationMode
        ).canStart
    }

    func updateProgressStage(_ stage: ProgressStage) {
        guard let jobID = activeJob?.id, let cardID = activeCardDraft?.id else { return }
        updateProgressStage(stage, jobID: jobID, cardID: cardID)
    }

    func updateProgressStage(_ stage: ProgressStage, jobID: UUID, cardID: UUID) {
        switch stage {
        case .copying:
            transitionCard(jobID: jobID, cardID: cardID, to: .copying) { card in
                if card.startedAt == nil { card.startedAt = self.now() }
            }
        case .verifying:
            transitionCard(jobID: jobID, cardID: cardID, to: .verifying)
        default:
            break
        }
    }

    func operationFailed() {
        guard let jobID = activeJob?.id, let cardID = activeCardDraft?.id else { return }
        operationFailed(jobID: jobID, cardID: cardID)
    }

    func operationFailed(jobID: UUID, cardID: UUID) {
        do {
            try transitionCardThrowing(jobID: jobID, cardID: cardID, to: .issues) { card in
                card.locallySafeAt = nil
                card.provenance.confirmedFingerprint = nil
                card.verifiedDestinationCount = 0
            }
        } catch {
            forceCardIntoIssuesInMemory(jobID: jobID, cardID: cardID)
            lastError = error.localizedDescription
        }
    }

    /// Remote controls deliberately update only remote configuration and
    /// summaries. A remote error must never invalidate local copy evidence.
    func selectRemoteProfile(_ profileID: UUID?) {
        guard let jobID = activeJob?.id else {
            lastError = ProjectRemoteCoordinatorError.missingJob.errorDescription
            return
        }
        do {
            let updatedJob = try remoteBackupCoordinator.selectRemoteProfile(profileID, for: jobID)
            replaceLoadedJob(updatedJob)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveRemoteProfile(_ profile: RemoteDestinationProfile) {
        do {
            try store.save(profile)
            loadRemoteProfiles()
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func deleteRemoteProfile(id: UUID) {
        do {
            try store.deleteProfile(id: id)
            if activeJob?.remoteBackupConfiguration?.destinationProfileID == id { selectRemoteProfile(nil) }
            loadRemoteProfiles()
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    func setRemoteFeedback(_ message: String) { lastError = message }

    @discardableResult
    func queueRemoteBackup(for cardIngestID: UUID, results: [ResultRow]) throws -> [RemoteQueueItem] {
        guard let jobID = activeJob?.id else { throw PhotographerJobViewModelError.noActiveJob }
        do {
            let items = try remoteBackupCoordinator.queueRemoteBackup(
                for: cardIngestID,
                in: jobID,
                results: results
            )
            try updateRemoteSummary(for: cardIngestID, items: items)
            lastError = nil
            return items
        } catch {
            // Do not call operationFailed(): the local verdict was produced
            // by the authoritative local operation and remains unchanged.
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Queue workers persist the authoritative remote state. Rebuild the card
    /// summary from those durable items after a run without touching local
    /// safety evidence.
    func refreshRemoteBackupSummary(for cardIngestID: UUID, items: [RemoteQueueItem]) {
        do {
            try updateRemoteSummary(for: cardIngestID, items: items)
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func completeIngest(results: [ResultRow]) throws -> PhotographerFinalizationResult {
        guard let jobID = activeJob?.id, let cardID = activeCardDraft?.id else {
            throw PhotographerJobViewModelError.noActiveCard
        }
        guard let preliminaryAnalysis else { throw PhotographerJobViewModelError.missingPreliminaryAnalysis }
        return try completeIngest(
            jobID: jobID,
            cardID: cardID,
            analysis: preliminaryAnalysis,
            results: results
        )
    }

    @discardableResult
    func completeIngest(
        jobID: UUID,
        cardID: UUID,
        analysis: CardAnalysis,
        results: [ResultRow],
        independentDestinationCount: Int? = nil
    ) throws -> PhotographerFinalizationResult {
        guard var job = jobForRun(jobID) else {
            throw PhotographerJobViewModelError.noActiveJob
        }
        guard let cardIndex = job.cardIngests.firstIndex(where: { $0.id == cardID }) else {
            throw PhotographerJobViewModelError.noActiveCard
        }
        let currentCard = job.cardIngests[cardIndex]
        guard currentCard.localState == .copying || currentCard.localState == .verifying else {
            return finalizationResult(job: job, cardID: cardID, analysis: analysis)
        }

        let context = PhotographerReportContext(
            job: job,
            cardIngestID: cardID,
            analysis: analysis,
            verifiedDestinationCount: currentCard.verifiedDestinationCount,
            warnings: duplicateWarning.map { [$0.message] } ?? [],
            independentDestinationCount: independentDestinationCount
        )
        let finalized: PhotographerReportPayload.FinalizedCard
        do {
            finalized = try PhotographerReportPayload.finalizedCard(
                context: context,
                results: results,
                finishedAt: now(),
                confirmedFingerprint: confirmedAnalyzer
            )
        } catch {
            var failedCard = currentCard
            failedCard.localState = .issues
            failedCard.locallySafeAt = nil
            failedCard.provenance.confirmedFingerprint = nil
            failedCard.verifiedDestinationCount = 0
            job.cardIngests[cardIndex] = failedCard
            do {
                try persistRunJobThrowing(job)
            } catch {
                lastError = error.localizedDescription
                throw error
            }
            if activeCardDraft?.id == cardID { activeCardDraft = failedCard }
            lastError = error.localizedDescription
            throw error
        }

        job.cardIngests[cardIndex] = finalized.card
        do {
            try persistRunJobThrowing(job)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        if activeCardDraft?.id == cardID { activeCardDraft = finalized.card }
        return finalizationResult(
            job: jobForRun(jobID) ?? job,
            cardID: cardID,
            analysis: analysis
        )
    }

    func cancelIngest() {
        guard let jobID = activeJob?.id, let cardID = activeCardDraft?.id else { return }
        cancelIngest(jobID: jobID, cardID: cardID)
    }

    func cancelIngest(jobID: UUID, cardID: UUID) {
        transitionCard(jobID: jobID, cardID: cardID, to: .cancelled) { card in
            card.locallySafeAt = nil
        }
    }

    private func updateRemoteSummary(for cardIngestID: UUID, items: [RemoteQueueItem]) throws {
        guard !items.isEmpty,
              items.allSatisfy({ $0.cardIngestID == cardIngestID }),
              let jobID = items.first?.jobID,
              items.allSatisfy({ $0.jobID == jobID }),
              var job = try store.jobs().first(where: { $0.id == jobID }),
              let cardIndex = job.cardIngests.firstIndex(where: { $0.id == cardIngestID }) else { return }

        var summaries: [UUID: RemoteBackupCardSummary] = [:]
        for (targetID, targetItems) in Dictionary(grouping: items, by: \.destinationProfileID) {
            summaries[targetID] = try remoteBackupSummary(targetID: targetID, items: targetItems)
        }
        for (targetID, summary) in summaries {
            job.cardIngests[cardIndex].remoteBackupSummaries[targetID] = summary
        }
        try persistBackgroundJobThrowing(job)
    }

    private func remoteBackupSummary(
        targetID: UUID,
        items: [RemoteQueueItem]
    ) throws -> RemoteBackupCardSummary {
        let orderedItems = items.sorted {
            if $0.remoteRelativePath.description != $1.remoteRelativePath.description {
                return $0.remoteRelativePath.description < $1.remoteRelativePath.description
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        let totalBytes = orderedItems.reduce(Int64(0)) { $0 + $1.uploadedByteCount }
        let expectedBytes = try orderedItems.reduce(Int64(0)) { (total, item) throws -> Int64 in
            total + (try remoteManifestEntryByteCount(for: item))
        }
        // A card is fully backed up only when every manifest entry has durable
        // verified evidence. Never let the first item conceal a later conflict,
        // failure, or upload-only terminal state.
        let state: RemoteBackupState
        let allVerified = orderedItems.allSatisfy {
            $0.state == .verified && RemoteBackupStatusPresentation.make(state: $0.state, evidence: $0.verificationEvidence).isFullyBackedUp
        }
        if allVerified { state = .verified }
        else if orderedItems.contains(where: { $0.state == .conflict }) { state = .conflict }
        else if orderedItems.contains(where: { $0.state == .failed }) { state = .failed }
        else if orderedItems.contains(where: { $0.state == .cancelled }) { state = .cancelled }
        else if orderedItems.contains(where: { $0.state == .uploadedUnverified }) { state = .uploadedUnverified }
        else if orderedItems.contains(where: { $0.state == .verifying }) { state = .verifying }
        else if orderedItems.contains(where: { $0.state == .paused }) { state = .paused }
        else if orderedItems.contains(where: { $0.state == .retrying }) { state = .retrying }
        else if orderedItems.contains(where: { $0.state == .uploading }) { state = .uploading }
        else { state = .queued }
        return RemoteBackupCardSummary(
            targetID: targetID,
            state: state,
            totalFileCount: orderedItems.count,
            uploadedFileCount: orderedItems.filter { $0.state == .uploadedUnverified || $0.state == .verified }.count,
            totalByteCount: expectedBytes,
            uploadedByteCount: totalBytes,
            verificationEvidence: allVerified ? orderedItems[0].verificationEvidence : .none,
            remotePath: orderedItems.first?.remoteRelativePath,
            errorSummary: orderedItems.compactMap(\.errorSummary).first,
            updatedAt: now()
        )
    }

    private func remoteManifestEntryByteCount(for item: RemoteQueueItem) throws -> Int64 {
        guard let manifest = try store.manifests().first(where: { $0.id == item.manifestID }),
              let entry = manifest.entries.first(where: { $0.id == item.manifestEntryID }) else {
            throw ProjectRemoteCoordinatorError.manifestUnavailable
        }
        return entry.byteCount
    }

    private func replaceLoadedJob(_ updatedJob: PhotographerJob) {
        if let index = jobs.firstIndex(where: { $0.id == updatedJob.id }) {
            jobs[index] = updatedJob
        } else {
            jobs.append(updatedJob)
        }
        activeJob = updatedJob
        selectedWorkflow = updatedJob.workflow
    }

    /// Persists a queue-owned update without changing the active job or any
    /// current card/setup selection when the worker belongs to another job.
    private func persistBackgroundJobThrowing(_ job: PhotographerJob) throws {
        var updated = job
        updated.updatedAt = now()
        try store.save(updated)
        if let index = jobs.firstIndex(where: { $0.id == updated.id }) {
            jobs[index] = updated
        } else {
            jobs.append(updated)
        }
        if activeJob?.id == updated.id {
            activeJob = updated
        }
        jobs.sort { $0.updatedAt > $1.updatedAt }
        lastError = nil
    }

    func resetForNextCard() {
        clearCardPreparation()
    }

    /// Reopens the exact project card behind a failed transfer row. The old
    /// journal attempt keeps its evidence; setup re-analyzes the source before
    /// this card can start another attempt.
    func prepareProjectCardForRetry(jobID: UUID, cardID: UUID) throws {
        guard var job = jobForRun(jobID),
              let index = job.cardIngests.firstIndex(where: { $0.id == cardID }),
              job.cardIngests[index].localState == .issues
                || job.cardIngests[index].localState == .cancelled else {
            throw PhotographerJobViewModelError.noActiveCard
        }
        var card = job.cardIngests[index]
        card.localState = .notStarted
        card.startedAt = nil
        card.locallySafeAt = nil
        card.provenance.confirmedFingerprint = nil
        card.verifiedDestinationCount = 0
        job.cardIngests[index] = card
        try persistRunJobThrowing(job)

        activeJob = jobForRun(jobID) ?? job
        selectedWorkflow = job.workflow
        draftRecipe = job.recipe
        selectedPhotographerID = card.provenance.photographerID
        cameraName = card.provenance.cameraName
        activeCardDraft = card
        renderedRecipe = RenderedFolderRecipe(
            components: card.renderedRelativePath.split(separator: "/").map(String.init)
        )
        preliminaryAnalysis = nil
        duplicateWarning = nil
        preparedSourcePath = nil
        preparedSetupSignature = nil
        sourcePreparationInvalidated = false
        setupPreparationInvalidated = false
        preparationError = nil
        lastError = nil
    }

    func setDraftLayer(_ id: UUID, isEnabled: Bool) {
        guard let index = draftRecipe.layers.firstIndex(where: { $0.id == id }) else { return }
        draftRecipe.layers[index].isEnabled = isEnabled
        invalidateSetupPreparationIfNeeded()
    }

    func moveDraftLayer(_ id: UUID, direction: FolderLayerMoveDirection) {
        guard let index = draftRecipe.layers.firstIndex(where: { $0.id == id }) else { return }
        let destination = direction == .up ? index - 1 : index + 1
        guard draftRecipe.layers.indices.contains(destination) else { return }
        draftRecipe.layers.swapAt(index, destination)
        invalidateSetupPreparationIfNeeded()
    }

    func saveDraftAsPreset(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let presetID = UUID()
        var recipe = draftRecipe
        recipe.id = presetID
        recipe.name = cleanName
        let preset = PhotographerPreset(
            id: presetID,
            name: cleanName,
            eventType: .wedding,
            recipe: recipe,
            requiredLocalCopyCount: activeJob?.requiredLocalCopyCount ?? 2
        )
        do {
            try store.save(preset)
            presets.append(preset)
            presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            draftRecipe = recipe
            invalidateSetupPreparationIfNeeded()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectPreset(id: UUID) {
        if let builtInRecipe = FolderRecipe.builtInRecipe(id: id) {
            draftRecipe = builtInRecipe
        } else if let preset = presets.first(where: { $0.id == id }) {
            draftRecipe = preset.recipe
        }
        invalidateSetupPreparationIfNeeded()
    }

    func focusCardIngest(id: UUID) {
        dashboardJobID = jobs.first { job in
            job.cardIngests.contains { $0.id == id }
        }?.id ?? activeJob.flatMap { job in
            job.cardIngests.contains { $0.id == id } ? job.id : nil
        }
        focusedCardIngestID = id
    }

    private func loadJobs() {
        do {
            var recoveredCardCount = 0
            let loadedJobs = try store.jobs()
            let recoveredJobs = try loadedJobs.map { job -> PhotographerJob in
                var recovered = job
                var changed = false

                for index in recovered.cardIngests.indices where [
                    PhotographerLocalState.notStarted,
                    .copying,
                    .verifying
                ].contains(recovered.cardIngests[index].localState) {
                    recovered.cardIngests[index].localState = .issues
                    recovered.cardIngests[index].locallySafeAt = nil
                    recovered.cardIngests[index].provenance.confirmedFingerprint = nil
                    recovered.cardIngests[index].verifiedDestinationCount = 0
                    recoveredCardCount += 1
                    changed = true
                }

                if changed {
                    recovered.updatedAt = now()
                    try store.save(recovered)
                }
                return recovered
            }

            jobs = recoveredJobs.sorted { $0.updatedAt > $1.updatedAt }
            activeJob = jobs.first
            dashboardJobID = activeJob?.id
            selectedWorkflow = activeJob?.workflow ?? rememberedWorkflow
            draftRecipe = activeJob?.recipe ?? selectedWorkflow.defaultRecipe
            if recoveredCardCount > 0 {
                lastError = "Recovered \(recoveredCardCount) interrupted photographer \(recoveredCardCount == 1 ? "card" : "cards") and marked them as issues. Set up a new card to retry."
            } else {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadPresets() {
        do {
            presets = try store.presets().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadRemoteProfiles() {
        do {
            remoteProfiles = try store.profiles().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            remoteProfiles = []
        }
    }

    private func identity(named name: String, in job: PhotographerJob) -> PhotographerIdentity {
        if let existing = job.photographers.first(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return existing
        }
        return PhotographerIdentity(id: UUID(), name: name)
    }

    private func nextCardNumber(cameraName: String, in job: PhotographerJob) -> Int {
        let priorNumbers = job.cardIngests.compactMap { card -> Int? in
            guard card.provenance.cameraName.compare(
                cameraName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame else { return nil }
            return card.provenance.cardNumber
        }
        return (priorNumbers.max() ?? 0) + 1
    }

    private func portablePackageRoute(_ route: String) -> String {
        route
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { component in
                String(component)
                    .precomposedStringWithCanonicalMapping
                    .lowercased(with: Locale(identifier: "en_US_POSIX"))
            }
            .joined(separator: "/")
    }

    private func duplicateWarning(
        for fingerprint: String,
        excludingCardID: UUID? = nil
    ) -> DuplicateCardWarning? {
        let currentJobID = activeJob?.id
        let allJobs = jobs.map { storedJob in
            storedJob.id == currentJobID ? (activeJob ?? storedJob) : storedJob
        }
        for job in allJobs {
            if let card = job.cardIngests.first(where: {
                $0.id != excludingCardID
                    && ($0.provenance.preliminaryFingerprint == fingerprint
                        || $0.provenance.confirmedFingerprint == fingerprint)
            }) {
                return DuplicateCardWarning(
                    jobID: job.id,
                    cardIngestID: card.id,
                    fingerprint: fingerprint,
                    message: "This card appears to have already been ingested for \(job.jobName)."
                )
            }
        }
        return nil
    }

    private func finalizationResult(
        job: PhotographerJob,
        cardID: UUID,
        analysis: CardAnalysis
    ) -> PhotographerFinalizationResult {
        let card = job.cardIngests.first { $0.id == cardID }
        let context = PhotographerReportContext(
            job: job,
            cardIngestID: cardID,
            analysis: analysis,
            verifiedDestinationCount: card?.verifiedDestinationCount ?? 0,
            warnings: duplicateWarning.map { [$0.message] } ?? [],
            // The stored verified count was capped by the independence
            // assessment at finalization. Re-apply it so re-reports score
            // the same evidence instead of recounting raw groups, which
            // would flip a capped-safe card back to issues.
            independentDestinationCount: card?.verifiedDestinationCount
        )
        return PhotographerFinalizationResult(
            context: context,
            locallySafe: card?.localState == .locallySafe
        )
    }

    private func transitionActiveCard(
        to state: PhotographerLocalState,
        mutate: (inout CardIngest) -> Void = { _ in }
    ) {
        guard let jobID = activeJob?.id, let cardID = activeCardDraft?.id else { return }
        transitionCard(jobID: jobID, cardID: cardID, to: state, mutate: mutate)
    }

    private func transitionCard(
        jobID: UUID,
        cardID: UUID,
        to state: PhotographerLocalState,
        mutate: (inout CardIngest) -> Void = { _ in }
    ) {
        do {
            try transitionCardThrowing(jobID: jobID, cardID: cardID, to: state, mutate: mutate)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func transitionActiveCardThrowing(
        to state: PhotographerLocalState,
        mutate: (inout CardIngest) -> Void = { _ in }
    ) throws {
        guard let jobID = activeJob?.id, let cardID = activeCardDraft?.id else { return }
        try transitionCardThrowing(jobID: jobID, cardID: cardID, to: state, mutate: mutate)
    }

    private func transitionCardThrowing(
        jobID: UUID,
        cardID: UUID,
        to state: PhotographerLocalState,
        mutate: (inout CardIngest) -> Void = { _ in }
    ) throws {
        guard var job = jobForRun(jobID),
              let index = job.cardIngests.firstIndex(where: { $0.id == cardID }) else { return }
        let currentState = job.cardIngests[index].localState
        guard currentState != state, canTransition(from: currentState, to: state) else { return }

        job.cardIngests[index].localState = state
        mutate(&job.cardIngests[index])
        do {
            try persistRunJobThrowing(job)
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        if activeCardDraft?.id == cardID { activeCardDraft = job.cardIngests[index] }
    }

    private func forceActiveCardIntoIssuesInMemory() {
        guard let jobID = activeJob?.id, let cardID = activeCardDraft?.id else { return }
        forceCardIntoIssuesInMemory(jobID: jobID, cardID: cardID)
    }

    private func forceCardIntoIssuesInMemory(jobID: UUID, cardID: UUID) {
        guard var job = jobForRun(jobID),
              let index = job.cardIngests.firstIndex(where: { $0.id == cardID }) else { return }
        guard job.cardIngests[index].localState == .notStarted
                || job.cardIngests[index].localState == .copying
                || job.cardIngests[index].localState == .verifying else { return }

        job.cardIngests[index].localState = .issues
        job.cardIngests[index].locallySafeAt = nil
        job.cardIngests[index].provenance.confirmedFingerprint = nil
        job.cardIngests[index].verifiedDestinationCount = 0
        if activeJob?.id == jobID { activeJob = job }
        if let jobIndex = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[jobIndex] = job
        }
        if activeCardDraft?.id == cardID { activeCardDraft = job.cardIngests[index] }
    }

    private func persistThrowing(_ job: PhotographerJob) throws {
        var updated = job
        updated.updatedAt = now()
        try store.save(updated)
        activeJob = updated
        selectedWorkflow = updated.workflow
        if let index = jobs.firstIndex(where: { $0.id == updated.id }) {
            jobs[index] = updated
        } else {
            jobs.append(updated)
        }
        jobs.sort { $0.updatedAt > $1.updatedAt }
        lastError = nil
    }

    private func jobForRun(_ jobID: UUID) -> PhotographerJob? {
        if activeJob?.id == jobID { return activeJob }
        return jobs.first { $0.id == jobID }
    }

    /// Persists a snapshotted run's project without changing whichever job
    /// or draft the setup composer currently has selected.
    private func persistRunJobThrowing(_ job: PhotographerJob) throws {
        var updated = job
        updated.updatedAt = now()
        try store.save(updated)
        if activeJob?.id == updated.id {
            activeJob = updated
            selectedWorkflow = updated.workflow
        }
        if let index = jobs.firstIndex(where: { $0.id == updated.id }) {
            jobs[index] = updated
        } else {
            jobs.append(updated)
        }
        jobs.sort { $0.updatedAt > $1.updatedAt }
        lastError = nil
    }

    private func canTransition(from current: PhotographerLocalState, to next: PhotographerLocalState) -> Bool {
        switch current {
        case .locallySafe, .issues, .cancelled:
            return false
        case .notStarted:
            return next == .copying || next == .issues || next == .cancelled
        case .copying:
            return next == .verifying || next == .locallySafe || next == .issues || next == .cancelled
        case .verifying:
            return next == .locallySafe || next == .issues || next == .cancelled
        }
    }

    private func clearCardPreparation() {
        selectedPhotographerID = nil
        cameraName = ""
        activeCardDraft = nil
        renderedRecipe = nil
        preliminaryAnalysis = nil
        duplicateWarning = nil
        preparedSourcePath = nil
        preparedSetupSignature = nil
        currentSetupSignature = nil
        currentSourcePath = nil
        sourcePreparationInvalidated = false
        setupPreparationInvalidated = false
        setupGeneration = UUID()
        setupTask?.cancel()
        setupTask = nil
        isPreparing = false
        preparationError = nil
        lastError = nil
    }

    private func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func invalidateSetupPreparationIfNeeded() {
        if preparedSetupSignature != nil {
            setupPreparationInvalidated = true
        }
    }

}

enum PhotographerJobViewModelError: LocalizedError, Equatable {
    case noActiveJob
    case noActiveCard
    case missingPreliminaryAnalysis
    case duplicatePackageRoute(String)

    var errorDescription: String? {
        switch self {
        case .noActiveJob: return "Create or select a photographer job first."
        case .noActiveCard: return "Prepare a photographer card before completing ingest."
        case .missingPreliminaryAnalysis: return "Card analysis is required before completing ingest."
        case .duplicatePackageRoute(let path):
            return "Another card in this job already uses the package route \(path). Change the folder layers before retrying."
        }
    }
}
