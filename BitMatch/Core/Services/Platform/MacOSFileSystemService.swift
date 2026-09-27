// Core/Services/Platform/MacOSFileSystemService.swift
#if os(macOS)
import Foundation
import AppKit
import UserNotifications
import BitMatchEngine

final class MacOSFileSystemService: FileSystemService, Sendable {
    static let shared = MacOSFileSystemService()
    private init() {}
    
    func selectSourceFolder() async -> URL? {
        return await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select Source"
            panel.message = "Choose the folder to copy from"
            
            if panel.runModal() == .OK {
                return panel.url
            }
            return nil
        }
    }
    
    func selectDestinationFolders() async -> [URL] {
        return await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = "Select Destinations"
            panel.message = "Choose one or more destinations"
            
            if panel.runModal() == .OK {
                return panel.urls
            }
            return []
        }
    }
    
    func selectLeftFolder() async -> URL? {
        return await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select Left Folder"
            panel.message = "Choose the first folder to compare"
            
            if panel.runModal() == .OK {
                return panel.url
            }
            return nil
        }
    }
    
    func selectRightFolder() async -> URL? {
        return await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select Right Folder"
            panel.message = "Choose the second folder to compare"
            
            if panel.runModal() == .OK {
                return panel.url
            }
            return nil
        }
    }
    
    // Everything but the pickers is plain local-disk access.
    private let local = LocalFileAccess()

    func validateFileAccess(url: URL) async -> Bool {
        await local.validateFileAccess(url: url)
    }

    func startAccessing(url: URL) -> Bool {
        local.startAccessing(url: url)
    }

    func stopAccessing(url: URL) {
        local.stopAccessing(url: url)
    }

    func getFileList(from folderURL: URL) async throws -> [URL] {
        try await local.getFileList(from: folderURL)
    }

    nonisolated func getFileSize(for url: URL) throws -> Int64 {
        try local.getFileSize(for: url)
    }

    nonisolated func createDirectory(at url: URL) throws {
        try local.createDirectory(at: url)
    }

    nonisolated func freeSpace(at url: URL) -> Int64 {
        local.freeSpace(at: url)
    }
}

#endif
