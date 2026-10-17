import Foundation
import Testing
@testable import BitMatch

#if os(macOS)
@MainActor
struct VolumeMonitorReconciliationTests {
    private let path = URL(fileURLWithPath: "/Volumes/REUSED-CARD")

    private func mount(_ identity: String?) -> VolumeMonitorService.MountedVolume {
        .init(url: path, identity: identity)
    }

    @Test func missedUnmountAndReplacementAtSamePathIsRediscovered() {
        let old = mount("old-device:old-uuid")
        let replacement = mount("new-device:new-uuid")
        let plan = VolumeMonitorService.reconciliation(
            mounted: [replacement], published: [old.path: old.identity!],
            pending: [:], knownPaths: [old.path]
        )

        #expect(plan.stalePaths == [old.path])
        #expect(plan.toAnalyze.map(\.identity) == [replacement.identity])
        #expect(!VolumeMonitorService.acceptsAnalysis(old, mounted: [replacement]))
        #expect(VolumeMonitorService.acceptsAnalysis(replacement, mounted: [replacement]))
    }

    @Test func repeatedEventForSameMountDoesNotDuplicateAnalysis() {
        let card = mount("same-device:same-uuid")
        let published = VolumeMonitorService.reconciliation(
            mounted: [card], published: [card.path: card.identity!],
            pending: [:], knownPaths: [card.path]
        )
        #expect(published.stalePaths.isEmpty)
        #expect(published.toAnalyze.isEmpty)

        let pending = VolumeMonitorService.reconciliation(
            mounted: [card], published: [:],
            pending: [card.path: card.identity!], knownPaths: []
        )
        #expect(pending.toAnalyze.isEmpty)
    }

    @Test func explicitRefreshRetriesKnownMountAfterAccessChanges() {
        let card = mount("same-device:same-uuid")
        let normal = VolumeMonitorService.reconciliation(
            mounted: [card], published: [card.path: card.identity!],
            pending: [:], knownPaths: [card.path]
        )
        #expect(normal.toAnalyze.isEmpty)

        let refresh = VolumeMonitorService.reconciliation(
            mounted: [card], published: [card.path: card.identity!],
            pending: [:], knownPaths: [card.path], forceAnalysis: true
        )
        #expect(refresh.stalePaths.isEmpty)
        #expect(refresh.toAnalyze.map(\.identity) == [card.identity])

        // An access grant can race an analysis started before the grant.
        // Refresh must start a replacement and retire the old request even
        // though the filesystem identity is unchanged.
        let pendingRefresh = VolumeMonitorService.reconciliation(
            mounted: [card], published: [card.path: card.identity!],
            pending: [card.path: card.identity!], knownPaths: [card.path],
            forceAnalysis: true
        )
        #expect(pendingRefresh.toAnalyze.map(\.identity) == [card.identity])
        #expect(!VolumeMonitorService.acceptsAnalysisRequest(1, current: 2))
        #expect(VolumeMonitorService.acceptsAnalysisRequest(2, current: 2))
    }

    @Test func missingIdentityDropsStaleCardWithoutPublishingAnother() {
        let old = mount("old-device:old-uuid")
        let unresolved = mount(nil)
        let plan = VolumeMonitorService.reconciliation(
            mounted: [unresolved], published: [old.path: old.identity!],
            pending: [:], knownPaths: [old.path]
        )
        #expect(plan.stalePaths == [old.path])
        #expect(plan.toAnalyze.isEmpty)
        #expect(!VolumeMonitorService.acceptsAnalysis(old, mounted: [unresolved]))
    }

    @Test func disappearedMountClearsPublishedIdentityAfterItsRowWasRemoved() {
        let old = mount("old-device:old-uuid")
        let plan = VolumeMonitorService.reconciliation(
            mounted: [], published: [old.path: old.identity!],
            pending: [:], knownPaths: []
        )
        #expect(plan.stalePaths == [old.path])
        #expect(plan.toAnalyze.isEmpty)
    }

    @Test func cardWithoutVolumeUUIDCannotEnterAutomaticQueue() {
        // A device number alone is not a durable card identity. Discovery may
        // show the card, but automatic queueing requires a volume UUID.
        let volume = ConnectedDrivesPresentation.Volume(
            name: "Card", url: path, totalBytes: 64, freeBytes: 32,
            isRemovable: true, isInternal: false, volumeID: nil, cameraName: "Camera"
        )
        let rows = ConnectedDrivesPresentation.make(
            volumes: [volume], sourceURL: nil, destinationURLs: []
        )
        #expect(AutoQueuePolicy.candidates(
            eligibleRows: rows, seenVolumeIDs: [], activeDestinationVolumeIDs: []
        ).isEmpty)
    }

    @Test func replacedSelectedSourceIsClearedButSameCardIsKept() {
        let shared = SharedAppCoordinator(
            platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            projectStore: InMemoryPhotographerJobStore(),
            defaults: .isolatedWorkflowDefaults()
        )
        let model = MacVolumeAccessModel(shared: shared, enableVolumeMonitoring: false)
        var liveIdentity = "old-device:old-uuid"
        model.sourceMountIdentity = { _ in liveIdentity }
        shared.sourceURL = path

        model.handleConnectedVolumesUpdate([])
        #expect(shared.sourceURL == path)

        // Neither an unmount event nor a path disappearance is delivered:
        // the next snapshot already has a different card at the same path.
        liveIdentity = "new-device:new-uuid"
        model.handleConnectedVolumesUpdate([])
        #expect(shared.sourceURL == nil)
    }
}
#endif
