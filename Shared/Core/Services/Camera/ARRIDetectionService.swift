// Core/Services/Camera/ARRIDetectionService.swift
import Foundation

/// Specialized service for detecting ARRI cameras via ALE files and metadata
final class ARRIDetectionService: Sendable {
    static let shared = ARRIDetectionService()
    private init() {}
    
    // MARK: - Public Interface
    
    func detectARRICamera(at url: URL) -> String? {
        return checkForALEFile(at: url)
    }
    
    // MARK: - ALE File Detection
    
    private func checkForALEFile(at url: URL) -> String? {
        let fm = FileManager.default
        var foundGenericALE = false
        
        // Look for .ale files in the directory tree
        if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                guard !Task.isCancelled else { return nil }
                if fileURL.pathExtension.lowercased() == "ale" {
                    if let camera = extractCameraFromALE(aleFile: fileURL) {
                        if camera == "ARRI" {
                            foundGenericALE = true
                            continue
                        }
                        return camera
                    }
                }
            }
        }
        
        return Task.isCancelled ? nil : (foundGenericALE ? "ARRI" : nil)
    }
    
    private func extractCameraFromALE(aleFile: URL) -> String? {
        return autoreleasepool {
            guard let data = AdvisoryMetadataFileReader.read(aleFile),
                  let aleContent = String(data: data, encoding: .utf8),
                  !Task.isCancelled else { return nil }
            let lines = aleContent.components(separatedBy: .newlines)
            
            // Look for camera information in ALE metadata
            for line in lines {
                guard !Task.isCancelled else { return nil }
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                
                // Check for ARRI camera models in metadata. ALE files mix
                // case ("ALEXA Mini LF"), so compare in upper case.
                let upperLine = trimmedLine.uppercased()
                if upperLine.contains("ALEXA") {
                    let isLF = upperLine.range(of: #"\bLF\b"#, options: .regularExpression) != nil
                    if upperLine.contains("MINI LF") {
                        return "ARRI Alexa Mini LF"
                    } else if upperLine.contains("MINI") {
                        return "ARRI Alexa Mini"
                    } else if isLF {
                        return "ARRI Alexa LF"
                    } else {
                        return "ARRI Alexa"
                    }
                }
                
                if upperLine.contains("AMIRA") {
                    return "ARRI Amira"
                }
                
                // General ARRI detection
                if trimmedLine.lowercased().contains("arri") {
                    return "ARRI"
                }
                
                // Look for camera model in specific ALE fields
                if trimmedLine.hasPrefix("Camera") || trimmedLine.hasPrefix("Cam") {
                    if let cameraModel = extractARRIModelFromField(trimmedLine) {
                        return "ARRI \(cameraModel)"
                    }
                }
            }
            
            // If we found an ALE file but no specific camera model, assume ARRI
            return "ARRI"
        }
    }
    
    private func extractARRIModelFromField(_ field: String) -> String? {
        let fieldUpper = field.uppercased()
        
        if fieldUpper.contains("ALEXA MINI LF") { return "Alexa Mini LF" }
        if fieldUpper.contains("ALEXA MINI") { return "Alexa Mini" }
        if fieldUpper.contains("ALEXA LF") { return "Alexa LF" }
        if fieldUpper.contains("ALEXA") { return "Alexa" }
        if fieldUpper.contains("AMIRA") { return "Amira" }
        
        return nil
    }
}
