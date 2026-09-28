// Core/Services/CameraMemoryService.swift
import Foundation
import ImageIO
import AVFoundation
import BitMatchEngine

// MARK: - Camera Memory Service
/// `@unchecked Sendable`: its only mutable state, `memory`, is read and
/// written under `memoryLock` (the load in `init` runs before sharing).
final class CameraMemoryService: @unchecked Sendable {
    static let shared = CameraMemoryService()
    private let userDefaults = UserDefaults.standard
    private let memoryKey = "CameraMemory"
    
    // MARK: - Camera Fingerprint Model
    struct CameraFingerprint: Codable, Equatable {
        let manufacturer: String
        let model: String
        let serialNumber: String
        var assignedLabel: String
        var lastSeen: Date
        
        var displayName: String {
            "\(model) #\(serialNumber.suffix(5))"
        }
        
        var uniqueID: String {
            "\(manufacturer)-\(model)-\(serialNumber)"
        }
    }
    
    // MARK: - Memory Storage
    /// Guards `memory`: fingerprinting runs off the main actor (label-view
    /// background detection) while label reads/writes happen on it.
    /// Mutations still auto-save via didSet, which runs inside the lock on
    /// the mutating thread; `saveMemory` only re-reads `memory` on that
    /// same thread, so no re-entry occurs.
    private let memoryLock = NSLock()
    private var memory: [String: CameraFingerprint] = [:] {
        didSet {
            saveMemory()
        }
    }
    
    private init() {
        loadMemory()
    }
    
    // MARK: - Sony System ID Detection
    private func getSonySystemFingerprint(at url: URL) -> CameraFingerprint? {
        let mediaProPath = url.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML")
        guard FileManager.default.fileExists(atPath: mediaProPath.path) else { return nil }
        
        guard let xmlData = try? Data(contentsOf: mediaProPath),
              let xmlString = String(data: xmlData, encoding: .utf8) else { return nil }
        
        // Extract systemId and systemKind
        var systemId: String?
        var systemKind: String?
        
        if let systemIdRange = xmlString.range(of: "systemId=\"[^\"]*\"", options: .regularExpression) {
            let match = String(xmlString[systemIdRange])
            systemId = match.replacingOccurrences(of: "systemId=\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        
        if let systemKindRange = xmlString.range(of: "systemKind=\"[^\"]*\"", options: .regularExpression) {
            let match = String(xmlString[systemKindRange])
            systemKind = match.replacingOccurrences(of: "systemKind=\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        
        guard let id = systemId, let kind = systemKind else { return nil }
        
        // Create or retrieve existing fingerprint
        let uniqueID = "Sony-\(kind)-\(id)"
        
        if let existing = cachedFingerprint(for: uniqueID) {
            // Update last seen
            touchFingerprint(for: uniqueID)
            return existing
        } else {
            // Create new fingerprint
            let fingerprint = CameraFingerprint(
                manufacturer: "Sony",
                model: mapSonySystemKind(kind),
                serialNumber: id,
                assignedLabel: "",
                lastSeen: Date()
            )
            storeFingerprint(fingerprint, for: uniqueID)

            SharedLogger.info("New Sony camera fingerprinted: \(fingerprint.displayName)", category: .transfer)
            return fingerprint
        }
    }
    
    private func mapSonySystemKind(_ systemKind: String) -> String {
        switch systemKind {
        case "ILCE-7SM3": return "A7S III"
        case "ILCE-7SM2": return "A7S II" 
        case "ILCE-7SM": return "A7S"
        case "ILCE-7RM5": return "A7R V"
        case "ILCE-7RM4": return "A7R IV"
        case "ILCE-7RM3": return "A7R III"
        case "ILCE-7M4": return "A7 IV"
        case "ILCE-7M3": return "A7 III"
        case "FX6": return "FX6"
        case "FX3": return "FX3"
        case "FX30": return "FX30"
        default: return systemKind
        }
    }
    
    // MARK: - Public Methods
    
    /// Get or create a fingerprint for a camera at the given URL
    func getCameraFingerprint(at url: URL) -> CameraFingerprint? {
        // Try Sony systemId first (most reliable for Sony cameras)
        if let sonyFingerprint = getSonySystemFingerprint(at: url) {
            return sonyFingerprint
        }
        
        // Try multiple detection methods
        if let fingerprint = detectFromMediaFiles(at: url) {
            return fingerprint
        }
        
        if let fingerprint = detectFromSidecarFiles(at: url) {
            return fingerprint
        }
        
        if let fingerprint = detectFromFolderStructure(at: url) {
            return fingerprint
        }
        
        return nil
    }
    
    /// Remember a label for a specific camera
    func rememberLabel(_ label: String, for fingerprint: CameraFingerprint) {
        var updated = fingerprint
        updated.assignedLabel = label
        updated.lastSeen = Date()
        storeFingerprint(updated, for: fingerprint.uniqueID)

        SharedLogger.info("Remembered: \(fingerprint.displayName) = \"\(label)\"", category: .transfer)
    }

    /// Get the remembered label for a camera
    func getRememberedLabel(for fingerprint: CameraFingerprint) -> String? {
        cachedFingerprint(for: fingerprint.uniqueID)?.assignedLabel
    }

    /// Update label if user changes it
    func updateLabel(_ newLabel: String, for fingerprint: CameraFingerprint) {
        let oldLabel: String? = memoryLock.withLock { () -> String? in
            guard var existing = memory[fingerprint.uniqueID] else { return nil }
            let old = existing.assignedLabel
            existing.assignedLabel = newLabel
            existing.lastSeen = Date()
            memory[fingerprint.uniqueID] = existing
            return old
        }
        if let oldLabel {
            SharedLogger.info("Updated: \(fingerprint.displayName) = \"\(newLabel)\" (was: \(oldLabel))", category: .transfer)
        } else {
            rememberLabel(newLabel, for: fingerprint)
        }
    }

    // MARK: - Synchronized Access

    private func cachedFingerprint(for id: String) -> CameraFingerprint? {
        memoryLock.withLock { memory[id] }
    }

    private func storeFingerprint(_ fingerprint: CameraFingerprint, for id: String) {
        memoryLock.withLock { memory[id] = fingerprint }
    }

    private func touchFingerprint(for id: String) {
        memoryLock.withLock { memory[id]?.lastSeen = Date() }
    }
    
    // MARK: - Detection Methods
    
    private func detectFromMediaFiles(at url: URL) -> CameraFingerprint? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url,
                                                         includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        
        // Look for image/video files
        let mediaExtensions = ["JPG", "JPEG", "MOV", "MP4", "MXF", "ARI", "R3D", "BRAW"]
        
        for file in contents.prefix(5) { // Check first 5 files
            let ext = file.pathExtension.uppercased()
            guard mediaExtensions.contains(ext) else { continue }
            
            // Try to extract metadata
            if let metadata = extractMetadata(from: file) {
                if let fingerprint = parseFingerprint(from: metadata) {
                    return fingerprint
                }
            }
        }
        
        return nil
    }
    
    private func detectFromSidecarFiles(at url: URL) -> CameraFingerprint? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url,
                                                         includingPropertiesForKeys: [.isRegularFileKey]) else {
            return nil
        }
        
        // Check for XML/metadata files
        for file in contents {
            let name = file.lastPathComponent.uppercased()
            
            // Sony XML files
            if name.contains("M01.XML") || name.contains("MEDIAPRO.XML") {
                if let xmlContent = try? String(contentsOf: file, encoding: .utf8) {
                    return parseSonyXML(xmlContent)
                }
            }
            
            // Canon XMP files
            if file.pathExtension.uppercased() == "XMP" {
                if let xmpContent = try? String(contentsOf: file, encoding: .utf8) {
                    return parseCanonXMP(xmpContent)
                }
            }
            
            // ARRI metadata
            if name.contains(".ARI") || name.contains("METADATA") {
                if let arriContent = try? String(contentsOf: file, encoding: .utf8) {
                    return parseARRIMetadata(arriContent)
                }
            }
        }
        
        return nil
    }
    
    private func detectFromFolderStructure(at url: URL) -> CameraFingerprint? {
        // Look for camera-specific folder patterns that might contain serial numbers
        let folderName = url.lastPathComponent
        
        // Sony pattern: might have camera ID in folder
        if folderName.contains("C0") || folderName.contains("M4ROOT") {
            // Try to extract from MEDIAPRO.XML or similar
            return detectSonyFromStructure(at: url)
        }
        
        // RED pattern: might have camera info in RDC folder
        if folderName.uppercased().contains("RDC") {
            return detectREDFromStructure(at: url)
        }
        
        return nil
    }
    
    // MARK: - Metadata Extraction
    
    private func extractMetadata(from fileURL: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        
        return metadata
    }
    
    private func parseFingerprint(from metadata: [String: Any]) -> CameraFingerprint? {
        // Try EXIF data first
        if let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            let make = (exif["Make"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (exif["Model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Try to find serial number in various fields
            var serial: String?
            
            // Common serial number fields
            if let bodySerial = exif["BodySerialNumber"] as? String {
                serial = bodySerial
            } else if let cameraSerial = exif["SerialNumber"] as? String {
                serial = cameraSerial
            } else if let lensSerial = exif["LensSerialNumber"] as? String {
                // Sometimes camera serial is stored here
                serial = lensSerial
            }
            
            // Check maker notes for serial
            if serial == nil, let makerNote = exif["MakerNote"] as? Data {
                serial = extractSerialFromMakerNote(makerNote, manufacturer: make)
            }
            
            if let serial = serial, !make.isEmpty, !model.isEmpty {
                return CameraFingerprint(
                    manufacturer: make,
                    model: model.replacingOccurrences(of: make, with: "").trimmingCharacters(in: .whitespaces),
                    serialNumber: serial,
                    assignedLabel: "",
                    lastSeen: Date()
                )
            }
        }
        
        // Try TIFF data
        if let tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            let make = (tiff["Make"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (tiff["Model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let software = tiff["Software"] as? String
            
            // Some cameras put serial in software field
            if let serial = extractSerialFromSoftware(software) {
                return CameraFingerprint(
                    manufacturer: make,
                    model: model,
                    serialNumber: serial,
                    assignedLabel: "",
                    lastSeen: Date()
                )
            }
        }
        
        return nil
    }
    
    // MARK: - Camera-Specific Parsers
    
    private func parseSonyXML(_ xml: String) -> CameraFingerprint? {
        // Look for Sony-specific metadata
        if let serialRange = xml.range(of: "<SerialNumber>([^<]+)</SerialNumber>", options: .regularExpression) {
            let serial = String(xml[serialRange]).replacingOccurrences(of: "<SerialNumber>", with: "")
                                                 .replacingOccurrences(of: "</SerialNumber>", with: "")
            
            let model = xml.contains("FX6") ? "FX6" :
                       xml.contains("FX3") ? "FX3" :
                       xml.contains("FX9") ? "FX9" : "Camera"
            
            return CameraFingerprint(
                manufacturer: "Sony",
                model: model,
                serialNumber: serial,
                assignedLabel: "",
                lastSeen: Date()
            )
        }
        return nil
    }
    
    private func parseCanonXMP(_ xmp: String) -> CameraFingerprint? {
        // Parse Canon XMP for serial
        if let serialRange = xmp.range(of: "exif:BodySerialNumber=\"([^\"]+)\"", options: .regularExpression) {
            let serial = String(xmp[serialRange]).components(separatedBy: "\"")[1]
            
            let model = xmp.contains("C70") ? "C70" :
                       xmp.contains("C300") ? "C300" :
                       xmp.contains("C500") ? "C500" : "Camera"
            
            return CameraFingerprint(
                manufacturer: "Canon",
                model: model,
                serialNumber: serial,
                assignedLabel: "",
                lastSeen: Date()
            )
        }
        return nil
    }
    
    private func parseARRIMetadata(_ content: String) -> CameraFingerprint? {
        // ARRI cameras have very consistent metadata
        var serial: String?
        var model = "ALEXA" // Default
        
        if content.contains("ALEXA Mini") {
            model = "ALEXA Mini"
        } else if content.contains("ALEXA LF") {
            model = "ALEXA LF"
        } else if content.contains("AMIRA") {
            model = "AMIRA"
        }
        
        // Look for serial patterns
        if let serialRange = content.range(of: "CameraSerialNumber: ([A-Z0-9]+)", options: .regularExpression) {
            serial = String(content[serialRange]).components(separatedBy: ": ").last
        }
        
        if let serial = serial {
            return CameraFingerprint(
                manufacturer: "ARRI",
                model: model,
                serialNumber: serial,
                assignedLabel: "",
                lastSeen: Date()
            )
        }
        
        return nil
    }
    
    private func detectSonyFromStructure(at url: URL) -> CameraFingerprint? {
        // Check for MEDIAPRO.XML in Sony folder structure
        let mediaproURL = url.appendingPathComponent("MEDIAPRO.XML")
        if let content = try? String(contentsOf: mediaproURL, encoding: .utf8) {
            return parseSonyXML(content)
        }
        return nil
    }
    
    private func detectREDFromStructure(at url: URL) -> CameraFingerprint? {
        // RED stores metadata in RDC folders
        // This would need actual RED SDK integration for full support
        // For now, generate a pseudo-serial from folder structure
        let folderName = url.lastPathComponent
        if folderName.contains("_") {
            let components = folderName.components(separatedBy: "_")
            if let cameraID = components.first {
                return CameraFingerprint(
                    manufacturer: "RED",
                    model: "Dragon", // Would need to detect actual model
                    serialNumber: cameraID,
                    assignedLabel: "",
                    lastSeen: Date()
                )
            }
        }
        return nil
    }
    
    // MARK: - Helper Methods
    
    private func extractSerialFromMakerNote(_ data: Data, manufacturer: String) -> String? {
        // This would need manufacturer-specific parsing
        // For now, return nil
        return nil
    }
    
    private func extractSerialFromSoftware(_ software: String?) -> String? {
        guard let software = software else { return nil }
        
        // Some cameras put serial in software string
        if let match = software.range(of: "\\b[A-Z0-9]{8,}\\b", options: .regularExpression) {
            return String(software[match])
        }
        
        return nil
    }
    
    // MARK: - Persistence
    
    private func loadMemory() {
        guard let data = userDefaults.data(forKey: memoryKey),
              let decoded = try? JSONDecoder().decode([String: CameraFingerprint].self, from: data) else {
            return
        }
        memory = decoded
        SharedLogger.info("Loaded \(memory.count) remembered cameras", category: .transfer)
    }
    
    private func saveMemory() {
        guard let encoded = try? JSONEncoder().encode(memory) else { return }
        userDefaults.set(encoded, forKey: memoryKey)
    }
}
