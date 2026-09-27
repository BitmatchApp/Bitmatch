import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

@MainActor
struct PhotographerJobViewModelTests {
    private let eventDate = Date(timeIntervalSince1970: 100)
    private let now = Date(timeIntervalSince1970: 200)
    private let renderedPackage = "1970-01-01_Smith-Wedding/Originals/Mike/Sony-A7-IV/Card-001"

    @Test func selectingVideoWorkflowUsesVideoSafeFolderDefaults() {
        let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())

        viewModel.selectWorkflow(.videoDIT)

        #expect(viewModel.selectedWorkflow == .videoDIT)
        #expect(viewModel.draftRecipe.name == "Video / DIT")
        #expect(!viewModel.draftRecipe.layers.contains { $0.kind == .photographer })
    }

    @Test func selectingWorkflowUpdatesAnEmptyActiveProjectBeforeItsFirstCard() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = makeViewModel(store: store)
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Commercial", eventDate: eventDate)

        viewModel.selectWorkflow(.videoDIT)

        let job = try #require(viewModel.activeJob)
        #expect(job.workflow == .videoDIT)
        #expect(job.recipe.name == "Video / DIT")
        #expect(store.storedJobs.first?.workflow == .videoDIT)
    }

    @Test func workflowCannotChangeAfterFirstMediaPackageIsPrepared() throws {
        let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Commercial", eventDate: eventDate)
        try viewModel.prepareCard(photographerName: "Mike", cameraName: "FX6", analysis: analysis("one"))

        viewModel.selectWorkflow(.videoDIT)

        #expect(viewModel.selectedWorkflow == .photography)
        #expect(viewModel.activeJob?.workflow == .photography)
        #expect(viewModel.preparationError == "Project type is fixed after the first media package is prepared.")
    }

    @Test func weddingJobUsesWeddingDefaultsAndPersistsCreation() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = makeViewModel(store: store)

        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)

        let job = try #require(viewModel.activeJob)
        #expect(job.eventType == .wedding)
        #expect(job.recipe.name == FolderRecipe.wedding.name)
        #expect(job.requiredLocalCopyCount == 2)
        #expect(job.clientName == "Smith")
        #expect(store.saveCount == 1)
        #expect(viewModel.jobs == [job])
    }

    @Test func reloadsPersistedJobsWhenStoreBecomesAvailableAfterLaunch() throws {
        let job = PhotographerJob(
            id: UUID(),
            eventDate: eventDate,
            clientName: "Smith",
            jobName: "Recovered Wedding",
            eventType: .wedding,
            photographers: [],
            recipe: .wedding,
            requiredLocalCopyCount: 2,
            cardIngests: [],
            createdAt: eventDate,
            updatedAt: now
        )
        let store = DeferredPhotographerJobStore(storedJobs: [job])
        let viewModel = PhotographerJobViewModel(store: store, workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography))

        #expect(viewModel.jobs.isEmpty)
        store.becomeAvailable()

        #expect(viewModel.activeJob?.id == job.id)
        #expect(viewModel.jobs == [job])
    }

    @Test func draftLayerControlsToggleAndReorderTheWeddingRecipe() throws {
        let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())
        let photographerID = try #require(viewModel.draftRecipe.layers.first { $0.kind == .photographer }?.id)

        viewModel.setDraftLayer(photographerID, isEnabled: false)
        viewModel.moveDraftLayer(photographerID, direction: .up)

        let photographerIndex = try #require(viewModel.draftRecipe.layers.firstIndex { $0.id == photographerID })
        #expect(!viewModel.draftRecipe.layers[photographerIndex].isEnabled)
        #expect(photographerIndex == 1)
    }

    @Test func saveDraftAsPresetPersistsCurrentLayerConfiguration() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = makeViewModel(store: store)
        let cameraID = try #require(viewModel.draftRecipe.layers.first { $0.kind == .camera }?.id)
        viewModel.setDraftLayer(cameraID, isEnabled: false)

        viewModel.saveDraftAsPreset(name: "Wedding without camera")

        let preset = try #require(store.storedPresets.first)
        #expect(preset.name == "Wedding without camera")
        #expect(preset.recipe.layers.first { $0.kind == .camera }?.isEnabled == false)
        #expect(viewModel.presets.contains(preset))
        #expect(viewModel.draftRecipe == preset.recipe)
    }

    @Test func draftSetupCreatesCardWithCustomizedRecipeAndKeepsJobForNextCard() throws {
        let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())
        let photographerID = try #require(viewModel.draftRecipe.layers.first { $0.kind == .photographer }?.id)
        viewModel.setDraftLayer(photographerID, isEnabled: false)

        try viewModel.prepareDraftCard(
            clientName: "Smith",
            jobName: "Smith Wedding",
            eventDate: eventDate,
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            sourceDisplayName: "CARD1",
            entries: [FileEntry(url: URL(fileURLWithPath: "/card/A.ARW"), relativePath: "A.ARW", size: 100, modificationDate: eventDate)]
        )
        let firstJobID = try #require(viewModel.activeJob?.id)
        #expect(viewModel.renderedRecipe?.relativePath == "1970-01-01_Smith-Wedding/Originals/Sony-A7-IV/Card-001")

        viewModel.resetForNextCard()
        try viewModel.prepareDraftCard(
            clientName: "Smith",
            jobName: "Smith Wedding",
            eventDate: eventDate,
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            sourceDisplayName: "CARD2",
            entries: [FileEntry(url: URL(fileURLWithPath: "/card/B.ARW"), relativePath: "B.ARW", size: 100, modificationDate: eventDate)]
        )

        #expect(viewModel.activeJob?.id == firstJobID)
        #expect(viewModel.activeCard?.provenance.cardNumber == 2)
    }

    @Test func cardNumbersAdvanceIndependentlyForEachCamera() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = makeViewModel(store: store)
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)

        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", analysis: analysis("one"))
        #expect(viewModel.activeCard?.provenance.cardNumber == 1)
        viewModel.resetForNextCard()
        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Canon R5", analysis: analysis("two"))
        #expect(viewModel.activeCard?.provenance.cardNumber == 1)
        viewModel.resetForNextCard()
        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", analysis: analysis("three"))

        #expect(viewModel.activeCard?.provenance.cardNumber == 2)
    }

    @Test func preparedCardPublishesRenderedPreviewAndPersistsNotStartedState() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = makeViewModel(store: store)
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)

        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", analysis: analysis("preview"))

        #expect(viewModel.renderedRecipe?.components == [
            "1970-01-01_Smith-Wedding", "Originals", "Mike", "Sony-A7-IV", "Card-001"
        ])
        #expect(viewModel.activeCardDraft?.localState == .notStarted)
        #expect(viewModel.activeCardDraft?.renderedRelativePath == viewModel.renderedRecipe?.relativePath)
        #expect(store.saveCount == 2)
    }

    @Test func preparedCardUsesHumanReadableDefaultSourceName() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = makeViewModel(store: store)
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)

        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", analysis: analysis("source"))

        #expect(viewModel.activeCard?.sourceDisplayName == "Card 1")
    }

    @Test func repeatedPreliminaryFingerprintPublishesPriorCardWarning() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = makeViewModel(store: store)
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)
        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", analysis: analysis("same"))
        let priorJobID = try #require(viewModel.activeJob?.id)
        let priorCardID = try #require(viewModel.activeCard?.id)
        viewModel.resetForNextCard()

        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", analysis: analysis("same"))

        let warning = try #require(viewModel.duplicateWarning)
        #expect(warning.jobID == priorJobID)
        #expect(warning.cardIngestID == priorCardID)
        #expect(warning.fingerprint == "same")
        #expect(warning.message.contains("already"))
    }

    @Test func ingestTransitionsCopyingVerifyingLocallySafeAndPersistsEachTransition() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        #expect(store.saveCount == 2)

        viewModel.beginIngest(destinationCount: 2)
        #expect(viewModel.activeCard?.localState == .copying)
        #expect(store.saveCount == 3)

        viewModel.updateProgressStage(.verifying)
        #expect(viewModel.activeCard?.localState == .verifying)
        #expect(store.saveCount == 4)

        try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary", "Secondary"]))
        #expect(viewModel.activeCard?.localState == .locallySafe)
        #expect(viewModel.activeCard?.locallySafeAt == now)
        #expect(store.saveCount == 5)
    }

    @Test func handoffFailurePreservesPersistedLocalVerificationEvidence() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)
        try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary", "Secondary"]))
        let verified = try #require(viewModel.activeCard)
        let savesBeforeHandoffResult = store.saveCount

        // Delayed copy progress and a failed ASC MHL/report handoff cannot erase the local verdict.
        viewModel.updateProgressStage(.verifying)
        viewModel.operationFailed()
        viewModel.operationFailed() // Shared + native shell may both observe completion.

        #expect(viewModel.activeCard?.localState == .locallySafe)
        #expect(viewModel.activeCard?.locallySafeAt == verified.locallySafeAt)
        #expect(viewModel.activeCard?.provenance.confirmedFingerprint == verified.provenance.confirmedFingerprint)
        #expect(viewModel.activeCard?.verifiedDestinationCount == verified.verifiedDestinationCount)
        #expect(store.saveCount == savesBeforeHandoffResult)
        #expect(store.storedJobs.first?.cardIngests.first?.localState == .locallySafe)
    }

    @Test func unsuccessfulCompletionBeforeLocalFinalizationStillFailsCard() {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())
        viewModel.beginIngest(destinationCount: 2)
        viewModel.updateProgressStage(.verifying)

        viewModel.operationFailed()

        #expect(viewModel.activeCard?.localState == .issues)
        #expect(viewModel.activeCard?.locallySafeAt == nil)
        #expect(viewModel.activeCard?.verifiedDestinationCount == 0)
        #expect(viewModel.activeCard?.provenance.confirmedFingerprint == nil)
    }

    @Test func completionRequiresConfiguredVerifiedDestinationCount() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)

        try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary", "Secondary"]))

        #expect(viewModel.activeCard?.localState == .locallySafe)
    }

    @Test func startingWithTooFewDestinationsReportsRequiredCount() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)

        let began = viewModel.beginIngest(destinationCount: 1)

        #expect(viewModel.lastError == "Add 1 more destination for this 2-copy job")
        #expect(!began)
        #expect(viewModel.activeCard?.localState == .notStarted)
    }

    @Test func startingProjectWithNoDestinationsFailsClosed() {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())

        let began = viewModel.beginIngest(destinationCount: 0)

        #expect(!began)
        #expect(viewModel.lastError == "Add 2 more destinations for this 2-copy job")
        #expect(viewModel.activeCard?.localState == .notStarted)
    }

    @Test func rereportReusesStoredIndependenceInsteadOfRecountingGroups() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)
        let rows = verifiedRows(destinationNames: ["Primary", "Secondary"])
        try viewModel.completeIngest(results: rows)
        let card = try #require(viewModel.activeCard)
        #expect(card.localState == .locallySafe)

        let jobID = try #require(viewModel.activeJob?.id)
        let analysis = try #require(viewModel.preliminaryAnalysis)
        let rereport = try viewModel.completeIngest(
            jobID: jobID, cardID: card.id, analysis: analysis, results: rows
        )

        #expect(rereport.context?.independentDestinationCount == card.verifiedDestinationCount)
        #expect(rereport.locallySafe)
    }

    @Test func preparedPhotographerCardBlocksQuickModeWithConcreteStartError() throws {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())

        let presentation = viewModel.startPresentation(
            preflightReady: true,
            sourceURL: nil,
            destinationCount: 2,
            verificationMode: .quick
        )
        let began = viewModel.beginIngest(
            destinationCount: 2,
            verificationMode: .quick
        )

        #expect(!presentation.canStart)
        #expect(
            presentation.blocker ==
                "Photographer ingests require Standard, Thorough, or Paranoid verification; Quick mode cannot establish locally safe evidence."
        )
        #expect(!began)
        #expect(viewModel.activeCard?.localState == .notStarted)
        #expect(viewModel.lastError == presentation.blocker)
    }

    @Test func remoteQueueFailureDoesNotChangeCopyingLocalEvidence() throws {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())
        _ = viewModel.beginIngest(destinationCount: 2)
        let cardID = try #require(viewModel.activeCard?.id)

        #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            try viewModel.queueRemoteBackup(for: cardID, results: [])
        }

        #expect(viewModel.activeCard?.localState == .copying)
        #expect(viewModel.activeCard?.locallySafeAt == nil)
        #expect(viewModel.activeCard?.provenance.confirmedFingerprint == nil)
    }

    @Test func remoteSummaryRefreshPersistsForBackgroundJobAndSeparatesDestinations() throws {
        let store = InMemoryPhotographerJobStore()
        let backgroundJobID = UUID()
        let backgroundCardID = UUID()
        let activeJobID = UUID()
        let backgroundJob = summaryJob(id: backgroundJobID, cardID: backgroundCardID, updatedAt: now.addingTimeInterval(-10))
        let activeJob = summaryJob(id: activeJobID, cardID: UUID(), updatedAt: now)
        try store.save(backgroundJob)
        try store.save(activeJob)

        let targetA = UUID()
        let targetB = UUID()
        let package = try RemoteRelativePath(components: ["Jobs", "Background"])
        let entryA = RemoteManifestEntry(
            id: UUID(),
            relativePath: try RemoteRelativePath(components: ["A.mov"]),
            byteCount: 10,
            sha256: String(repeating: "a", count: 64)
        )
        let entryB = RemoteManifestEntry(
            id: UUID(),
            relativePath: try RemoteRelativePath(components: ["B.mov"]),
            byteCount: 20,
            sha256: String(repeating: "b", count: 64)
        )
        let manifestA = try RemoteManifest(
            id: UUID(), jobID: backgroundJobID, cardIngestID: backgroundCardID,
            destinationProfileID: targetA, packageRelativePath: package,
            entries: [entryA], createdAt: now
        )
        let manifestB = try RemoteManifest(
            id: UUID(), jobID: backgroundJobID, cardIngestID: backgroundCardID,
            destinationProfileID: targetB, packageRelativePath: package,
            entries: [entryB], createdAt: now
        )
        try store.save(manifestA)
        try store.save(manifestB)
        let itemA = summaryItem(
            jobID: backgroundJobID, cardID: backgroundCardID, targetID: targetA,
            manifest: manifestA, entry: entryA, state: .uploadedUnverified, uploadedBytes: 10
        )
        let itemB = summaryItem(
            jobID: backgroundJobID, cardID: backgroundCardID, targetID: targetB,
            manifest: manifestB, entry: entryB, state: .queued, uploadedBytes: 0
        )

        let viewModel = makeViewModel(store: store)
        viewModel.refreshRemoteBackupSummary(for: backgroundCardID, items: [itemA, itemB])

        let savedBackground = try #require(store.storedJobs.first { $0.id == backgroundJobID })
        let savedCard = try #require(savedBackground.cardIngests.first)
        #expect(savedCard.remoteBackupSummaries[targetA]?.state == .uploadedUnverified)
        #expect(savedCard.remoteBackupSummaries[targetB]?.state == .queued)
        #expect(savedCard.remoteBackupSummaries[targetA]?.totalByteCount == 10)
        #expect(savedCard.remoteBackupSummaries[targetB]?.totalByteCount == 20)
        #expect(viewModel.activeJob?.id == activeJobID)
    }

    @Test func terminalCardsCannotBeginAgainAndRequireNextCardSetup() throws {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())
        _ = viewModel.beginIngest(destinationCount: 2)
        try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary", "Secondary"]))

        let began = viewModel.beginIngest(destinationCount: 2)

        #expect(!began)
        #expect(viewModel.activeCard?.localState == .locallySafe)
        #expect(viewModel.startPresentation(preflightReady: true, sourceURL: nil, destinationCount: 2).blocker == "Set up the next card before starting")
    }

    @Test func changedSourceInvalidatesPreparedCard() throws {
        let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())
        let source = URL(fileURLWithPath: "/Volumes/CARD1")
        let signature = setupSignature()
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)
        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", sourceURL: source, setupSignature: signature, analysis: analysis("source"))

        viewModel.sourceDidChange(to: URL(fileURLWithPath: "/Volumes/CARD2"))
        viewModel.sourceDidChange(to: source)

        #expect(!viewModel.isStartEligible(preflightReady: true, sourceURL: source, destinationCount: 2))
    }

    @Test func everySetupSignatureCategoryInvalidatesPreparation() throws {
        let original = setupSignature()
        let variants = [
            PhotographerSetupSignature(clientName: "Jones", jobName: original.jobName, eventDate: original.eventDate, photographerName: original.photographerName, cameraName: original.cameraName, cardNumber: original.cardNumber, recipe: original.recipe),
            PhotographerSetupSignature(clientName: original.clientName, jobName: "Other", eventDate: original.eventDate, photographerName: original.photographerName, cameraName: original.cameraName, cardNumber: original.cardNumber, recipe: original.recipe),
            PhotographerSetupSignature(clientName: original.clientName, jobName: original.jobName, eventDate: eventDate.addingTimeInterval(86_400), photographerName: original.photographerName, cameraName: original.cameraName, cardNumber: original.cardNumber, recipe: original.recipe),
            PhotographerSetupSignature(clientName: original.clientName, jobName: original.jobName, eventDate: original.eventDate, photographerName: "Sam", cameraName: original.cameraName, cardNumber: original.cardNumber, recipe: original.recipe),
            PhotographerSetupSignature(clientName: original.clientName, jobName: original.jobName, eventDate: original.eventDate, photographerName: original.photographerName, cameraName: "Canon", cardNumber: original.cardNumber, recipe: original.recipe),
            PhotographerSetupSignature(clientName: original.clientName, jobName: original.jobName, eventDate: original.eventDate, photographerName: original.photographerName, cameraName: original.cameraName, cardNumber: 2, recipe: original.recipe),
            PhotographerSetupSignature(clientName: original.clientName, jobName: original.jobName, eventDate: original.eventDate, photographerName: original.photographerName, cameraName: original.cameraName, cardNumber: original.cardNumber, recipe: FolderRecipe(id: UUID(), name: "Custom", layers: original.recipe.layers))
        ]
        for variant in variants {
            let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())
            let source = URL(fileURLWithPath: "/Volumes/CARD1")
            viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)
            try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", sourceURL: source, setupSignature: original, analysis: analysis("sig"))
            viewModel.updateSetupSignature(variant)
            viewModel.updateSetupSignature(original)
            #expect(!viewModel.isStartEligible(preflightReady: true, sourceURL: source, destinationCount: 2))
        }
    }

    @Test func editingAndRepreparingPendingCardPreservesIdentityAndCardNumber() async throws {
        let source = URL(fileURLWithPath: "/Volumes/CARD1")
        let viewModel = PhotographerJobViewModel(
            store: InMemoryPhotographerJobStore(),
            now: { self.now },
            entryEnumerator: { source in
                [FileEntry(
                    url: source.appendingPathComponent("A.ARW"),
                    relativePath: "A.ARW",
                    size: 100
                )]
            },
            workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography)
        )
        let original = setupSignature()
        viewModel.startPreparingDraftCard(sourceURL: source, setupSignature: original)
        await viewModel.waitForSetupForTesting()
        let originalID = try #require(viewModel.activeCard?.id)
        #expect(viewModel.proposedCardNumber(cameraName: original.cameraName) == 1)
        var editedRecipe = original.recipe
        editedRecipe.name = "Edited Wedding"
        let edited = PhotographerSetupSignature(
            clientName: "Jones",
            jobName: "Jones Wedding",
            eventDate: eventDate.addingTimeInterval(86_400),
            photographerName: "Sam",
            cameraName: "Canon R5",
            cardNumber: 1,
            recipe: editedRecipe
        )

        viewModel.updateSetupSignature(edited)
        viewModel.startPreparingDraftCard(sourceURL: source, setupSignature: edited)
        await viewModel.waitForSetupForTesting()

        #expect(viewModel.activeJob?.clientName == "Jones")
        #expect(viewModel.activeJob?.jobName == "Jones Wedding")
        #expect(viewModel.activeCard?.id == originalID)
        #expect(viewModel.activeCard?.provenance.cardNumber == 1)
        #expect(viewModel.activeJob?.cardIngests.count == 1)
        #expect(viewModel.activeCard?.provenance.cameraName == "Canon R5")
    }

    @Test func exactVerifiedDestinationCountPersistsAndRestoresMostRecentSession() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        _ = viewModel.beginIngest(destinationCount: 3)
        try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary", "Secondary", "Archive"]))

        let restored = makeViewModel(store: store)

        #expect(restored.activeJob?.id == viewModel.activeJob?.id)
        #expect(restored.activeJob?.cardIngests.first?.verifiedDestinationCount == 3)
        #expect(PhotographerSessionPresentation.make(job: try #require(restored.activeJob)).rows.first?.verifiedCopyTitle == "3 of 2 verified")
    }

    @Test func loadingInterruptedCardDurablyDowngradesItAndClearsSafetyEvidence() throws {
        let store = InMemoryPhotographerJobStore()
        let original = preparedViewModel(store: store)
        var job = try #require(original.activeJob)
        var stale = try #require(job.cardIngests.first)
        stale.localState = .verifying
        stale.locallySafeAt = now
        stale.provenance.confirmedFingerprint = "stale-confirmed-fingerprint"
        stale.verifiedDestinationCount = 2
        job.cardIngests = [stale]
        try store.save(job)

        let recovered = makeViewModel(store: store)
        let recoveredCard = try #require(recovered.activeJob?.cardIngests.first)

        #expect(recoveredCard.localState == .issues)
        #expect(recoveredCard.locallySafeAt == nil)
        #expect(recoveredCard.provenance.confirmedFingerprint == nil)
        #expect(recoveredCard.verifiedDestinationCount == 0)
        #expect(store.storedJobs.first?.cardIngests.first == recoveredCard)
        #expect(recovered.activeCardDraft == nil)
        #expect(recovered.lastError?.contains("Recovered") == true)

        try recovered.prepareCard(
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            analysis: analysis("retry")
        )
        #expect(recovered.activeJob?.cardIngests.count == 2)
        #expect(recovered.activeCard?.localState == .notStarted)
    }

    @Test func staleAsyncSetupCompletionAfterSourceChangeIsIgnored() async throws {
        let gate = AsyncSetupGate()
        let viewModel = PhotographerJobViewModel(store: InMemoryPhotographerJobStore(), now: { self.now }, entryEnumerator: { url in
            gate.wait()
            return [FileEntry(url: url.appendingPathComponent("A.ARW"), relativePath: "A.ARW", size: 100)]
        }, workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography))
        let first = URL(fileURLWithPath: "/Volumes/CARD1")
        viewModel.startPreparingDraftCard(sourceURL: first, setupSignature: setupSignature())
        await Task.yield()

        viewModel.sourceDidChange(to: URL(fileURLWithPath: "/Volumes/CARD2"))
        gate.open()
        await viewModel.waitForSetupForTesting()

        #expect(viewModel.activeCard == nil)
        #expect(!viewModel.isPreparing)
    }

    @Test func asyncSetupDoesNotBlockMainActorAndCancellationClearsPreparingState() async {
        let gate = AsyncSetupGate()
        let viewModel = PhotographerJobViewModel(store: InMemoryPhotographerJobStore(), entryEnumerator: { url in
            gate.wait()
            try Task.checkCancellation()
            return [FileEntry(url: url, relativePath: "A.ARW", size: 100)]
        }, workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography))

        viewModel.startPreparingDraftCard(sourceURL: URL(fileURLWithPath: "/Volumes/CARD1"), setupSignature: setupSignature())
        #expect(viewModel.isPreparing)
        var mainActorAdvanced = false
        await Task.yield()
        mainActorAdvanced = true
        viewModel.sourceDidChange(to: URL(fileURLWithPath: "/Volumes/CARD2"))
        gate.open()
        await viewModel.waitForSetupForTesting()

        #expect(mainActorAdvanced)
        #expect(!viewModel.isPreparing)
        #expect(viewModel.activeCard == nil)
    }

    @Test func userCancellationStopsPreparingDraftWithoutCreatingACard() async {
        let gate = AsyncSetupGate()
        let viewModel = PhotographerJobViewModel(store: InMemoryPhotographerJobStore(), entryEnumerator: { url in
            gate.wait()
            try Task.checkCancellation()
            return [FileEntry(url: url, relativePath: "A.ARW", size: 100)]
        }, workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography))

        viewModel.startPreparingDraftCard(sourceURL: URL(fileURLWithPath: "/Volumes/CARD1"), setupSignature: setupSignature())
        #expect(viewModel.isPreparing)

        viewModel.cancelPreparingDraftCard()
        #expect(!viewModel.isPreparing)
        gate.open()
        await viewModel.waitForSetupForTesting()

        #expect(viewModel.activeCard == nil)
        #expect(viewModel.preparationError == nil)
    }

    @Test func duplicateNavigationRevealsAndPublishesDashboardFocusTarget() throws {
        let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)
        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony", analysis: analysis("same"))
        let earlierID = try #require(viewModel.activeCard?.id)
        viewModel.resetForNextCard()
        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony", analysis: analysis("same"))

        viewModel.focusCardIngest(id: earlierID)

        #expect(viewModel.focusedCardIngestID == earlierID)
        #expect(viewModel.dashboardJob?.cardIngests.contains { $0.id == earlierID } == true)
    }

    @Test func duplicatePortablePackageRouteIsRejectedWhenCardLayerIsDisabled() throws {
        let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())
        let cardLayerID = try #require(
            viewModel.draftRecipe.layers.first { $0.kind == .cardNumber }?.id
        )
        viewModel.setDraftLayer(cardLayerID, isEnabled: false)
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)
        try viewModel.prepareCard(
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            analysis: analysis("first")
        )
        viewModel.resetForNextCard()

        do {
            try viewModel.prepareCard(
                photographerName: "Mike",
                cameraName: "Sony A7 IV",
                analysis: analysis("second")
            )
            Issue.record("Expected duplicate portable package route to be rejected")
        } catch PhotographerJobViewModelError.duplicatePackageRoute(let path) {
            #expect(path == "1970-01-01_Smith-Wedding/Originals/Mike/Sony-A7-IV")
        }

        #expect(viewModel.activeJob?.cardIngests.count == 1)
    }

    @Test func reconfiguringTheSamePendingCardMayKeepItsPortablePackageRoute() throws {
        let viewModel = makeViewModel(store: InMemoryPhotographerJobStore())
        let cardLayerID = try #require(
            viewModel.draftRecipe.layers.first { $0.kind == .cardNumber }?.id
        )
        viewModel.setDraftLayer(cardLayerID, isEnabled: false)
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)
        try viewModel.prepareCard(
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            analysis: analysis("first")
        )
        let originalID = try #require(viewModel.activeCard?.id)

        try viewModel.prepareCard(
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            analysis: analysis("reconfigured")
        )

        #expect(viewModel.activeCard?.id == originalID)
        #expect(viewModel.activeJob?.cardIngests.count == 1)
    }

    @Test func destinationPathsDistinguishVolumesWithTheSameDisplayName() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)
        let rows = [
            "/Volumes/One/\(renderedPackage)/A.ARW",
            "/Volumes/Two/\(renderedPackage)/A.ARW"
        ].map { path in
            ResultRow(
                path: "/card/A.ARW",
                status: "✅ Verified",
                size: 100,
                checksum: "abc",
                destination: "Backup",
                destinationPath: path
            )
        }

        try viewModel.completeIngest(results: rows)

        #expect(viewModel.activeCard?.localState == .locallySafe)
    }

    @Test func failedOrUnverifiedDestinationLeavesCardInIssues() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)
        let rows = verifiedRows(destinationNames: ["Primary"]) + [
            ResultRow(
                path: "/card/A.ARW",
                status: "❌ Checksum mismatch",
                size: 100,
                checksum: "bad",
                destination: "Secondary",
                destinationPath: "/secondary/A.ARW"
            )
        ]

        try viewModel.completeIngest(results: rows)

        #expect(viewModel.activeCard?.localState == .issues)
        #expect(viewModel.activeCard?.locallySafeAt == nil)
    }

    @Test func successWithoutChecksumIsUnverifiedAndLeavesCardInIssues() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)
        let rows = verifiedRows(destinationNames: ["Primary"]) + [
            ResultRow(
                path: "/card/A.ARW",
                status: "✅ Copied",
                size: 100,
                checksum: nil,
                destination: "Secondary",
                destinationPath: "/secondary/A.ARW"
            )
        ]

        try viewModel.completeIngest(results: rows)

        #expect(viewModel.activeCard?.localState == .issues)
    }

    @Test func safeCompletionStoresCardFingerprintFromOneAuthoritativeCopyPerSource() throws {
        let store = InMemoryPhotographerJobStore()
        let rows = verifiedRows(destinationNames: ["Primary", "Secondary"])
        let expected = try PhotographerCardAnalyzer.confirmedFingerprint(results: [rows[0]])
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)

        try viewModel.completeIngest(results: rows)

        #expect(viewModel.activeCard?.provenance.confirmedFingerprint == expected)
    }

    @Test func cancellationPersistsCancelledState() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)

        viewModel.cancelIngest()

        #expect(viewModel.activeCard?.localState == .cancelled)
        #expect(store.saveCount == 4)
    }

    @Test func terminalStatesIgnoreDelayedProgressCancellationAndRepeatCompletion() throws {
        for terminalState in PhotographerLocalState.terminalStates {
            let store = InMemoryPhotographerJobStore()
            let viewModel = preparedViewModel(store: store)
            viewModel.beginIngest(destinationCount: 2)
            switch terminalState {
            case .locallySafe:
                try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary", "Secondary"]))
            case .issues:
                try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary"]))
            case .cancelled:
                viewModel.cancelIngest()
            default:
                Issue.record("Expected terminal state")
            }

            viewModel.updateProgressStage(.copying)
            viewModel.updateProgressStage(.verifying)
            viewModel.cancelIngest()
            try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary", "Secondary"]))

            #expect(viewModel.activeCard?.localState == terminalState)
        }
    }

    @Test func equalDestinationCountsWithDifferentPathSetsAreIssues() throws {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore(), sourcePaths: ["/card/A.ARW", "/card/B.JPG"])
        viewModel.beginIngest(destinationCount: 2)
        let rows = [
            verifiedRow(path: "/card/A.ARW", checksum: "aaa", destination: "Primary"),
            verifiedRow(path: "/card/B.JPG", checksum: "bbb", destination: "Primary"),
            verifiedRow(path: "/card/A.ARW", checksum: "aaa", destination: "Secondary"),
            verifiedRow(path: "/card/C.JPG", checksum: "ccc", destination: "Secondary")
        ]

        try viewModel.completeIngest(results: rows)

        #expect(viewModel.activeCard?.localState == .issues)
    }

    @Test func preparedPathMissingFromEveryResultIsIssues() throws {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore(), sourcePaths: ["/card/A.ARW", "/card/B.JPG"])
        viewModel.beginIngest(destinationCount: 2)
        let rows = ["Primary", "Secondary"].flatMap { destination in
            [verifiedRow(path: "/card/A.ARW", checksum: "aaa", destination: destination)]
        }

        try viewModel.completeIngest(results: rows)

        #expect(viewModel.activeCard?.localState == .issues)
    }

    @Test func duplicateRowsForOneSourceAreIssues() throws {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())
        viewModel.beginIngest(destinationCount: 2)
        var rows = verifiedRows(destinationNames: ["Primary", "Secondary"])
        rows.append(verifiedRow(path: "/card/A.ARW", checksum: "abc", destination: "Secondary"))

        try viewModel.completeIngest(results: rows)

        #expect(viewModel.activeCard?.localState == .issues)
    }

    @Test func crossDestinationChecksumDisagreementIsIssues() throws {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())
        viewModel.beginIngest(destinationCount: 2)
        let rows = [
            verifiedRow(path: "/card/A.ARW", checksum: "abc", destination: "Primary"),
            verifiedRow(path: "/card/A.ARW", checksum: "different", destination: "Secondary")
        ]

        try viewModel.completeIngest(results: rows)

        #expect(viewModel.activeCard?.localState == .issues)
    }

    @Test func blankSourceDestinationOrChecksumIsIssues() throws {
        let invalidRows = [
            verifiedRow(path: "   ", checksum: "abc", destination: "Primary"),
            ResultRow(path: "/card/A.ARW", status: "✅ Verified", size: 100, checksum: "abc", destination: "Primary", destinationPath: "  "),
            verifiedRow(path: "/card/A.ARW", checksum: " \t", destination: "Primary")
        ]

        for invalidRow in invalidRows {
            let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())
            viewModel.beginIngest(destinationCount: 2)
            try viewModel.completeIngest(results: [invalidRow, verifiedRow(path: "/card/A.ARW", checksum: "abc", destination: "Secondary")])
            #expect(viewModel.activeCard?.localState == .issues)
        }
    }

    @Test func safeTransitionPublishesOnlyAfterDurableSave() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        viewModel.beginIngest(destinationCount: 2)
        viewModel.updateProgressStage(.verifying)
        store.errorOnSave = TestStoreError.saveFailed

        #expect(throws: TestStoreError.saveFailed) {
            try viewModel.completeIngest(results: verifiedRows(destinationNames: ["Primary", "Secondary"]))
        }

        #expect(viewModel.activeCard?.localState == .verifying)
        #expect(viewModel.activeCard?.locallySafeAt == nil)
        #expect(viewModel.lastError == TestStoreError.saveFailed.localizedDescription)
    }

    @Test func canonicalDestinationSelectionIsDeterministic() throws {
        let analyzedDestinationPaths = Locked<[[String]]>([])
        let store = InMemoryPhotographerJobStore()
        let viewModel = PhotographerJobViewModel(
            store: store,
            now: { now },
            confirmedAnalyzer: { rows in
                analyzedDestinationPaths.mutate { $0.append(rows.compactMap(\.destinationPath)) }
                return "confirmed"
            },
            workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography)
        )
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)
        try viewModel.prepareCard(photographerName: "Mike", cameraName: "Sony A7 IV", analysis: analysis("preliminary"))
        viewModel.beginIngest(destinationCount: 2)
        let secondary = verifiedRow(path: "/card/A.ARW", checksum: "abc", destination: "Secondary")
        let primary = verifiedRow(path: "/card/A.ARW", checksum: "abc", destination: "Primary")

        try viewModel.completeIngest(results: [secondary, primary])

        #expect(analyzedDestinationPaths.value == [["/primary/\(renderedPackage)/A.ARW"]])
    }

    @Test func resetClearsCardSpecificStateAndKeepsJobForNextCard() throws {
        let store = InMemoryPhotographerJobStore()
        let viewModel = preparedViewModel(store: store)
        let jobID = viewModel.activeJob?.id

        viewModel.resetForNextCard()

        #expect(viewModel.activeJob?.id == jobID)
        #expect(viewModel.activeCardDraft == nil)
        #expect(viewModel.renderedRecipe == nil)
        #expect(viewModel.preliminaryAnalysis == nil)
        #expect(viewModel.duplicateWarning == nil)
        #expect(viewModel.cameraName.isEmpty)
    }

    @Test func completionWithoutAnActivePreparedCardFailsClosed() throws {
        let viewModel = preparedViewModel(store: InMemoryPhotographerJobStore())
        viewModel.resetForNextCard()

        #expect(throws: PhotographerJobViewModelError.noActiveCard) {
            try viewModel.completeIngest(results: [])
        }
    }

    private func makeViewModel(store: InMemoryPhotographerJobStore) -> PhotographerJobViewModel {
        PhotographerJobViewModel(store: store, now: { now }, workflowDefaults: .isolatedWorkflowDefaults(remembering: .photography))
    }

    private func summaryJob(id: UUID, cardID: UUID, updatedAt: Date) -> PhotographerJob {
        PhotographerJob(
            id: id,
            eventDate: eventDate,
            clientName: "Client",
            jobName: "Background Job",
            eventType: .wedding,
            photographers: [],
            recipe: .wedding,
            requiredLocalCopyCount: 2,
            cardIngests: [CardIngest(
                id: cardID,
                provenance: CardProvenance(
                    photographerID: UUID(), photographerName: "Photographer", cameraName: "Camera",
                    cardNumber: 1, preliminaryFingerprint: nil, confirmedFingerprint: "fingerprint"
                ),
                sourceDisplayName: "Card 1", renderedRelativePath: "Jobs/Background",
                localState: .locallySafe, startedAt: eventDate, locallySafeAt: eventDate,
                fileCount: 1, totalBytes: 10, verifiedDestinationCount: 2
            )],
            createdAt: eventDate,
            updatedAt: updatedAt
        )
    }

    private func summaryItem(
        jobID: UUID,
        cardID: UUID,
        targetID: UUID,
        manifest: RemoteManifest,
        entry: RemoteManifestEntry,
        state: RemoteBackupState,
        uploadedBytes: Int64
    ) -> RemoteQueueItem {
        let final = try! manifest.packageRelativePath.appending(path: entry.relativePath)
        let temporary = try! RemoteRelativePath(components: Array(final.components.dropLast()) + [".temporary"])
        return RemoteQueueItem(
            id: UUID(), jobID: jobID, cardIngestID: cardID, destinationProfileID: targetID,
            manifestID: manifest.id, manifestEntryID: entry.id,
            localArtifactBookmarkReference: "bookmark", localArtifactRelativePath: entry.relativePath,
            remoteRelativePath: final, temporaryRemoteRelativePath: temporary,
            state: state, uploadedByteCount: uploadedBytes, retryCount: 0, nextAttemptAt: nil,
            verificationEvidence: .none, errorSummary: nil, createdAt: now, updatedAt: now
        )
    }

    private func preparedViewModel(
        store: InMemoryPhotographerJobStore,
        sourcePaths: [String] = ["/card/A.ARW"]
    ) -> PhotographerJobViewModel {
        let viewModel = makeViewModel(store: store)
        viewModel.createWeddingJob(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate)
        try! viewModel.prepareCard(
            photographerName: "Mike",
            cameraName: "Sony A7 IV",
            analysis: analysis("preliminary", sourcePaths: sourcePaths)
        )
        return viewModel
    }

    private func analysis(_ fingerprint: String, sourcePaths: [String] = ["/card/A.ARW"]) -> CardAnalysis {
        CardAnalysis(fingerprint: fingerprint, fileCount: sourcePaths.count, totalBytes: 100, companionGroups: [], sourcePaths: sourcePaths)
    }

    private func setupSignature() -> PhotographerSetupSignature {
        PhotographerSetupSignature(clientName: "Smith", jobName: "Smith Wedding", eventDate: eventDate, photographerName: "Mike", cameraName: "Sony A7 IV", cardNumber: 1, recipe: .wedding)
    }

    private func verifiedRows(destinationNames: [String]) -> [ResultRow] {
        destinationNames.map { destination in
            ResultRow(
                path: "/card/A.ARW",
                status: "✅ Verified",
                size: 100,
                checksum: "abc",
                destination: destination,
                destinationPath: "/\(destination.lowercased())/\(renderedPackage)/A.ARW"
            )
        }
    }

    private func verifiedRow(path: String, checksum: String, destination: String) -> ResultRow {
        ResultRow(
            path: path,
            status: "✅ Verified",
            size: 100,
            checksum: checksum,
            destination: destination,
            destinationPath: "/\(destination.lowercased())/\(renderedPackage)/\((path as NSString).lastPathComponent)"
        )
    }
}

private final class AsyncSetupGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

private extension PhotographerLocalState {
    static let terminalStates: [PhotographerLocalState] = [.locallySafe, .issues, .cancelled]
}

private enum TestStoreError: LocalizedError {
    case saveFailed

    var errorDescription: String? { "The test store rejected the save." }
}

@MainActor
final class InMemoryPhotographerJobStore: PhotographerJobStore {
    private(set) var storedJobs: [PhotographerJob] = []
    private(set) var storedPresets: [PhotographerPreset] = []
    private(set) var storedManifests: [RemoteManifest] = []
    private(set) var saveCount = 0
    var errorOnSave: Error?

    func jobs() throws -> [PhotographerJob] { storedJobs }

    func save(_ job: PhotographerJob) throws {
        if let errorOnSave { throw errorOnSave }
        saveCount += 1
        if let index = storedJobs.firstIndex(where: { $0.id == job.id }) {
            storedJobs[index] = job
        } else {
            storedJobs.append(job)
        }
    }

    func deleteJob(id: UUID) throws {
        storedJobs.removeAll { $0.id == id }
    }

    func presets() throws -> [PhotographerPreset] { storedPresets }

    func save(_ preset: PhotographerPreset) throws {
        if let index = storedPresets.firstIndex(where: { $0.id == preset.id }) {
            storedPresets[index] = preset
        } else {
            storedPresets.append(preset)
        }
    }

    func manifests() throws -> [RemoteManifest] { storedManifests }

    func save(_ manifest: RemoteManifest) throws {
        if let index = storedManifests.firstIndex(where: { $0.id == manifest.id }) {
            storedManifests[index] = manifest
        } else {
            storedManifests.append(manifest)
        }
    }
}

@MainActor
private final class DeferredPhotographerJobStore: PhotographerJobStore {
    private(set) var storedJobs: [PhotographerJob]
    private var observers: [() -> Void] = []
    private var available = false

    init(storedJobs: [PhotographerJob]) {
        self.storedJobs = storedJobs
    }

    var isAvailable: Bool { available }

    func whenAvailable(_ action: @escaping () -> Void) {
        if available {
            action()
        } else {
            observers.append(action)
        }
    }

    func becomeAvailable() {
        available = true
        let pendingObservers = observers
        observers.removeAll()
        pendingObservers.forEach { $0() }
    }

    func jobs() throws -> [PhotographerJob] {
        guard available else { throw PhotographerStoreError.persistentStoreUnavailable }
        return storedJobs
    }

    func save(_ job: PhotographerJob) throws {
        guard available else { throw PhotographerStoreError.persistentStoreUnavailable }
        if let index = storedJobs.firstIndex(where: { $0.id == job.id }) {
            storedJobs[index] = job
        } else {
            storedJobs.append(job)
        }
    }

    func deleteJob(id: UUID) throws {
        guard available else { throw PhotographerStoreError.persistentStoreUnavailable }
        storedJobs.removeAll { $0.id == id }
    }

    func presets() throws -> [PhotographerPreset] {
        guard available else { throw PhotographerStoreError.persistentStoreUnavailable }
        return []
    }

    func save(_: PhotographerPreset) throws {
        guard available else { throw PhotographerStoreError.persistentStoreUnavailable }
    }
}
