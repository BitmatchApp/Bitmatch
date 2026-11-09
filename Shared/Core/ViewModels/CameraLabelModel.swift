// Core/ViewModels/CameraLabelModel.swift
import Foundation
import Combine
import BitMatchEngine

/// The camera label for the next transfer, on every platform (thesis
/// decision, step 3). It suggests a label from the card, remembers the
/// label per camera by fingerprint, and saves the settings across launches
/// with the Mac's `destLabelSettings` key. `SharedAppCoordinator` owns it.
@MainActor
final class CameraLabelModel: ObservableObject {
    static let settingsKey = "destLabelSettings"

    /// Saved on every change, and remembered for the current camera.
    @Published var settings = CameraLabelSettings() {
        didSet { settingsDidChange() }
    }
    @Published private(set) var detectedCamera: CameraType = .generic
    @Published private(set) var currentFingerprint: CameraMemoryService.CameraFingerprint?
    /// The detected camera's clean display name ("Sony FX6"), for showing
    /// next to the source. Nil until detection finishes or when unknown.
    @Published private(set) var detectedCameraName: String?

    /// While true, changes are neither saved nor remembered (a queued
    /// transfer's replay applies its record's settings for that run only).
    var suspendsSaving = false

    private let defaults: UserDefaults
    /// Owned detection task and its generation: reselecting or clearing the
    /// source cancels the in-flight detection and only the latest may publish.
    private var detectionTask: Task<Void, Never>?
    private var detectionGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(CameraLabelSettings.self, from: data) {
            settings = saved
        }
    }

    // MARK: - Detection with memory

    /// Detection does filesystem enumeration and metadata reads that can
    /// block on a stalled card, so it runs on a bounded blocking worker
    /// rather than a detached task on the cooperative executor. The
    /// worker's explicit check replaces task cancellation inside the
    /// synchronous stages; a superseded detection's late result is still
    /// discarded by generation below.
    private static let detectionWorker = DriveAccessWorker(maxConcurrent: 2, maxQueued: 8, useBlockingThreads: true)

    private struct DetectionOutcome: Sendable {
        let detectedName: String?
        let fingerprint: CameraMemoryService.CameraFingerprint?
        let suggestion: CameraNamingService.CameraNamingResult?
    }

    func detectCameraWithMemory(at url: URL) {
        // Supersede any in-flight detection: only the latest source may
        // publish.
        let generation = supersedeDetection()
        let worker = Self.detectionWorker
        detectionTask = Task { [weak self] in
            let outcome: DetectionOutcome
            do {
                outcome = try await worker.performCancellable(
                    mountKeys: [DriveAccessWorker.mountKey(for: url)],
                    jobKey: "camera-detection.\(generation)"
                ) { check in
                    let isCancelled: @Sendable () -> Bool = {
                        do { try check(); return false } catch { return true }
                    }
                    let detectedName = CameraDetectionOrchestrator.shared.detectCamera(at: url, isCancelled: isCancelled)
                    try check()
                    // Then try to get the camera's fingerprint
                    let fingerprint = CameraMemoryService.shared.getCameraFingerprint(at: url)
                    try check()
                    // Folder-analysis naming suggestion.
                    let suggestion = CameraNamingService.getBestCameraSuggestion(for: url)
                    try check()
                    return DetectionOutcome(detectedName: detectedName, fingerprint: fingerprint, suggestion: suggestion)
                }
            } catch {
                return
            }
            let detectedName = outcome.detectedName
            let fingerprint = outcome.fingerprint
            let suggestion = outcome.suggestion
            let cameraType = Self.mapCameraNameToType(detectedName)
            let cleanName = detectedName.map { CleanCameraNameService.shared.getCleanCameraName(from: $0) }

            await MainActor.run { [weak self] in
                guard let self, generation == self.detectionGeneration else { return }
                self.detectedCamera = cameraType
                self.currentFingerprint = fingerprint
                self.detectedCameraName = cleanName

                // Check if we remember this specific camera
                if let fingerprint = fingerprint,
                   let rememberedLabel = CameraMemoryService.shared.getRememberedLabel(for: fingerprint) {
                    // We've seen this exact camera before! Use its remembered label
                    self.settings.label = rememberedLabel
                    SharedLogger.info("Recognized camera: \(fingerprint.displayName) → Auto-applied label: \"\(rememberedLabel)\"", category: .transfer)

                } else if self.settings.label.isEmpty {
                    // Try intelligent camera naming from video files first
                    if let cameraSuggestion = suggestion {
                        self.settings.label = cameraSuggestion.suggestedName
                        SharedLogger.info("Auto-detected camera designation: \(cameraSuggestion.cameraDesignation) from \(cameraSuggestion.sourceFilename)", category: .transfer)
                        SharedLogger.debug("Suggested folder name: \"\(cameraSuggestion.suggestedName)\" (confidence: \(cameraSuggestion.confidence * 100)%)", category: .transfer)

                    } else if cameraType != .generic {
                        // Fallback to model-based naming using clean camera names
                        if let cleanName {
                            self.settings.label = cleanName
                        } else {
                            self.settings.label = Self.cameraModelLabel(for: cameraType)
                        }
                    }
                    SharedLogger.info("New camera detected: \(cameraType.rawValue)", category: .transfer)
                }
            }
        }
    }

    /// No source: no label, no detected camera, and any detection still
    /// running for the previous source is dropped.
    func clearCameraLabel() {
        supersedeDetection()
        settings.label = ""
        detectedCamera = .generic
        currentFingerprint = nil
        detectedCameraName = nil
        SharedLogger.debug("Cleared camera label - no source selected", category: .transfer)
    }

    /// A setup snapshot clears only its source. Stop the old card's detection
    /// without clearing the camera label and folder settings being reused for
    /// the next composer card.
    func clearDetectionPreservingSettings() {
        supersedeDetection()
        detectedCamera = .generic
        currentFingerprint = nil
        detectedCameraName = nil
    }

    /// Cancels the in-flight detection and returns the generation a new one
    /// must match to publish.
    @discardableResult
    private func supersedeDetection() -> Int {
        detectionTask?.cancel()
        detectionTask = nil
        detectionGeneration += 1
        return detectionGeneration
    }

    // MARK: - Saving and memory

    private func settingsDidChange() {
        guard !suspendsSaving else { return }
        // Remember the label for this exact camera for next time.
        if let fingerprint = currentFingerprint, !settings.label.isEmpty {
            CameraMemoryService.shared.updateLabel(settings.label, for: fingerprint)
        }
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: Self.settingsKey)
        } catch {
            SharedLogger.error("Failed to save camera label settings: \(error)", category: .transfer)
        }
    }

    // MARK: - Camera Label Generation (Model-based, not position)
    private static func cameraModelLabel(for camera: CameraType) -> String {
        switch camera {
        case .sony: return "SONY"
        case .sonyFX6: return "FX6"
        case .sonyFX3: return "FX3"
        case .sonyA7S: return "A7S"
        case .canon: return "CANON"
        case .canonC70: return "C70"
        case .arri: return "ARRI"
        case .arriAlexa: return "ALEXA"
        case .arriAmira: return "AMIRA"
        case .red: return "RED"
        case .redCamera: return "RED"
        case .redDragon: return "RED"
        case .blackmagic: return "BMPCC"
        case .blackmagicPocket: return "BMPCC"
        case .panasonic: return "PANASONIC"
        case .fujifilm: return "FUJIFILM"
        case .nikon: return "NIKON"
        case .gopro: return "GOPRO"
        case .dji: return "DJI"
        case .insta360: return "INSTA360"
        case .genericDCIM: return "DCIM"
        case .genericMedia: return "MEDIA"
        case .generic: return ""
        }
    }

    // MARK: - Camera Type Mapping
    private nonisolated static func mapCameraNameToType(_ name: String?) -> CameraType {
        guard let name = name else { return .generic }

        let lowercased = name.lowercased()

        if lowercased.contains("arri") {
            if lowercased.contains("alexa") { return .arriAlexa }
            if lowercased.contains("amira") { return .arriAmira }
        }
        if lowercased.contains("red") && lowercased.contains("dragon") { return .redDragon }
        if lowercased.contains("sony") {
            if lowercased.contains("fx6") { return .sonyFX6 }
            if lowercased.contains("fx3") { return .sonyFX3 }
            if lowercased.contains("a7s") { return .sonyA7S }
        }
        if lowercased.contains("canon") && lowercased.contains("c70") { return .canonC70 }
        if lowercased.contains("blackmagic") && lowercased.contains("pocket") { return .blackmagicPocket }
        if lowercased.contains("dji") { return .dji }
        if lowercased.contains("gopro") { return .gopro }

        return .generic
    }
}
