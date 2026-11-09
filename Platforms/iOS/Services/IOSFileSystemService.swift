// IOSFileSystemService.swift - iOS-specific file system implementation
import Foundation
import UIKit
import UniformTypeIdentifiers
import BitMatchEngine

/// `@unchecked Sendable`: its only mutable state is `currentDelegate`, which
/// only the `@MainActor` picker methods touch.
final class IOSFileSystemService: NSObject, FileSystemService, @unchecked Sendable {
    static let shared = IOSFileSystemService()
    
    // Keep reference to delegate to prevent deallocation
    private var currentDelegate: DocumentPickerDelegate?
    
    private override init() {
        super.init()
    }
    
    // MARK: - FileSystemService Protocol Implementation
    
    @MainActor
    func selectSourceFolder() async -> URL? {
        return await selectFolder(allowMultiple: false).first
    }
    
    @MainActor
    func selectDestinationFolders() async -> [URL] {
        return await selectFolder(allowMultiple: true)
    }
    
    @MainActor
    func selectLeftFolder() async -> URL? {
        return await selectFolder(allowMultiple: false).first
    }
    
    @MainActor
    func selectRightFolder() async -> URL? {
        return await selectFolder(allowMultiple: false).first
    }
    
    func validateFileAccess(url: URL) async -> Bool {
        let canAccess = url.startAccessingSecurityScopedResource()
        if canAccess {
            url.stopAccessingSecurityScopedResource()
        }
        return canAccess
    }

    func startAccessing(url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
    
    func getFileList(from folderURL: URL) async throws -> [URL] {
        #if DEBUG
        let start = CFAbsoluteTimeGetCurrent()
        #endif

        // Acquire a single folder-level security scope
        guard folderURL.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "IOSFileSystemService", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot access security-scoped folder"
            ])
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        // Enumeration can block on slow external storage; run it on the
        // engine's bounded blocking executor, not a cooperative thread.
        let fileURLs = try await BoundedBlockingExecutor.shared.performCancellable { check in
            try CardSource.enumerateRegularFiles(base: folderURL, checkCancellation: check)
        }.map(\.url)

        #if DEBUG
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        SharedLogger.debug("IOSFileSystemService: enumerated \(fileURLs.count) files in \(elapsedMs) ms")
        #endif

        return fileURLs
    }
    
    // NOTE: copyFile removed - all copying uses DestinationWriter.copyAllSafely() for atomic writes
    // The previous implementation was dangerous: it deleted destination before copy, risking data loss

    nonisolated func getFileSize(for url: URL) throws -> Int64 {
        guard url.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "IOSFileSystemService", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "Cannot access file for size: \(url.lastPathComponent)"
            ])
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }
    
    nonisolated func createDirectory(at url: URL) throws {
        #if os(iOS)
        // Attempt to acquire a security scope for the folder to be created,
        // or fall back to its parent directory.
        let didStartScope = url.startAccessingSecurityScopedResource()
        let parentDidStartScope: Bool = {
            if !didStartScope {
                let parent = url.deletingLastPathComponent()
                return parent.startAccessingSecurityScopedResource()
            }
            return false
        }()
        defer {
            if didStartScope { url.stopAccessingSecurityScopedResource() }
            if parentDidStartScope { url.deletingLastPathComponent().stopAccessingSecurityScopedResource() }
        }
        #endif

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
    
    nonisolated func freeSpace(at url: URL) -> Int64 {
        do {
            // iOS: Attempt to access security scoped resource if needed
            #if os(iOS)
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            #endif
            
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            return Int64(values.volumeAvailableCapacity ?? 0)
        } catch {
            SharedLogger.error("Error checking free space for \(url.path): \(error)")
            return 0
        }
    }
    
    // MARK: - Private iOS-specific Implementation
    
    @MainActor
    private func selectFolder(allowMultiple: Bool) async -> [URL] {
        return await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = allowMultiple
            
            // Create and retain the delegate
            let delegate = DocumentPickerDelegate { urls in
                // Clear the delegate reference after completion
                self.currentDelegate = nil
                continuation.resume(returning: urls)
            }
            
            // Retain the delegate
            self.currentDelegate = delegate
            picker.delegate = delegate
            
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let windows = scenes.flatMap { $0.windows }
            let rootViewController = windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windows.first?.rootViewController
            if let rootViewController = rootViewController {
                let presenter = topViewController(from: rootViewController)
                presenter.present(picker, animated: true)
            } else {
                // Clear delegate if we can't present
                self.currentDelegate = nil
                continuation.resume(returning: [])
            }
        }
    }
}

@MainActor
private func topViewController(from root: UIViewController) -> UIViewController {
    var current = root
    while let presented = current.presentedViewController {
        current = presented
    }
    return current
}

// MARK: - Document Picker Delegate
private class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let completion: ([URL]) -> Void
    
    init(completion: @escaping ([URL]) -> Void) {
        self.completion = completion
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        completion(urls)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion([])
    }
}
