// Core/Services/Camera/PanasonicDetectionService.swift
import Foundation
import BitMatchEngine

/// Specialized service for detecting Panasonic cameras via metadata and folder structure
final class PanasonicDetectionService: Sendable {
    static let shared = PanasonicDetectionService()
    private init() {}
    
    // MARK: - Public Interface
    
    func detectPanasonicCamera(at url: URL) -> String? {
        if let metadataInfo = checkPanasonicMetadata(at: url) {
            return metadataInfo
        }
        
        // Folder shape is CardLayoutClassifier's job. The old rule here
        // counted DCIM + MISC as Panasonic, which almost every DCIM card
        // writes (audit finding D).
        return nil
    }
    
    // MARK: - Panasonic Metadata Detection
    
    private func checkPanasonicMetadata(at url: URL) -> String? {
        // Check for Panasonic-specific metadata files
        let panasonicMetadataFiles = [
            "PRIVATE/PANASONIC/MISC/DPOF.DAT",
            "MISC/PANASONIC.DAT",
            "PRIVATE/MISC/INFO.DAT"
        ]
        
        var foundReadableSidecar = false
        for metadataFile in panasonicMetadataFiles {
            guard !Task.isCancelled else { return nil }
            let metadataPath = url.appendingPathComponent(metadataFile)
            
            if let metadataData = AdvisoryMetadataFileReader.read(metadataPath) {
                guard !Task.isCancelled else { return nil }
                foundReadableSidecar = true
                if let cameraModel = extractPanasonicModelFromMetadata(metadataData) {
                    return "Panasonic \(cameraModel)"
                }
            }
        }

        if foundReadableSidecar { return "Panasonic" }
        
        // Check RW2/RAF files for metadata
        return checkPanasonicRAWFiles(at: url)
    }
    
    private func checkPanasonicRAWFiles(at url: URL) -> String? {
        let fm = FileManager.default
        let rawExtensions = ["RW2", "RAW"]
        
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { return nil }
                if rawExtensions.contains(fileURL.pathExtension.uppercased()) {
                    if let model = extractPanasonicModelFromRAW(fileURL) {
                        return "Panasonic \(model)"
                    }
                    return "Panasonic"
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Metadata Extraction
    
    private func extractPanasonicModelFromMetadata(_ metadataData: Data) -> String? {
        guard let metadataString = String(data: metadataData, encoding: .ascii) ?? String(data: metadataData, encoding: .utf8) else { return nil }
        let panasonicModels = [
            "DC-GH6": "GH6",
            "DC-GH5S": "GH5S",
            "DC-GH5": "GH5",
            "DC-G9": "G9",
            "DC-S1H": "S1H",
            "DC-S1R": "S1R",
            "DC-S1": "S1",
            "DC-S5": "S5",
            "DC-FZ2500": "FZ2500",
            "DC-FZ1000": "FZ1000",
            "DMC-GH4": "GH4",
            "DMC-GH3": "GH3",
            "DMC-G7": "G7",
            "DMC-G85": "G85"
        ]

        for (pattern, model) in panasonicModels {
            if metadataString.contains(pattern) {
                return model
            }
        }

        return nil
    }
    
    private func extractPanasonicModelFromRAW(_ rawFile: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: rawFile) else { return nil }
        defer { try? fileHandle.close() }
        
        let headerSize = 2048
        guard let headerData = try? fileHandle.read(upToCount: headerSize) else { return nil }
        
        guard let headerString = String(data: headerData, encoding: .ascii) else { return nil }
        
        let panasonicModels = [
            "PANASONIC": "",
            "DC-GH6": "GH6",
            "DC-GH5": "GH5",
            "DC-S1H": "S1H",
            "DC-S5": "S5"
        ]
        
        for (pattern, model) in panasonicModels {
            if headerString.contains(pattern) {
                return model.isEmpty ? nil : model
            }
        }
        
        return nil
    }
}

