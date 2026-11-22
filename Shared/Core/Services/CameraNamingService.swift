// Core/Services/CameraNamingService.swift
import Foundation
import BitMatchEngine

struct CameraNamingService {
    
    // MARK: - Camera Naming Result
    struct CameraNamingResult: Sendable {
        let suggestedName: String
        let cameraDesignation: String
        let confidence: Float // 0.0 - 1.0
        let sourceFilename: String
    }
    
    // MARK: - Camera Naming Patterns
    private static let cameraPatterns: [(pattern: String, designation: String)] = [
        // A Camera variations
        ("A[_-]?CAM", "A-Cam"),
        ("ACAM", "A-Cam"),
        ("A[_-]?CAMERA", "A-Cam"),
        ("CAMERA[_-]?A", "A-Cam"),
        ("CAM[_-]?A", "A-Cam"),
        
        // B Camera variations
        ("B[_-]?CAM", "B-Cam"),
        ("BCAM", "B-Cam"),
        ("B[_-]?CAMERA", "B-Cam"),
        ("CAMERA[_-]?B", "B-Cam"),
        ("CAM[_-]?B", "B-Cam"),
        
        // C Camera variations
        ("C[_-]?CAM", "C-Cam"),
        ("CCAM", "C-Cam"),
        ("C[_-]?CAMERA", "C-Cam"),
        ("CAMERA[_-]?C", "C-Cam"),
        ("CAM[_-]?C", "C-Cam"),
        
        // D Camera variations
        ("D[_-]?CAM", "D-Cam"),
        ("DCAM", "D-Cam"),
        ("D[_-]?CAMERA", "D-Cam"),
        ("CAMERA[_-]?D", "D-Cam"),
        ("CAM[_-]?D", "D-Cam"),
        
        // Main/Master Camera variations
        ("MAIN[_-]?CAM", "Main"),
        ("MASTER[_-]?CAM", "Master"),
        ("PRIMARY[_-]?CAM", "Primary"),
        
        // Secondary Camera variations  
        ("SECONDARY[_-]?CAM", "Secondary"),
        ("SECOND[_-]?CAM", "Secondary"),
        ("BACKUP[_-]?CAM", "Backup"),
        
        // Specialty Camera variations
        ("WIDE[_-]?CAM", "Wide"),
        ("TIGHT[_-]?CAM", "Tight"),
        ("CLOSE[_-]?CAM", "Close-up"),
        ("MEDIUM[_-]?CAM", "Medium"),
        ("ESTABLISHING[_-]?CAM", "Establishing"),
        ("ROAMING[_-]?CAM", "Roaming"),
        ("HANDHELD[_-]?CAM", "Handheld"),
        ("STEADICAM", "Steadicam"),
        ("GIMBAL[_-]?CAM", "Gimbal"),
        ("DRONE[_-]?CAM", "Drone"),
        ("AERIAL[_-]?CAM", "Aerial"),
        
        // Angle-based variations
        ("HIGH[_-]?CAM", "High Angle"),
        ("LOW[_-]?CAM", "Low Angle"),
        ("OVERHEAD[_-]?CAM", "Overhead"),
        ("GROUND[_-]?CAM", "Ground Level"),
        
        // Position-based variations
        ("LEFT[_-]?CAM", "Left"),
        ("RIGHT[_-]?CAM", "Right"),
        ("CENTER[_-]?CAM", "Center"),
        ("FRONT[_-]?CAM", "Front"),
        ("BACK[_-]?CAM", "Back"),
        ("SIDE[_-]?CAM", "Side"),
    ]
    
    // MARK: - Video File Extensions
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "avi", "mkv", "mxf", "r3d", "braw", "prores", 
        "dnxhd", "dnxhr", "h264", "h265", "hevc", "avchd", "mts", 
        "m2ts", "3gp", "flv", "wmv", "webm", "ogv"
    ]
    
    // MARK: - Public Methods
    
    /// Analyzes video files in a folder and suggests camera naming based on filename patterns
    static func analyzeFolderForCameraNaming(at folderURL: URL) -> [CameraNamingResult] {
        guard folderURL.hasDirectoryPath else { return [] }
        
        var results: [CameraNamingResult] = []
        
        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
            
            // Filter to video files only
            let videoFiles = fileURLs.filter { url in
                let fileExtension = url.pathExtension.lowercased()
                return videoExtensions.contains(fileExtension)
            }
            
            // Analyze each video file
            for videoURL in videoFiles.prefix(50) { // Limit to first 50 files for performance
                if let result = detectCameraFromFilename(videoURL.lastPathComponent) {
                    results.append(result)
                }
            }
            
        } catch {
            SharedLogger.error("Error reading folder contents: \(error)", category: .transfer)
        }
        
        return results
    }
    
    /// Gets the best camera naming suggestion based on detected patterns
    static func getBestCameraSuggestion(for folderURL: URL) -> CameraNamingResult? {
        let results = analyzeFolderForCameraNaming(at: folderURL)
        
        // Group by designation and find the most common one
        let grouped = Dictionary(grouping: results) { $0.cameraDesignation }
        
        // Find the designation with highest confidence and most occurrences
        let bestDesignation = grouped.max { first, second in
            let firstScore = first.value.reduce(0) { $0 + $1.confidence } * Float(first.value.count)
            let secondScore = second.value.reduce(0) { $0 + $1.confidence } * Float(second.value.count)
            return firstScore < secondScore
        }
        
        guard let best = bestDesignation?.value.first else { return nil }
        
        // Create suggested name based on folder name and detected camera
        let folderName = folderURL.lastPathComponent
        let suggestedName = generateSuggestedName(baseName: folderName, cameraDesignation: best.cameraDesignation)
        
        return CameraNamingResult(
            suggestedName: suggestedName,
            cameraDesignation: best.cameraDesignation,
            confidence: best.confidence,
            sourceFilename: best.sourceFilename
        )
    }
    
    // MARK: - Private Methods
    
    /// Detects camera designation from a single filename
    private static func detectCameraFromFilename(_ filename: String) -> CameraNamingResult? {
        let uppercaseFilename = filename.uppercased()
        
        for (pattern, designation) in cameraPatterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                let range = NSRange(location: 0, length: filename.count)
                
                if let match = regex.firstMatch(in: uppercaseFilename, options: [], range: range) {
                    // Calculate confidence based on pattern specificity and position
                    let confidence = calculateConfidence(
                        pattern: pattern,
                        match: match,
                        filename: uppercaseFilename
                    )
                    
                    let suggestedName = generateSuggestedName(
                        baseName: extractBaseName(from: filename),
                        cameraDesignation: designation
                    )
                    
                    return CameraNamingResult(
                        suggestedName: suggestedName,
                        cameraDesignation: designation,
                        confidence: confidence,
                        sourceFilename: filename
                    )
                }
            } catch {
                continue
            }
        }
        
        return nil
    }
    
    /// Calculates confidence score for a pattern match
    private static func calculateConfidence(pattern: String, match: NSTextCheckingResult, filename: String) -> Float {
        var confidence: Float = 0.7 // Base confidence
        
        // Higher confidence for more specific patterns
        if pattern.contains("CAMERA") { confidence += 0.1 }
        if pattern.contains("[_-]") { confidence += 0.05 }
        
        // Position matters - earlier in filename is better
        let position = Float(match.range.location) / Float(filename.count)
        confidence += (1.0 - position) * 0.15
        
        return min(confidence, 1.0)
    }
    
    /// Extracts base name from filename (removes camera designation and extension)
    private static func extractBaseName(from filename: String) -> String {
        let nameWithoutExtension = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        
        // Remove common camera patterns to get clean base name
        var cleanName = nameWithoutExtension
        
        for (pattern, _) in cameraPatterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                cleanName = regex.stringByReplacingMatches(
                    in: cleanName,
                    options: [],
                    range: NSRange(location: 0, length: cleanName.count),
                    withTemplate: ""
                )
            } catch {
                continue
            }
        }
        
        // Clean up any trailing/leading separators
        cleanName = cleanName.trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))
        
        // If we removed too much, fall back to original
        if cleanName.isEmpty || cleanName.count < 3 {
            cleanName = nameWithoutExtension
        }
        
        return cleanName
    }
    
    /// Generates a suggested folder name
    private static func generateSuggestedName(baseName: String, cameraDesignation: String) -> String {
        // Try to find project name from base name
        let components = baseName.components(separatedBy: CharacterSet(charactersIn: "_-. "))
        let projectName = components.first(where: { $0.count > 2 && !$0.allSatisfy(\.isNumber) }) ?? baseName
        
        return "\(projectName) \(cameraDesignation)"
    }
}

