// Core/Services/Camera/CameraDetectionOrchestrator.swift
import Foundation

/// Main orchestrator for camera detection using hierarchical detection methods
final class CameraDetectionOrchestrator: Sendable {
    static let shared = CameraDetectionOrchestrator()
    private init() {}
    
    // MARK: - Detection Services
    private let unifiedMetadataDetection = UnifiedMetadataDetectionService.shared
    private let cleanNaming = CleanCameraNameService.shared
    private let fujiDetection = FujiDetectionService.shared
    private let sonyDetection = SonyDetectionService.shared
    private let canonDetection = CanonDetectionService.shared
    private let panasonicDetection = PanasonicDetectionService.shared
    private let arriDetection = ARRIDetectionService.shared
    private let fileNamingDetection = FileNamingDetectionService.shared
    private let fileExtensionDetection = FileExtensionDetectionService.shared
    private let folderStructureDetection = FolderStructureDetectionService.shared
    private let xmlMetadataDetection = XMLMetadataDetectionService.shared
    
    // MARK: - Public Interface
    
    /// Detect camera with full hierarchy of methods.
    /// Cooperative cancellation: every stage boundary checks the current
    /// task, so cancelling the caller's task stops the detection at the
    /// next boundary instead of running the full hierarchy. Outside a task
    /// context the checks are always false and behavior is unchanged.
    func detectCamera(at url: URL, isCancelled: @Sendable () -> Bool = { Task.isCancelled }) -> String? {
        guard !isCancelled() else { return nil }
        return detectCamera(at: url, layout: CardLayoutClassifier.classify(at: url), isCancelled: isCancelled)
    }

    /// Same as `detectCamera(at:)` with the card layout already classified,
    /// so a caller that also needs the layout lists the card once.
    func detectCamera(at url: URL, layout: CardLayoutMatch?,
                      isCancelled: @Sendable () -> Bool = { Task.isCancelled }) -> String? {
        guard !isCancelled() else { return nil }
        // A brand-unique layout marker decides the brand, ahead of
        // Spotlight and the heuristics below (audit findings C and D). The
        // stages after this only add a model name.
        if let layout, let brand = layout.brand {
            return label(forBrand: brand, cameraType: layout.cameraType, at: url, isCancelled: isCancelled)
        }

        // No brand marker: try the remaining methods in order of reliability.
        if let metadataInfo = unifiedMetadataDetection.detectCameraFromMetadata(at: url) { return metadataInfo }
        guard !isCancelled() else { return nil }
        if let fujiInfo = fujiDetection.detectFujiCamera(at: url) { return fujiInfo }
        guard !isCancelled() else { return nil }
        if let sonyInfo = sonyDetection.detectSonyCamera(at: url) { return sonyInfo }
        guard !isCancelled() else { return nil }
        if let canonInfo = canonDetection.detectCanonCamera(at: url) { return canonInfo }
        guard !isCancelled() else { return nil }
        if let panasonicInfo = panasonicDetection.detectPanasonicCamera(at: url) { return panasonicInfo }
        guard !isCancelled() else { return nil }
        if let arriInfo = arriDetection.detectARRICamera(at: url) { return arriInfo }
        guard !isCancelled() else { return nil }
        if let folderInfo = folderStructureDetection.detectCameraFromStructure(at: url) { return folderInfo }
        guard !isCancelled() else { return nil }
        if let nameInfo = fileNamingDetection.detectCameraFromNaming(at: url) { return nameInfo }
        guard !isCancelled() else { return nil }
        if let extInfo = fileExtensionDetection.detectCameraFromExtensions(at: url) { return extInfo }
        guard !isCancelled() else { return nil }
        if let xmlInfo = xmlMetadataDetection.detectCameraFromXML(at: url) { return xmlInfo }

        return nil
    }
    
    /// Brand plus model when a model reader for that brand, or Spotlight,
    /// names one. A reader's answer is used only when it agrees with the
    /// brand, so the label never contradicts the layout.
    private func label(forBrand brand: String, cameraType: CameraType, at url: URL,
                       isCancelled: @Sendable () -> Bool = { Task.isCancelled }) -> String? {
        let fromCard: String?
        switch cameraType {
        case .sony, .sonyFX6, .sonyFX3, .sonyA7S: fromCard = sonyDetection.detectSonyCamera(at: url)
        case .canon, .canonC70: fromCard = canonDetection.detectCanonCamera(at: url)
        case .panasonic: fromCard = panasonicDetection.detectPanasonicCamera(at: url)
        case .fujifilm: fromCard = fujiDetection.detectFujiCamera(at: url)
        case .arri, .arriAlexa, .arriAmira: fromCard = arriDetection.detectARRICamera(at: url)
        default: fromCard = nil
        }
        if let fromCard, fromCard.count > brand.count, fromCard.hasPrefix(brand + " ") {
            return fromCard
        }
        guard !isCancelled() else { return nil }
        if let metadata = unifiedMetadataDetection.detectCameraFromMetadata(at: url),
           metadata.range(of: brand, options: .caseInsensitive) != nil {
            return metadata
        }
        return brand
    }

    /// Get clean camera name for folder labeling
    func getCleanCameraName(from fullCameraName: String) -> String {
        return cleanNaming.getCleanCameraName(from: fullCameraName)
    }
    
}

// MARK: - Migration Notes
/*
 This orchestrator represents the refactoring of the monolithic CameraDetectionService.
 
 Completed:
 ✅ VideoMetadataDetectionService - Universal video metadata detection
 ✅ CleanCameraNameService - Camera name cleaning for folder labels
 ✅ FujiDetectionService - RAF file detection and metadata extraction
 ✅ SonyDetectionService - MEDIAPRO.XML and folder structure detection
 ✅ CanonDetectionService - Canon metadata and RAW file detection
 ✅ PanasonicDetectionService - Panasonic metadata and folder structure
 ✅ ARRIDetectionService - ALE file detection and metadata extraction
 ✅ FileNamingDetectionService - Camera detection via filename patterns
 ✅ FileExtensionDetectionService - Camera detection via file extensions
 ✅ FolderStructureDetectionService - Camera detection via directory structure
 
 ✅ XMLMetadataDetectionService - Generic XML metadata detection
 ✅ MediaMetadataDetectionService - Generic media file metadata detection
 
 Migration Complete:
 🎉 All detection methods now implemented in focused services
 🎉 Original CameraDetectionService reduced to thin compatibility wrapper
 🎉 Full modular architecture achieved
 
 This approach ensures:
 - Single Responsibility Principle
 - Easy testing of individual detection methods  
 - Cleaner code organization
 - Better maintainability as we add more cameras
 */