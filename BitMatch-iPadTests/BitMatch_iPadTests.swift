//
//  BitMatch_iPadTests.swift
//  BitMatch-iPadTests
//
//  Created by Mike Cerisano on 8/28/25.
//

import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch_iPad

struct BitMatch_iPadTests {

    @Test @MainActor func coordinatorPreservesUnconfirmedCardWhenRecoveredHistoryCannotBeSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "BitMatch-iPadTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPhotographerJobStore(defaults: defaults)
        let jobID = UUID(), cardID = UUID()
        var card = CardIngest(id: cardID, provenance: CardProvenance(
            photographerID: UUID(), photographerName: "P", cameraName: "C", cardNumber: 1,
            preliminaryFingerprint: nil, confirmedFingerprint: "proof"),
            sourceDisplayName: "Card", renderedRelativePath: "Card", localState: .locallySafe,
            startedAt: Date(), locallySafeAt: Date(), fileCount: 1, totalBytes: 1, verifiedDestinationCount: 2)
        card.historySettled = false
        let job = PhotographerJob(id: jobID, eventDate: Date(), clientName: "Client", jobName: "Job",
            eventType: .wedding, photographers: [], recipe: .wedding, requiredLocalCopyCount: 2,
            cardIngests: [card], createdAt: Date(), updatedAt: Date())
        try store.save(job)
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(), source: try LocalTransferResource(url: root),
            destinations: [try LocalTransferResource(url: root)], verificationMode: .standard,
            cameraSettings: .init(), reportSettings: .init(), projectID: jobID, projectCardID: cardID)
        record.state = .running
        let file = root.appendingPathComponent("history.json")
        try JSONEncoder().encode([record]).write(to: file)
        let journal = LocalTransferJournal(fileURL: file, beforeRecoveryPersist: { throw CocoaError(.fileWriteUnknown) })
        #expect(!journal.historyAvailable)
        #expect(journal.records.first?.state == .interrupted)
        let coordinator = SharedAppCoordinator(platformManager: IOSPlatformManager.shared,
            transferJournal: journal, projectStore: store, defaults: defaults)
        #expect(coordinator.photographerJobViewModel.activeJob?.cardIngests.first?.localState == .locallySafe)
        #expect(coordinator.photographerJobViewModel.activeJob?.cardIngests.first?.historySettled == false)
        #expect(try store.jobs().first?.cardIngests.first?.localState == .locallySafe)
    }

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test @MainActor func drivePickerDelegateIsRetainedWhilePresented() async throws {
        #if os(iOS)
        IOSDriverScanner.clearRetainedDrivePickerDelegateForTesting()
        _ = IOSDriverScanner.makeDrivePickerForTesting { _ in }
        #expect(IOSDriverScanner.hasRetainedDrivePickerDelegateForTesting)
        IOSDriverScanner.clearRetainedDrivePickerDelegateForTesting()
        #else
        #expect(true)
        #endif
    }

    @Test func navigationReflowsFromPhoneToTabletToWorkbench() {
        #expect(AdaptiveNavigationPolicy.presentation(for: 390) == .compact)
        #expect(AdaptiveNavigationPolicy.presentation(for: 744) == .toolbar)
        #expect(AdaptiveNavigationPolicy.presentation(for: 1_024) == .sidebar)
    }

    @Test func portraitPadUsesQueueBarToProtectSetupWidth() {
        let usesInspector = AdaptiveQueueLayoutPolicy.usesInspector(
            availableWidth: 834,
            isPad: true,
            isRegularWidth: true
        )
        #expect(!usesInspector)
    }

    @Test func widePadCanUseQueueInspector() {
        let usesInspector = AdaptiveQueueLayoutPolicy.usesInspector(
            availableWidth: 1_024,
            isPad: true,
            isRegularWidth: true
        )
        #expect(usesInspector)
    }

    @Test func iOSKeepsWaitingCardsOutOfTheSetupComposer() {
        #expect(!SetupQueuePlacementPolicy.showsComposerAdjacentQueue)
    }

    @Test @MainActor func portableProjectStoreRoundTripsProjectAndDestination() throws {
        let suiteName = "BitMatch-iPadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPhotographerJobStore(defaults: defaults)
        let job = PhotographerJob(
            id: UUID(), eventDate: .distantPast, clientName: "Acme", jobName: "Campaign",
            eventType: .wedding, photographers: [], recipe: .wedding,
            requiredLocalCopyCount: 2, cardIngests: [], createdAt: .distantPast, updatedAt: .distantPast
        )
        let profile = RemoteDestinationProfile(
            id: UUID(), name: "Studio archive", host: "archive.example", port: 22,
            username: "mike", root: try RemoteRelativePath(components: ["Backups"]), verificationMode: .sha256
        )

        try store.save(job)
        try store.save(profile)

        #expect(try store.jobs() == [job])
        #expect(try store.profiles() == [profile])
    }

    @Test @MainActor func unavailableRemoteCoordinatorPersistsTheChosenDestination() throws {
        let suiteName = "BitMatch-iPadTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPhotographerJobStore(defaults: defaults)
        let job = PhotographerJob(
            id: UUID(), eventDate: .distantPast, clientName: "Acme", jobName: "Campaign",
            eventType: .wedding, photographers: [], recipe: .wedding,
            requiredLocalCopyCount: 2, cardIngests: [], createdAt: .distantPast, updatedAt: .distantPast
        )
        let profile = RemoteDestinationProfile(
            id: UUID(), name: "Studio archive", host: "archive.example", port: 22,
            username: "mike", root: try RemoteRelativePath(components: ["Backups"]), verificationMode: .sha256
        )
        try store.save(job)
        try store.save(profile)

        let coordinator = UnavailableRemoteProjectCoordinator(store: store)
        let updated = try coordinator.selectRemoteProfile(profile.id, for: job.id)

        #expect(updated.remoteBackupConfiguration?.destinationProfileID == profile.id)
        #expect(updated.remoteBackupConfiguration?.isEnabled == true)
        #expect(try store.jobs().first?.remoteBackupConfiguration == updated.remoteBackupConfiguration)
    }

    @Test @MainActor func sharedCoordinatorOwnsPortableProjectWorkflow() {
        let suiteName = "BitMatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = SharedAppCoordinator(platformManager: IOSPlatformManager.shared, defaults: defaults)

        coordinator.photographerJobViewModel.createWeddingJob(
            clientName: "Acme",
            jobName: "Campaign",
            eventDate: .distantPast
        )

        #expect(coordinator.photographerJobViewModel.activeJob?.clientName == "Acme")
    }

    @Test @MainActor func sharedCoordinatorWillNotStartAnUnpreparedProjectTransfer() async {
        let suiteName = "BitMatchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = SharedAppCoordinator(platformManager: IOSPlatformManager.shared, defaults: defaults)

        let started = await coordinator.startProjectOperation()

        #expect(!started)
        #expect(!coordinator.isOperationInProgress)
    }

    @Test func projectWorkflowUsesTheSameProductLanguageAsMac() {
        #expect(TransferWorkflowPresentation.quick.title == "One-time transfer")
        #expect(TransferWorkflowPresentation.project.title == "Project transfer")
        #expect(TransferWorkflowPresentation.project.detail == "Organize cards by job and track copies")
    }

    @Test func notificationPermissionIsNotRequestedAtLaunch() {
        #expect(!NotificationPermissionPolicy.requestsAtLaunch)
    }

    @Test @MainActor func pickedButUnscannedFolderKeepsCompareDisabledOniOS() {
        let suiteName = "BitMatch-iPadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = SharedAppCoordinator(
            platformManager: IOSPlatformManager.shared,
            defaults: defaults
        )
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-ipad-compare-presentation", isDirectory: true)
        coordinator.leftURL = base.appendingPathComponent("card", isDirectory: true)
        coordinator.rightURL = base.appendingPathComponent("backup", isDirectory: true)

        let presentation = ComparePresentation.make(coordinator: coordinator)

        #expect(presentation.left.isLoading)
        #expect(presentation.right.isLoading)
        #expect(!presentation.readiness.canStart)

        ComparePresentation.startIfReady(coordinator)
        #expect(coordinator.currentMode == .copyAndVerify)
        #expect(!coordinator.isOperationInProgress)
    }

    @Test func completionEvidenceUsesTheSameSafetyGuidanceAsMac() {
        let success = CompletionVerdictPresentation.make(.success)
        let issues = CompletionVerdictPresentation.make(.issues)

        #expect(success.title == "The card is safe to erase")
        #expect(issues.title == "The card needs attention")
        #expect(issues.sourceGuidance == "Do not erase the card. These results don't establish a complete verified backup.")
    }

}
