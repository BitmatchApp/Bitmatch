// CameraModels.swift - Camera detection and labeling models
import Foundation

// MARK: - Camera Type
enum CameraType: String, CaseIterable, Identifiable, Codable, Sendable {
    case sony = "Sony"
    case sonyFX6 = "Sony FX6"
    case sonyFX3 = "Sony FX3"
    case sonyA7S = "Sony A7S"
    case canon = "Canon"
    case canonC70 = "Canon C70"
    case arri = "ARRI"
    case arriAlexa = "ARRI Alexa"
    case arriAmira = "ARRI Amira"
    case red = "RED"
    case redCamera = "RED Camera"
    case redDragon = "RED Dragon"
    case blackmagic = "Blackmagic Design"
    case blackmagicPocket = "Blackmagic Pocket"
    case panasonic = "Panasonic"
    case fujifilm = "Fujifilm"
    case nikon = "Nikon"
    case gopro = "GoPro"
    case dji = "DJI"
    case insta360 = "Insta360"
    case genericDCIM = "Generic DCIM"
    case genericMedia = "Generic Media"
    case generic = "Generic"
    
    var id: String { self.rawValue }
    
    var description: String {
        switch self {
        case .sony: return "Sony cameras (A7, FX series)"
        case .sonyFX6: return "Sony FX6 professional camera"
        case .sonyFX3: return "Sony FX3 compact cinema camera"
        case .sonyA7S: return "Sony A7S series camera"
        case .canon: return "Canon cameras (C series, EOS)"
        case .canonC70: return "Canon C70 cinema camera"
        case .arri: return "ARRI professional cameras"
        case .arriAlexa: return "ARRI Alexa series cameras"
        case .arriAmira: return "ARRI Amira series cameras"
        case .red: return "RED digital cinema cameras"
        case .redCamera: return "RED digital cinema cameras"
        case .redDragon: return "RED Dragon series cameras"
        case .blackmagic: return "Blackmagic Design cameras"
        case .blackmagicPocket: return "Blackmagic Pocket Cinema Camera"
        case .panasonic: return "Panasonic cameras (GH, EVA series)"
        case .fujifilm: return "Fujifilm cameras (X, GFX series)"
        case .nikon: return "Nikon cameras (D, Z series)"
        case .gopro: return "GoPro action cameras"
        case .dji: return "DJI drones and cameras"
        case .insta360: return "Insta360 VR cameras"
        case .genericDCIM: return "Generic DCIM camera structure"
        case .genericMedia: return "Generic media device"
        case .generic: return "Generic or unknown camera type"
        }
    }
}

// MARK: - Camera Card Detection
struct CameraCard: Identifiable {
    let id = UUID()
    let name: String
    let manufacturer: String
    let model: String?
    let fileCount: Int
    let totalSize: Int64
    let detectionConfidence: Double
    let metadata: [String: Any]
    let volumeURL: URL
    let cameraType: CameraType
    let mediaPath: URL
    
    var displayName: String {
        if let model = model {
            return "\(manufacturer) \(model)"
        }
        return manufacturer
    }
}

// MARK: - Camera Detection Result
struct CameraDetectionResult {
    let cameraCard: CameraCard?
    let confidence: Double
    let metadata: [String: Any]
    let detectionMethod: String
    let processingTime: TimeInterval
    
    var isValid: Bool { confidence > 0.7 }
}
