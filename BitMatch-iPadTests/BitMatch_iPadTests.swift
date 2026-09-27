//
//  BitMatch_iPadTests.swift
//  BitMatch-iPadTests
//
//  Created by Mike Cerisano on 8/28/25.
//

import Foundation
import Testing
@testable import BitMatch_iPad

struct BitMatch_iPadTests {

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
        let coordinator = SharedAppCoordinator()

        coordinator.photographerJobViewModel.createWeddingJob(
            clientName: "Acme",
            jobName: "Campaign",
            eventDate: .distantPast
        )

        #expect(coordinator.photographerJobViewModel.activeJob?.clientName == "Acme")
    }

    @Test @MainActor func sharedCoordinatorWillNotStartAnUnpreparedProjectTransfer() async {
        let coordinator = SharedAppCoordinator()

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

    @Test func activeTransferUsesTheSamePauseAndVerificationLanguageAsMac() {
        let paused = TransferOperationPresentation.make(state: .copying, isPaused: true)
        let verifying = TransferOperationPresentation.make(state: .verifying, isPaused: false)

        #expect(paused.title == "Transfer paused")
        #expect(paused.controlTitle == "Resume")
        #expect(verifying.title == "Verifying")
        #expect(verifying.controlTitle == "Pause")
    }

    @Test func completionEvidenceUsesTheSameSafetyGuidanceAsMac() {
        let success = CompletionVerdictPresentation.make(.success)
        let issues = CompletionVerdictPresentation.make(.issues)

        #expect(success.title == "The card is safe to erase")
        #expect(issues.title == "The card needs attention")
        #expect(issues.sourceGuidance == "Do not erase the card until every file below is resolved.")
    }

}
