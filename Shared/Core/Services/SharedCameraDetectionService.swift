// SharedCameraDetectionService.swift - Platform-agnostic camera detection
import Foundation
import AVFoundation
import BitMatchEngine

final class SharedCameraDetectionService: CameraDetectionService, Sendable {
    
    func detectCamera(from folderURL: URL) async -> CameraDetectionResult {
        let startTime = Date()
        var metadata: [String: Any] = [:]
        var confidence: Double = 0.0
        var detectedCard: CameraCard? = nil
        var detectionMethod = "unknown"
        
        do {
            // Guard against scanning huge destination volumes (≥ 1 TB)
            if let rv = try? folderURL.resourceValues(forKeys: [.volumeTotalCapacityKey]),
               let cap = rv.volumeTotalCapacity, cap >= 1_000_000_000_000 {
                SharedLogger.debug("Skip SharedCameraDetectionService on large volume: \(ByteCountFormatter.string(fromByteCount: Int64(cap), countStyle: .file)) at \(folderURL.path)", category: .transfer)
                return CameraDetectionResult(cameraCard: nil, confidence: 0.0, metadata: ["skip": "large_volume"], detectionMethod: "guard", processingTime: Date().timeIntervalSince(startTime))
            }
            // The card layout decides the brand, through the same classifier
            // the Mac auto-detect and the orchestrator use (Promise 5).
            let layout = CardLayoutClassifier.classify(at: folderURL)
            let layoutType = layout?.brand != nil ? layout?.cameraType : nil
            // Set when the orchestrator names a known brand. The folder-name
            // and file-extension guesses below may then raise confidence but
            // must not replace that brand (a VENICE card is not a
            // "Professional Camera").
            var brandLocked = false
            // Fast path: use orchestrator’s folder/name heuristics on every platform.
            if let orchestrated = CameraDetectionOrchestrator.shared.detectCamera(at: folderURL, layout: layout) {
                metadata["orchestrator_hint"] = orchestrated
                // Parse manufacturer/model from the returned string
                let parts = orchestrated.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                let manufacturerFromHint = parts.first.map(String.init)
                let modelFromHint = parts.count > 1 ? String(parts[1]) : nil
                // If we recognize a specific make (e.g., Sony/Canon/FUJI/ARRI/RED/etc.), bump confidence
                if let make = manufacturerFromHint, ["Sony","Canon","FUJIFILM","Fujifilm","ARRI","RED","Blackmagic","Panasonic","DJI","GoPro","Nikon","Insta360"].contains(where: { make.localizedCaseInsensitiveContains($0) }) {
                    confidence = max(confidence, 0.9)
                    detectionMethod = "orchestrator_hint"
                    brandLocked = true
                    // Pre-seed a card so UI can label immediately
                    let fileURLs = try await getFileList(from: folderURL)
                    // The model when known (FX3 over SONY), else the brand
                    let cleanName = Self.cameraCardName(manufacturer: make, model: modelFromHint)
                    detectedCard = CameraCard(
                        name: cleanName,
                        manufacturer: make,
                        model: modelFromHint,
                        fileCount: fileURLs.count,
                        totalSize: calculateTotalSize(fileURLs),
                        detectionConfidence: confidence,
                        metadata: metadata,
                        volumeURL: folderURL,
                        cameraType: layoutType ?? .generic,
                        mediaPath: folderURL
                    )
                }
            }

            // Step 1: Analyze folder structure
            let folderStructure = try await analyzeFolderStructure(at: folderURL)
            metadata.merge(folderStructure) { _, new in new }
            
            // Step 2: Check for camera-specific folder patterns
            let folderName = folderURL.lastPathComponent.uppercased()
            let (manufacturer, model, folderConfidence) = detectFromFolderName(folderName)
            
            if folderConfidence > confidence {
                confidence = folderConfidence
                detectionMethod = "folder_structure"
            }
            
            // Step 3: Analyze file extensions and naming patterns
            let fileURLs = try await getFileList(from: folderURL)
            let (fileManufacturer, fileModel, fileConfidence) = await detectFromFilePatterns(fileURLs)
            
            if fileConfidence > confidence {
                confidence = fileConfidence
                detectionMethod = "file_patterns"
            }
            
            // Step 4: Extract metadata from video files
            if confidence < 0.8 {
                let videoURLs = fileURLs.filter { isVideoFile($0) }
                if let videoURL = videoURLs.first {
                    do {
                        let videoMetadata = try await extractVideoMetadata(from: videoURL)
                        metadata.merge(videoMetadata) { _, new in new }
                        
                        let (mf, mdl, videoConfidence) = extractCameraFromVideoMetadata(videoMetadata)
                        if videoConfidence > confidence {
                            confidence = videoConfidence
                            detectionMethod = "video_metadata"
                        }
                        // If model identified, prefer it for display
                        if let m = mf { metadata["make_inferred"] = m }
                        if let model = mdl { metadata["model_inferred"] = model }
                    } catch {
                        // Video metadata extraction failed, continue with other methods
                    }
                }
            }
            
            // Step 5: Look for XML sidecar files
            if confidence < 0.8 {
                let xmlURLs = fileURLs.filter { $0.pathExtension.lowercased() == "xml" }
                for xmlURL in xmlURLs.prefix(3) { // Only check first 3 XML files
                    guard !Task.isCancelled else { break }
                    do {
                        let xmlMetadata = try await parseXMLMetadata(from: xmlURL)
                        let (_, _, xmlConfidence) = extractCameraFromXMLMetadata(xmlMetadata)
                        if xmlConfidence > confidence {
                            confidence = xmlConfidence
                            detectionMethod = "xml_metadata"
                            metadata.merge(xmlMetadata) { _, new in new }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // XML parsing failed, continue
                    }
                }
            }
            
            // Create or update camera card if we have sufficient confidence
            if confidence > 0.5 {
                let finalManufacturer: String
                let finalModel: String?
                if brandLocked, let card = detectedCard {
                    finalManufacturer = card.manufacturer
                    finalModel = card.model
                } else {
                    finalManufacturer = manufacturer ?? fileManufacturer ?? detectedCard?.manufacturer ?? "Unknown"
                    finalModel = model ?? fileModel ?? detectedCard?.model
                }
                let cameraType = layoutType ?? Self.inferCameraType(
                    manufacturer: finalManufacturer,
                    model: finalModel,
                    extensions: Array(Set(fileURLs.map { $0.pathExtension.lowercased() }))
                )
                
                if detectedCard == nil {
                    let cleanName = Self.cleanCameraName("\(finalManufacturer) \(finalModel ?? "")")
                    detectedCard = CameraCard(
                        name: cleanName,
                        manufacturer: finalManufacturer,
                        model: finalModel,
                        fileCount: fileURLs.count,
                        totalSize: calculateTotalSize(fileURLs),
                        detectionConfidence: confidence,
                        metadata: metadata,
                        volumeURL: folderURL,
                        cameraType: cameraType,
                        mediaPath: folderURL
                    )
                } else {
                    let cleanName = Self.cameraCardName(manufacturer: finalManufacturer, model: finalModel)
                    detectedCard = CameraCard(
                        name: cleanName,
                        manufacturer: finalManufacturer,
                        model: finalModel,
                        fileCount: detectedCard?.fileCount ?? fileURLs.count,
                        totalSize: detectedCard?.totalSize ?? calculateTotalSize(fileURLs),
                        detectionConfidence: confidence,
                        metadata: metadata.merging(detectedCard?.metadata ?? [:]) { a, _ in a },
                        volumeURL: folderURL,
                        cameraType: cameraType,
                        mediaPath: folderURL
                    )
                }
            }
            
        } catch {
            metadata["error"] = error.localizedDescription
            confidence = 0.0
        }
        
        let processingTime = Date().timeIntervalSince(startTime)
        
        return CameraDetectionResult(
            cameraCard: detectedCard,
            confidence: confidence,
            metadata: metadata,
            detectionMethod: detectionMethod,
            processingTime: processingTime
        )
    }

    /// A detected card's name: the model when there is
    /// one, else the brand. iPad and iPhone use it as the default destination
    /// folder label, so it must not change between versions: a card that
    /// went into "GOPRO" yesterday goes there today, not into "GP".
    /// The default destination folder label for a detected card. A known
    /// model uses the Mac's label cleaner on "brand model", so the folder is
    /// the same on every platform ("A7SIII"). A brand alone keeps the
    /// long-standing folder names ("GOPRO", not the Mac cleaner's "GP").
    static func cameraCardName(manufacturer: String, model: String?) -> String {
        if let model, !model.isEmpty {
            return CleanCameraNameService.shared.getCleanCameraName(from: "\(manufacturer) \(model)")
        }
        return cleanCameraName(manufacturer)
    }

    /// The folder-name cleaner iPad and iPhone have always used: uppercase,
    /// no spaces, at most 8 characters ("GoPro" → "GOPRO", "A7S III" → "A7S3").
    /// It is deliberately not `CleanCameraNameService` (the Mac's label
    /// cleaner), which would rename existing folders ("GoPro" → "GP").
    static func cleanCameraName(_ full: String) -> String {
        var result = full
        result = result.replacingOccurrences(of: "-", with: " ")
        result = result.replacingOccurrences(of: "_", with: " ")
        result = result.replacingOccurrences(of: "  ", with: " ")
        result = result.replacingOccurrences(of: "Mark ", with: "MK", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "III", with: "3")
        result = result.replacingOccurrences(of: "II", with: "2")
        return result.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: " ", with: "").prefix(8).description
    }
    
    func analyzeFolderStructure(at url: URL) async throws -> [String: Any] {
        var structure: [String: Any] = [:]
        
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        var fileCount = 0
        var folderCount = 0
        var extensions: Set<String> = []
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            
            if isDirectory {
                folderCount += 1
            } else {
                fileCount += 1
                extensions.insert(fileURL.pathExtension.lowercased())
            }
        }
        
        structure["total_files"] = fileCount
        structure["total_folders"] = folderCount
        structure["file_extensions"] = Array(extensions).sorted()
        structure["folder_name"] = url.lastPathComponent
        
        return structure
    }
    
    func extractVideoMetadata(from fileURL: URL) async throws -> [String: Any] {
        let asset = AVURLAsset(url: fileURL)
        var metadata: [String: Any] = [:]
        
        // Get common metadata
        for item in try await asset.load(.metadata) {
            if let key = item.commonKey?.rawValue, let value = try? await item.load(.value) {
                metadata[key] = value
            }
        }
        
        // Get format-specific metadata
        for format in try await asset.load(.availableMetadataFormats) {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                if let key = item.key as? String, let value = try? await item.load(.value) {
                    metadata["format_\(format.rawValue)_\(key)"] = value
                }
            }
        }
        
        return metadata
    }
    
    func parseXMLMetadata(from fileURL: URL) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard let data = AdvisoryMetadataFileReader.read(fileURL) else {
            try Task.checkCancellation()
            return [:]
        }
        try Task.checkCancellation()
        var metadata: [String: Any] = [:]
        
        // Simple XML parsing for common camera metadata patterns
        if let xmlString = String(data: data, encoding: .utf8) {
            metadata["xml_content_length"] = xmlString.count
            
            // Look for common camera metadata patterns
            let patterns = [
                "camera": #"<camera[^>]*>([^<]+)</camera>"#,
                "manufacturer": #"<manufacturer[^>]*>([^<]+)</manufacturer>"#,
                "model": #"<model[^>]*>([^<]+)</model>"#,
                "device": #"<device[^>]*>([^<]+)</device>"#,
            ]
            
            for (key, pattern) in patterns {
                try Task.checkCancellation()
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(xmlString.startIndex..., in: xmlString)
                    if let match = regex.firstMatch(in: xmlString, range: range),
                       let valueRange = Range(match.range(at: 1), in: xmlString) {
                        metadata[key] = String(xmlString[valueRange])
                    }
                }
            }
        }

        try Task.checkCancellation()
        return metadata
    }
    
    // MARK: - Private Helper Methods
    
    private func getFileList(from folderURL: URL) async throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey])
        var fileURLs: [URL] = []
        
        while let url = enumerator?.nextObject() as? URL {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues.isRegularFile == true {
                fileURLs.append(url)
            }
        }
        
        return fileURLs
    }
    
    private func detectFromFolderName(_ folderName: String) -> (manufacturer: String?, model: String?, confidence: Double) {
        // First, check for common model codes in folder or volume names
        let modelPatterns: [(String, String, Double)] = [
            ("SONY", "FX3", 0.95), ("SONY", "FX6", 0.95), ("SONY", "FX9", 0.95),
            ("SONY", "A7SIII", 0.9), ("SONY", "A7S3", 0.9),
            ("SONY", "BURANO", 0.95),
            ("CANON", "C70", 0.95), ("CANON", "C300", 0.9),
            ("ARRI", "ALEXA", 0.95), ("ARRI", "AMIRA", 0.95),
            ("RED", "KOMODO", 0.95), ("RED", "RAPTOR", 0.95)
        ]
        for (make, model, conf) in modelPatterns {
            if folderName.contains(model) {
                return (make, model, conf)
            }
        }

        // Fallback to manufacturer-only detection
        let makePatterns: [(String, Double)] = [
            ("ARRI", 0.9), ("CANON", 0.8), ("SONY", 0.8), ("PANASONIC", 0.8),
            ("FUJI", 0.8), ("BLACKMAGIC", 0.8), ("RED", 0.9)
        ]
        for (make, conf) in makePatterns {
            if folderName.contains(make) {
                return (make, nil, conf)
            }
        }

        return (nil, nil, 0.0)
    }
    
    private func detectFromFilePatterns(_ fileURLs: [URL]) async -> (manufacturer: String?, model: String?, confidence: Double) {
        let fileExtensions = Set(fileURLs.map { $0.pathExtension.lowercased() })
        
        // Camera-specific file extension patterns
        if fileExtensions.contains("ari") { return ("ARRI", "ALEXA", 0.95) }
        if fileExtensions.contains("r3d") { return ("RED", nil, 0.95) }
        if fileExtensions.contains("braw") { return ("Blackmagic Design", nil, 0.95) }
        if fileExtensions.intersection(["mxf", "mov"]).count > 0 {
            return ("Professional Camera", nil, 0.6)
        }
        
        return (nil, nil, 0.0)
    }
    
    private func extractCameraFromVideoMetadata(_ metadata: [String: Any]) -> (manufacturer: String?, model: String?, confidence: Double) {
        // Look for camera information in video metadata
        for (_, value) in metadata {
            let valueString = "\(value)".lowercased()
            
            // Manufacturer detection
            var make: String? = nil
            if valueString.contains("arri") { make = "ARRI" }
            else if valueString.contains("canon") { make = "Canon" }
            else if valueString.contains("sony") { make = "Sony" }
            else if valueString.contains("panasonic") { make = "Panasonic" }

            // Model detection for common Sony/Canon/ARRI/RED patterns
            var model: String? = nil
            let modelCandidates = ["fx3","fx6","fx9","a7siii","a7s3","burano","c70","c300","alexa","amira","komodo","raptor"]
            for cand in modelCandidates {
                if valueString.contains(cand) {
                    model = cand.uppercased()
                    break
                }
            }

            if make != nil || model != nil {
                let conf = model != nil ? 0.96 : 0.9
                return (make, model, conf)
            }
        }
        
        return (nil, nil, 0.0)
    }
    
    private func extractCameraFromXMLMetadata(_ metadata: [String: Any]) -> (manufacturer: String?, model: String?, confidence: Double) {
        if let manufacturer = metadata["manufacturer"] as? String {
            let model = metadata["model"] as? String
            return (manufacturer, model, 0.85)
        }
        
        if let camera = metadata["camera"] as? String {
            return (camera, nil, 0.8)
        }
        
        return (nil, nil, 0.0)
    }
    
    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = ["mov", "mp4", "avi", "mxf", "r3d", "ari", "braw", "dnxhd", "prores"]
        return videoExtensions.contains(url.pathExtension.lowercased())
    }
    
    private func calculateTotalSize(_ fileURLs: [URL]) -> Int64 {
        return fileURLs.compactMap { url in
            try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
        }.reduce(0, +)
    }
}

// MARK: - Helpers
extension SharedCameraDetectionService {
    static func inferCameraType(manufacturer: String, model: String?, extensions: [String]) -> CameraType {
        let m = manufacturer.lowercased()
        let mod = (model ?? "").lowercased()
        let exts = Set(extensions.map { $0.lowercased() })
        if m.contains("arri") || (mod.contains("alexa")) || exts.contains("ari") { return .arri }
        if m.contains("red") || exts.contains("r3d") { return .red }
        if m.contains("sony") || exts.contains("mxf") { return .sony }
        if m.contains("canon") { return .canon }
        if m.contains("blackmagic") || exts.contains("braw") { return .blackmagic }
        if m.contains("panasonic") { return .panasonic }
        return .generic
    }
}
