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
    private var cancellables = Set<AnyCancellable>()

    init(
        shared: SharedAppCoordinator,
        detectionService: CameraCardDetectionService? = nil,
        startMonitoring: Bool = true
    ) {
        self.shared = shared
        // Built here, not as a default argument (evaluated off the main actor).
        self.detectionService = detectionService ?? CameraCardDetectionService()

        NotificationCenter.default.publisher(for: .cameraCardDetected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let cameraCard = notification.userInfo?["cameraCard"] as? CameraCard else { return }
                self?.cardDetected(at: cameraCard.mediaPath)
            }
            .store(in: &cancellables)

        if startMonitoring && shared.reportSettings.enableAutoCameraDetection {
            self.detectionService.startMonitoring()
        }
    }

    /// Selects a detected card as the source when the preferences allow it,
    /// nothing is chosen yet, and the card can actually be read.
    func cardDetected(at sourceURL: URL) {
        guard let shared, shared.reportSettings.enableAutoCameraDetection,
              !shared.isOperationInProgress, !shared.showsOutcomeSummary else { return }
        let shouldSelect = AutomaticSourceSelectionPolicy.shouldSelect(
            automaticSelectionEnabled: shared.reportSettings.autoPopulateSource,
            hasExistingSource: shared.sourceURL != nil,
            isReadable: FileManager.default.isReadableFile(atPath: sourceURL.path)
        )
        guard shouldSelect else {
            SharedLogger.info("Detected camera card is available, but BitMatch did not auto-select it without readable access.", category: .transfer)
            return
        }
        shared.sourceURL = sourceURL
    }

    func toggleCameraDetection(_ enabled: Bool) {
        shared?.reportSettings.enableAutoCameraDetection = enabled
        if enabled { detectionService.startMonitoring() }
        else { detectionService.stopMonitoring() }
    }

    func rescanForCameras() {
        detectionService.rescanVolumes()
    }
}
