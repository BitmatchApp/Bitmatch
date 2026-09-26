// TransferModels.swift - Transfer and reporting models
import Foundation
import BitMatchEngine

// MARK: - Transfer Metadata
struct TransferMetadata: Codable {
    let sourceURL: URL
    let destinationURLs: [URL]
    let startTime: Date
    let endTime: Date?
    let totalFiles: Int
    let totalSize: Int64
    let verificationMode: VerificationMode
    let cameraSettings: CameraLabelSettings?
    
    var duration: TimeInterval? {
        guard let endTime = endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }
}

// MARK: - Transfer Card
struct TransferCard: Identifiable {
    let id = UUID()
    let source: FolderInfo
    let destinations: [FolderInfo]
    let cameraCard: CameraCard?
    let metadata: TransferMetadata?
    let progress: Double
    let state: OperationState
    
    var cameraName: String {
        return cameraCard?.name ?? "Unknown Camera"
    }
    
    var totalSize: Int64 {
        return source.totalSize
    }
    
    var fileCount: Int {
        return source.fileCount
    }
    
    var timestamp: Date {
        return metadata?.startTime ?? Date()
    }
    
    var verified: Bool {
        switch state {
        case .completed(let info):
            return info.success
        default:
            return false
        }
    }
    
    var sourcePath: String {
        return source.url.path
    }
    
    var destinationPaths: [String] {
        return destinations.map { $0.url.path }
    }
    
    var formattedSize: String {
        return ByteCountPresentation.fileSize(totalSize)
    }
}

// MARK: - Result Outcome

enum AutomaticSourceSelectionPolicy {
    static func shouldSelect(
        automaticSelectionEnabled: Bool,
        hasExistingSource: Bool,
        isReadable: Bool
    ) -> Bool {
        automaticSelectionEnabled && !hasExistingSource && isReadable
    }
}

// MARK: - ResultRow Codable Extension
