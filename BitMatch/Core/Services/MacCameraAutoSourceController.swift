// MacCameraAutoSourceController.swift - Mac-only: use a detected camera card as the source
//
// iOS cannot watch mounted volumes, so this stays on the Mac. The switches
// (`enableAutoCameraDetection`, `autoPopulateSource`) are the shared
// ReportPrefs, and the chosen card is written to the shared coordinator's
// source; nothing is copied here.
import Foundation
import Combine
import BitMatchEngine

@MainActor
final class MacCameraAutoSourceController: ObservableObject {
    let detectionService: CameraCardDetectionService
    private weak var shared: SharedAppCoordinator?
    private weak var volumeAccess: MacVolumeAccessModel?
    private var cancellables = Set<AnyCancellable>()
    private let readabilityScheduler: BoundedVolumeProbeScheduler
    private let readabilityProbe: @Sendable (URL) -> Bool
    private var nextReadabilityRequest: UInt64 = 0
    private var pendingReadabilityRequests: [String: PendingReadabilityRequest] = [:]

    private struct PendingReadabilityRequest {
        let id: UInt64
        let cardID: UUID?
    }

    init(
        shared: SharedAppCoordinator,
        volumeAccess: MacVolumeAccessModel? = nil,
        detectionService: CameraCardDetectionService? = nil,
        startMonitoring: Bool = true,
        testReadabilityScheduler: BoundedVolumeProbeScheduler? = nil,
        testNotificationCenter: NotificationCenter = .default,
        readabilityProbe: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.isReadableFile(atPath: $0.path)
        }
    ) {
        self.shared = shared
        self.volumeAccess = volumeAccess
        readabilityScheduler = testReadabilityScheduler ?? BoundedVolumeProbeScheduler(
            maxConcurrent: 2, maxQueued: 8, reservedQueueSlots: 1
        )
        self.readabilityProbe = readabilityProbe
        // Built here, not as a default argument (evaluated off the main actor).
        self.detectionService = detectionService ?? CameraCardDetectionService()

        testNotificationCenter.publisher(for: .cameraCardDetected)
            .sink { [weak self] notification in
                guard let cameraCard = notification.userInfo?["cameraCard"] as? CameraCard else { return }
                self?.cardDetected(at: cameraCard.mediaPath, cardID: cameraCard.id)
            }
            .store(in: &cancellables)

        self.detectionService.$detectedCameraCards
            .sink { [weak self] cards in
                self?.retireRemovedCards(presentIDs: Set(cards.map(\.id)))
            }
            .store(in: &cancellables)

        shared.$sourceURL
            .dropFirst()
            .sink { [weak self] _ in self?.invalidatePendingReadabilityRequests() }
            .store(in: &cancellables)

        if startMonitoring && shared.reportSettings.enableAutoCameraDetection {
            self.detectionService.startMonitoring()
        }
    }

    /// Selects a detected card as the source when the preferences allow it,
    /// nothing is chosen yet, and the card can actually be read.
    func cardDetected(at sourceURL: URL) {
        scheduleAutoSelection(at: sourceURL, cardID: nil)
    }

    private func cardDetected(at sourceURL: URL, cardID: UUID) {
        scheduleAutoSelection(at: sourceURL, cardID: cardID)
    }

    private func scheduleAutoSelection(at sourceURL: URL, cardID: UUID?) {
        guard canAutomaticallySelectSource() else { return }
        if let cardID,
           !detectionService.detectedCameraCards.contains(where: { $0.id == cardID }) { return }

        nextReadabilityRequest &+= 1
        let requestID = nextReadabilityRequest
        let path = PathContainment.comparablePath(sourceURL.path)
        let key = Self.readabilityProbeKey(for: path)
        let probe = readabilityProbe
        let accepted = readabilityScheduler.enqueue(
            key: key,
            serialGroup: VolumeMonitorService.probeSerialGroup(for: sourceURL)
        ) { [weak self] in
            let isReadable = probe(sourceURL)
            await self?.finishAutoSelection(
                at: sourceURL, path: path, requestID: requestID,
                cardID: cardID, isReadable: isReadable
            )
        }
        guard accepted else {
            SharedLogger.info("Detected camera card was not auto-selected because bounded volume-probe capacity is full.", category: .transfer)
            return
        }
        pendingReadabilityRequests[path] = PendingReadabilityRequest(id: requestID, cardID: cardID)
    }

    private func finishAutoSelection(
        at sourceURL: URL, path: String, requestID: UInt64,
        cardID: UUID?, isReadable: Bool
    ) {
        guard pendingReadabilityRequests[path]?.id == requestID else { return }
        pendingReadabilityRequests.removeValue(forKey: path)
        guard canAutomaticallySelectSource(), isReadable else {
            if !isReadable {
                SharedLogger.info("Detected camera card is available, but BitMatch did not auto-select it without readable access.", category: .transfer)
            }
            return
        }
        if let cardID,
           !detectionService.detectedCameraCards.contains(where: { $0.id == cardID }) { return }
        shared?.sourceURL = sourceURL
    }

    private func canAutomaticallySelectSource() -> Bool {
        guard let shared,
              shared.reportSettings.enableAutoCameraDetection,
              shared.reportSettings.autoPopulateSource,
              volumeAccess?.needsDriveAccess != true,
              shared.sourceURL == nil,
              !shared.isOperationInProgress, !shared.showsOutcomeSummary else { return false }
        // The executor can become terminal before its journal record settles.
        // Finish is not safe to display yet, but a new card must not silently
        // replace the source until the operator starts a new transfer.
        if !shared.lastOperationWasCompare {
            switch shared.operationState {
            case .completed, .failed, .cancelled: return false
            default: break
            }
        }
        return true
    }

    private func retireRemovedCards(presentIDs: Set<UUID>) {
        let removedPaths = pendingReadabilityRequests.compactMap { path, pending -> String? in
            guard let cardID = pending.cardID, !presentIDs.contains(cardID) else { return nil }
            return path
        }
        for path in removedPaths {
            pendingReadabilityRequests.removeValue(forKey: path)
            let key = Self.readabilityProbeKey(for: path)
            readabilityScheduler.discardQueued { $0 == key }
        }
    }

    private func invalidatePendingReadabilityRequests() {
        pendingReadabilityRequests.removeAll()
        readabilityScheduler.discardQueued { $0.hasPrefix("auto-source-readability|") }
    }

    private static func readabilityProbeKey(for path: String) -> String {
        "auto-source-readability|\(path)"
    }

    /// Bounded settlement hook for deterministic tests. It does not cancel a
    /// synchronous filesystem call; test probes must always have release cleanup.
    func waitForReadabilityProbesForTesting(timeout: TimeInterval = 4) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while readabilityScheduler.runningCount > 0 || readabilityScheduler.queuedCount > 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func toggleCameraDetection(_ enabled: Bool) {
        shared?.reportSettings.enableAutoCameraDetection = enabled
        if !enabled {
            invalidatePendingReadabilityRequests()
        }
        if enabled { detectionService.startMonitoring() }
        else { detectionService.stopMonitoring() }
    }

    func rescanForCameras() {
        detectionService.rescanVolumes()
    }
}
