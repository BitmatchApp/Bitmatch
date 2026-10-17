// Core/Services/Camera/CanonDetectionService.swift
import Foundation
import BitMatchEngine

/// Specialized service for detecting Canon cameras via metadata and folder structure
final class CanonDetectionService: Sendable {
    static let shared = CanonDetectionService()
    private init() {}
    
    // MARK: - Public Interface
    
    func detectCanonCamera(at url: URL) -> String? {
        if let metadataInfo = checkCanonMetadata(at: url) {
            return metadataInfo
        }
        
        // Folder shape is CardLayoutClassifier's job. The old DCIM + MISC
        // rule here called GoPro, DJI and Lumix cards by this brand
        // (audit finding D).
        return nil
    }
    
    // MARK: - Canon Metadata Detection
    
    private func checkCanonMetadata(at url: URL) -> String? {
        // Check for Canon-specific metadata files
        let canonMetadataFiles = [
            "MISC/CANON.INF",
            "MISC/CANONINF.DAT",
            "DCIM/CANONMSC/CANON.DAT"
        ]
        
        var foundReadableSidecar = false
        for metadataFile in canonMetadataFiles {
            guard !Task.isCancelled else { return nil }
            let metadataPath = url.appendingPathComponent(metadataFile)
            
            if let metadataData = AdvisoryMetadataFileReader.read(metadataPath) {
                guard !Task.isCancelled else { return nil }
                foundReadableSidecar = true
                if let cameraModel = extractCanonModelFromMetadata(metadataData) {
                    return "Canon \(cameraModel)"
                }
            }
        }

        if foundReadableSidecar { return "Canon" }
        
        // Check CR2/CR3 files for metadata
        return checkCanonRAWFiles(at: url)
    }
    
    private func checkCanonRAWFiles(at url: URL) -> String? {
        let fm = FileManager.default
        let rawExtensions = ["CR2", "CR3", "CRW"]
        
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { return nil }
                if rawExtensions.contains(fileURL.pathExtension.uppercased()) {
                    if let model = extractCanonModelFromRAW(fileURL) {
                        return "Canon \(model)"
                    }
                    return "Canon"
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Metadata Extraction
    
    private func extractCanonModelFromMetadata(_ metadataData: Data) -> String? {
        guard let metadataString = String(data: metadataData, encoding: .ascii) else { return nil }
        let canonModels = [
            "EOS R5": "R5",
            "EOS R6 Mark II": "R6 Mark II",
            "EOS R6": "R6",
            "EOS R8": "R8",
            "EOS R": "R",
            "EOS R10": "R10",
            "EOS R50": "R50",
            "5D Mark IV": "5D Mark IV",
            "5D4": "5D Mark IV",
            "1DX Mark III": "1DX Mark III",
            "90D": "90D",
            "80D": "80D",
            "M50 Mark II": "M50 Mark II",
            "M50": "M50",
            // Cinema/XF series
            "EOS C70": "C70",
            "C70": "C70",
            "EOS C300 Mark III": "C300 Mark III",
            "C300 Mark III": "C300 Mark III",
            "EOS C500 Mark II": "C500 Mark II",
            "C500 Mark II": "C500 Mark II",
            "XF605": "XF605",
            "XF705": "XF705"
        ]

        for (pattern, model) in canonModels {
            if metadataString.contains(pattern) {
                return model
            }
        }

        return nil
    }
    
    private func extractCanonModelFromRAW(_ rawFile: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: rawFile) else { return nil }
        defer { try? fileHandle.close() }
        
        let headerSize = 2048
        guard let headerData = try? fileHandle.read(upToCount: headerSize) else { return nil }
        
        guard let headerString = String(data: headerData, encoding: .ascii) else { return nil }
        
        let canonModels = [
            "Canon EOS R5": "R5",
            "Canon EOS R6": "R6",
            "Canon EOS R": "R",
            "Canon EOS 5D Mark IV": "5D Mark IV",
            "Canon EOS-1D X Mark III": "1DX Mark III",
            "Canon EOS 90D": "90D",
            "Canon EOS 80D": "80D",
            "Canon EOS M50": "M50"
        ]
        
        for (pattern, model) in canonModels {
            if headerString.contains(pattern) {
                return model
            }
        }
        
        return nil
    }
}
