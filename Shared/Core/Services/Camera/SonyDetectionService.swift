// Core/Services/Camera/SonyDetectionService.swift
import Foundation
import BitMatchEngine

/// Reads the Sony model from MEDIAPRO.XML. The brand itself comes from CardLayoutClassifier.
final class SonyDetectionService: Sendable {
    static let shared = SonyDetectionService()
    private init() {}
    
    // MARK: - Public Interface
    
    func detectSonyCamera(at url: URL) -> String? {
        // Folder shape is CardLayoutClassifier's job; this stage only
        // reads MEDIAPRO.XML for the model.
        return checkSonyMediaProXML(at: url)
    }
    
    // MARK: - MEDIAPRO.XML Detection
    
    private func checkSonyMediaProXML(at url: URL) -> String? {
        // Consumer (M4ROOT), pro XAVC (XDROOT, or PRIVATE/XDROOT on SD),
        // and XDCAM EX (BPAV). VENICE firmware 3.0+ can rename XDROOT to
        // Cam ID + Reel, so any root folder's MEDIAPRO.XML also counts.
        let fm = FileManager.default
        guard !Task.isCancelled else { return nil }
        let rootNames = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        guard !Task.isCancelled else { return nil }
        let rootFolders = rootNames
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { "\($0)/MEDIAPRO.XML" }
        guard !Task.isCancelled else { return nil }
        let candidatePaths = [
            "PRIVATE/M4ROOT/MEDIAPRO.XML",
            "XDROOT/MEDIAPRO.XML",
            "PRIVATE/XDROOT/MEDIAPRO.XML",
            "BPAV/MEDIAPRO.XML"
        ] + rootFolders

        var foundReadableSidecar = false
        for candidate in candidatePaths {
            guard !Task.isCancelled else { return nil }
            let mediaProPath = url.appendingPathComponent(candidate)
            let model: String? = autoreleasepool {
                guard let xmlData = AdvisoryMetadataFileReader.read(mediaProPath),
                      let xmlString = String(data: xmlData, encoding: .utf8),
                      !Task.isCancelled else { return nil }
                foundReadableSidecar = true

                if let systemIdRange = xmlString.range(of: #"systemId="([^"]+)""#, options: .regularExpression) {
                    let systemId = String(xmlString[systemIdRange])
                        .replacingOccurrences(of: #"systemId=""#, with: "")
                        .replacingOccurrences(of: "\"", with: "")

                    if let cameraModel = mapSonySystemId(systemId) {
                        return "Sony \(cameraModel)"
                    }
                }

                guard !Task.isCancelled else { return nil }
                if let systemKindRange = xmlString.range(of: #"systemKind="([^"]+)""#, options: .regularExpression) {
                    // Extract attribute value
                    var systemKind = String(xmlString[systemKindRange])
                    systemKind = systemKind.replacingOccurrences(of: #"systemKind=""#, with: "")
                                           .replacingOccurrences(of: "\"", with: "")
                                           .trimmingCharacters(in: .whitespacesAndNewlines)

                    if let cameraModel = mapSonySystemKind(systemKind) {
                        SharedLogger.info("Resolved model: \(cameraModel) from systemKind=\(systemKind) at \(mediaProPath.path)", category: .transfer)
                        return "Sony \(cameraModel)"
                    }
                }
                return nil
            }
            guard !Task.isCancelled else { return nil }
            if let model { return model }
        }

        return Task.isCancelled ? nil : (foundReadableSidecar ? "Sony" : nil)
    }
    
    // MARK: - System ID/Kind Mapping
    
    private func mapSonySystemId(_ systemId: String) -> String? {
        let idMapping: [String: String] = [
            "0x0123": "A7S III",
            "0x0124": "A7S II",
            "0x0125": "A7S",
            "0x0126": "FX6",
            "0x0127": "FX3",
            "0x0128": "A7R V",
            "0x0129": "A7R IV",
            "0x012A": "A7 IV",
            "0x012B": "A7C II",
            "0x012C": "A7C",
            "0x012D": "FX30",
            "0x012E": "A6700",
            "0x012F": "A6600",
            "0x0130": "A6400"
        ]
        
        return idMapping[systemId]
    }
    
    private func mapSonySystemKind(_ systemKind: String) -> String? {
        // Ordered, and every key comes before any key it is a prefix of
        // (ILCE-7SM3 before ILCE-7S), so the first match is the right one.
        // A Dictionary here gave a different answer per process (audit F).
        let kindMapping: [(key: String, model: String)] = [
            ("ILCE-7SM3", "A7S III"),
            ("ILCE-7SM2", "A7S II"),
            ("ILCE-7S", "A7S"),
            ("ILCE-7RM5", "A7R V"),
            ("ILCE-7RM4", "A7R IV"),
            ("ILCE-7M4", "A7 IV"),
            ("ILCE-7CM2", "A7C II"),
            ("ILCE-7C", "A7C"),
            // Cinema line
            ("ILME-FX6", "FX6"),
            ("ILME-FX30", "FX30"),
            ("ILME-FX3", "FX3"),
            ("ILME-FX9", "FX9"),
            // VENICE model numbers (MPC-3610 VENICE, MPC-3628 VENICE 2)
            ("MPC-3628", "VENICE 2"),
            ("MPC-3610", "VENICE"),
            // XDCAM PXW series common on pro media
            ("PXW-FS7M2", "FS7 II"),
            ("PXW-FS7", "FS7"),
            ("PXW-FS5", "FS5"),
            ("ILCE-6700", "A6700"),
            ("ILCE-6600", "A6600"),
            ("ILCE-6400", "A6400")
        ]
        // Partial match (e.g., "ILME-FX6V ver.5.010" contains "ILME-FX6")
        for entry in kindMapping where systemKind.localizedCaseInsensitiveContains(entry.key) {
            return entry.model
        }
        return nil
    }
}
