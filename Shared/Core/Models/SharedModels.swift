// SharedModels.swift - Core shared models for both macOS and iPad
import Foundation
import SwiftUI

// Import specialized model files
// These imports make all models available throughout the app
// while keeping the code organized in focused files

// MARK: - App Mode
enum AppMode: String, CaseIterable, Identifiable {
    case copyAndVerify = "Copy & Verify"
    case compareFolders = "Check"
    case masterReport = "Master Report"
    
    var id: String { self.rawValue }
    
    var systemImage: String {
        switch self {
        case .copyAndVerify: return "doc.on.doc"
        case .compareFolders: return "folder.badge.questionmark"
        case .masterReport: return "doc.text.magnifyingglass"
        }
    }
    
    var description: String {
        switch self {
        case .copyAndVerify: return "Copy files and verify integrity"
        case .compareFolders: return "Check a folder against saved checksums or another folder"
        case .masterReport: return "Generate comprehensive transfer reports"
        }
    }
    
    /// The mode's name on every platform's mode switcher (the Mac menu and
    /// iPad/iPhone tabs say the same thing).
    var shortTitle: String { rawValue }
    
    #if os(iOS)
    static var supportedModes: [AppMode] {
        return [.copyAndVerify, .compareFolders]
    }
    #endif
    
    #if os(macOS)
    static var supportedModes: [AppMode] {
        return AppMode.allCases
    }
    #endif
}

// MARK: - Folder Info
struct FolderInfo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileCount: Int
    let totalSize: Int64
    let lastModified: Date
    let isInternalDrive: Bool
    
    var name: String { url.lastPathComponent }
    var formattedSize: String {
        ByteCountPresentation.fileSize(totalSize)
    }
    var formattedFileCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: fileCount)) ?? "\(fileCount)"
    }
    
    static func == (lhs: FolderInfo, rhs: FolderInfo) -> Bool {
        lhs.url == rhs.url
    }
}

// MARK: - Enhanced Folder Info
struct EnhancedFolderInfo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileCount: Int
    let totalSize: Int64
    let lastModified: Date
    let isInternalDrive: Bool
    
    // Enhanced metadata
    let fileTypeBreakdown: [String: Int] // File extension -> count
    let largestFile: (name: String, size: Int64)?
    let oldestFileDate: Date?
    let newestFileDate: Date?
    
    var name: String { url.lastPathComponent }
    var formattedSize: String {
        ByteCountPresentation.fileSize(totalSize)
    }
    var formattedFileCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: fileCount)) ?? "\(fileCount)"
    }
    
    var topFileTypes: [(type: String, count: Int)] {
        Array(fileTypeBreakdown.sorted { $0.value > $1.value }.prefix(3))
            .map { (type: $0.key, count: $0.value) }
    }
    
    var averageFileSize: Int64 {
        fileCount > 0 ? totalSize / Int64(fileCount) : 0
    }
    
    var formattedAverageFileSize: String {
        ByteCountPresentation.fileSize(averageFileSize)
    }
    
    var formattedLargestFile: String {
        guard let largest = largestFile else { return "No files" }
        let size = ByteCountPresentation.fileSize(largest.size)
        return "\(largest.name) (\(size))"
    }
    
    var dateRangeDescription: String {
        guard let oldest = oldestFileDate, let newest = newestFileDate else {
            return "No date info"
        }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        
        if Calendar.current.isDate(oldest, inSameDayAs: newest) {
            return "All from \(formatter.string(from: oldest))"
        } else {
            return "\(formatter.string(from: oldest)) - \(formatter.string(from: newest))"
        }
    }
    
    static func == (lhs: EnhancedFolderInfo, rhs: EnhancedFolderInfo) -> Bool {
        lhs.url == rhs.url
    }
}

// MARK: - Notifications
extension NSNotification.Name {
    static let cameraCardDetected = NSNotification.Name("cameraCardDetected")
    static let operationCancelledByUser = NSNotification.Name("operationCancelledByUser")
    static let operationCompleted = NSNotification.Name("operationCompleted")
}

// MARK: - FolderInfo Compatibility Extension
extension EnhancedFolderInfo {
    /// Extensions counted as video, upper-cased as `fileTypeBreakdown` keys are.
    static let videoExtensions: Set<String> = [
        "MOV", "MP4", "MXF", "R3D", "BRAW", "ARI", "AVI", "M4V", "HEVC", "HEIC", "PRORES", "DNXHD"
    ]

    /// Video files in the folder. Zero until the full scan (with its
    /// extension breakdown) has finished.
    var videoFileCount: Int {
        fileTypeBreakdown.reduce(0) { total, entry in
            Self.videoExtensions.contains(entry.key) ? total + entry.value : total
        }
    }

    /// Convert to base FolderInfo for backward compatibility
    var asFolderInfo: FolderInfo {
        return FolderInfo(
            url: url,
            fileCount: fileCount,
            totalSize: totalSize,
            lastModified: lastModified,
            isInternalDrive: isInternalDrive
        )
    }
}
