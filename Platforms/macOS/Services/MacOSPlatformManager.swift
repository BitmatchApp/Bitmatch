// MacOSPlatformManager.swift - macOS platform coordination
import Foundation
import BitMatchEngine
#if os(macOS)
import AppKit

final class MacOSPlatformManager: PlatformManager, Sendable {
    static let shared = MacOSPlatformManager()
    
    // MARK: - Service Instances
    var fileSystem: FileSystemService {
        MacOSFileSystemService.shared
    }
    
    var checksum: ChecksumService {
        ChecksumEngine.shared
    }
    
    // Thread-safe lazy initialization via static let
    private static let _sharedFileOperations = TransferPipeline(
        fileSystem: MacOSFileSystemService.shared,
        checksum: ChecksumEngine.shared,
        pipelinedVerification: !UserDefaults.standard.bool(forKey: "DisablePipelinedVerify"),
        verificationConcurrency: UserDefaults.standard.integer(forKey: "BitMatchVerifyConcurrency")
    )
    private static let _sharedCameraDetection = SharedCameraDetectionService()

    var fileOperations: FileOperationsService {
        Self._sharedFileOperations
    }

    var cameraDetection: CameraDetectionService {
        Self._sharedCameraDetection
    }

    var supportsDragAndDrop: Bool {
        return true // macOS supports drag and drop
    }

    private init() {
        // Services are now initialized via static properties for thread safety
    }
    
    // MARK: - Platform-specific UI Methods
    
    func presentAlert(title: String, message: String) async {
        // A modal alert under XCTest blocks the whole run until a human clicks
        // OK. Tests should inject a silent PlatformManager; this is the safety
        // net for any path that still reaches the real one.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            SharedLogger.warning("Suppressed alert during tests: \(title) - \(message)", category: .ui)
            return
        }
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
    
    func presentError(_ error: Error) async {
        await presentAlert(title: "Error", message: error.localizedDescription)
    }
    
    func openURL(_ url: URL) async -> Bool {
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - macOS-specific Utilities
    
    func requestDocumentAccess() async -> Bool {
        // macOS document access setup if needed
        return true
    }
    
    func checkStoragePermissions() async -> Bool {
        // Check macOS storage permissions
        return true
    }
    
}
#endif
