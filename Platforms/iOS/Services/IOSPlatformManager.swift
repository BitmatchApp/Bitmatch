// IOSPlatformManager.swift - iOS platform coordination
import Foundation
import UIKit
import BitMatchEngine

final class IOSPlatformManager: PlatformManager, Sendable {
    static let shared = IOSPlatformManager()
    
    // MARK: - Service Instances
    var fileSystem: FileSystemService {
        IOSFileSystemService.shared
    }
    
    var checksum: ChecksumService {
        ChecksumEngine.shared
    }
    
    var fileOperations: FileOperationsService {
        _fileOperations
    }
    
    var cameraDetection: CameraDetectionService {
        _cameraDetection
    }
    
    var supportsDragAndDrop: Bool {
        return false // iOS/iPadOS has limited drag and drop support
    }
    
    private let _fileOperations: any FileOperationsService
    private let _cameraDetection: any CameraDetectionService
    
    private init() {
        self._fileOperations = TransferPipeline(
            fileSystem: IOSFileSystemService.shared,
            checksum: ChecksumEngine.shared,
            pipelinedVerification: !UserDefaults.standard.bool(forKey: "DisablePipelinedVerify"),
            verificationConcurrency: UserDefaults.standard.integer(forKey: "BitMatchVerifyConcurrency")
        )
        self._cameraDetection = SharedCameraDetectionService()
    }
    
    // MARK: - Platform-specific UI Methods
    
    func presentAlert(title: String, message: String) async {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                    continuation.resume()
                })

                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootViewController = windowScene.windows.first?.rootViewController {
                    rootViewController.present(alert, animated: true)
                } else {
                    continuation.resume()
                }
            }
        }
    }
    
    func presentError(_ error: Error) async {
        await presentAlert(title: "Error", message: error.localizedDescription)
    }
    
    func openURL(_ url: URL) async -> Bool {
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url) { success in
                        continuation.resume(returning: success)
                    }
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    // MARK: - iOS-specific Utilities
    
    func requestDocumentAccess() async -> Bool {
        // iOS-specific document access setup if needed
        return true
    }
    
    func checkStoragePermissions() async -> Bool {
        // Check iOS storage permissions
        return true
    }
    
}
