// Core/Services/Camera/CardLayoutClassifier.swift
import Foundation
import BitMatchEngine

/// A bounded, uppercased listing of a card's folder tree. Paths are
/// relative to the card root and "/"-separated, e.g. "DCIM/100CANON".
struct CardListing {
    struct File {
        /// Relative path, uppercased.
        let path: String
        /// Last path component, uppercased.
        let name: String
        /// Extension without the dot, uppercased ("" when none).
        let ext: String
        /// 1 for a file at the root.
        let depth: Int
        /// Name without the extension, uppercased.
        var stem: String { ext.isEmpty ? name : String(name.dropLast(ext.count + 1)) }
    }

    private(set) var directories: Set<String> = []
    private(set) var files: [File] = []

    /// Deepest level listed. Every layout the classifier knows puts its
    /// markers within four levels of the root (Canon XF-AVC:
    /// CONTENTS/CLIPS001/<clip>/<file>).
    static let maxDepth = 4
    /// Entry cap, so a large backup drive costs a bounded amount of I/O.
    static let maxEntries = 20_000

    /// Breadth-first listing of `root`, skipping hidden entries. Stops at
    /// `maxDepth`, `maxEntries`, or task cancellation.
    static func scan(_ root: URL) -> CardListing {
        var listing = CardListing()
        let fm = FileManager.default
        var queue: [(url: URL, path: String, depth: Int)] = [(root, "", 1)]
        var next = 0
        var seen = 0
        while next < queue.count {
            if Task.isCancelled { return listing }
            let current = queue[next]
            next += 1
            guard let children = try? fm.contentsOfDirectory(
                at: current.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                if seen >= maxEntries {
                    SharedLogger.debug("CardListing: entry cap (\(maxEntries)) reached at \(root.path)", category: .transfer)
                    return listing
                }
                seen += 1
                let name = child.lastPathComponent.uppercased()
                let path = current.path.isEmpty ? name : current.path + "/" + name
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    listing.directories.insert(path)
                    if current.depth < maxDepth {
                        queue.append((child, path, current.depth + 1))
                    }
                } else {
                    let ext = child.pathExtension.uppercased()
                    listing.files.append(File(path: path, name: name, ext: ext, depth: current.depth))
                }
            }
        }
        return listing
    }

    // MARK: Queries (all arguments uppercase)

    func hasDirectory(_ path: String) -> Bool {
        directories.contains(path)
    }

    /// Names of the immediate subdirectories of `parent` ("" for the root).
    func subdirectories(of parent: String) -> [String] {
        let prefix = parent.isEmpty ? "" : parent + "/"
        return directories.compactMap { path in
            guard path.hasPrefix(prefix) else { return nil }
            let rest = path.dropFirst(prefix.count)
            return rest.contains("/") || rest.isEmpty ? nil : String(rest)
        }
    }

    /// True when an immediate subdirectory of `parent` matches the anchored
    /// regular expression `pattern`.
    func hasSubdirectory(of parent: String, matching pattern: String) -> Bool {
        subdirectories(of: parent).contains { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    func hasFile(where predicate: (File) -> Bool) -> Bool {
        files.contains(where: predicate)
    }

    /// Files anywhere under DCIM/.
    func hasDCIMFile(where predicate: (File) -> Bool) -> Bool {
        files.contains { $0.path.hasPrefix("DCIM/") && predicate($0) }
    }
}

/// What a card's layout says about the camera that wrote it.
struct CardLayoutMatch: Equatable {
    let cameraType: CameraType
    let confidence: DetectionConfidence
    /// The marker that decided it, for logs.
    let evidence: String

    /// Brand label ("Sony", "RED", ...) when the layout names a brand; nil
    /// for the generic DCIM and media-folder shapes.
    var brand: String? { CardLayoutClassifier.brandName(for: cameraType) }
}

enum DetectionConfidence {
    case high      // Multiple indicators match
    case medium    // Some indicators match
    case low       // Weak indicators
}

/// The one place that decides a card's brand from its folder layout.
///
/// Used by all three detection paths (the 2026-09-25 camera-detection audit,
/// finding B and Promise 5):
/// - `CameraStructureDetector` (Mac auto-detect),
/// - `CameraDetectionOrchestrator` (labels; its first step), and through it
/// - `SharedCameraDetectionService` (the verdict on every platform).
///
/// Rules run in order and the first match wins. Brand-unique markers come
/// first; a DCIM folder with ordinary media is only a last resort, so no
/// brand acts as a catch-all. Layouts and sources live in
/// BitMatchTests/TestHelpers/CameraCardLayouts.swift; *inferred* marks a
/// marker that is not confirmed by a manual or a real card.
enum CardLayoutClassifier {

    static func classify(at root: URL) -> CardLayoutMatch? {
        let listing = CardListing.scan(root)
        guard !Task.isCancelled else { return nil }
        return classify(listing)
    }

    static func classify(_ l: CardListing) -> CardLayoutMatch? {
        // Markers are anchored where a camera writes them (the root, the
        // first levels below it, or DCIM/), so a backup drive holding a
        // copied card inside a project folder is not taken for a card.

        // Pro cinema cards (no DCIM).
        if l.hasDirectory("XDROOT") || l.hasDirectory("PRIVATE/XDROOT") || l.hasDirectory("BPAV") || l.hasFile(where: { $0.name == "MEDIAPRO.XML" && $0.depth == 2 }) { return match(.sony, "XDROOT, BPAV or a root-level MEDIAPRO.XML") }
        if l.hasDirectory("ARRI") || l.hasFile(where: { $0.depth <= 3 && ($0.ext == "ARI" || isARRIClipName($0.name)) }) { return match(.arri, "ARRI folder, .ari, or ARRI clip name") }
        if l.subdirectories(of: "").contains(where: { $0.hasSuffix(".RDM") }) || l.hasFile(where: { $0.ext == "R3D" && $0.depth <= 3 }) { return match(.redCamera, ".RDM folder or .R3D") }
        if l.hasDirectory("BRAW") || l.hasDirectory("BLACKMAGIC RAW") || l.hasFile(where: { $0.ext == "BRAW" && $0.depth <= 2 }) { return match(.blackmagic, ".braw") }
        if l.hasSubdirectory(of: "CONTENTS", matching: #"^CLIPS\d{3}$"#) { return match(.canon, "XF-AVC CONTENTS/CLIPSnnn") }
        if l.hasDirectory("CONTENTS/VIDEO") || l.hasDirectory("CONTENTS/CLIP") { return match(.panasonic, "P2 CONTENTS/VIDEO or CONTENTS/CLIP") }
        if l.hasFile(where: { $0.depth <= 3 && $0.ext == "MXF" && isSonyProClipName($0.name) }) { return match(.sony, "Sony X-OCN/XAVC clip name (VENICE)") }

        // DCIM cards: brand-unique folder names, file names and RAW formats.
        if l.hasSubdirectory(of: "DCIM", matching: #"^\d{3}GOPRO$"#) { return match(.gopro, "DCIM/nnnGOPRO") }
        if l.hasSubdirectory(of: "DCIM", matching: "^DJI") || l.hasDCIMFile(where: { $0.name.hasPrefix("DJI_") }) { return match(.dji, "DCIM/DJI_nnn or DJI_ file") }
        if l.hasDCIMFile(where: { ["INSV", "INSP"].contains($0.ext) }) { return match(.insta360, ".insv/.insp") }
        if l.hasDirectory("PRIVATE/M4ROOT") || l.hasSubdirectory(of: "DCIM", matching: #"^\d{3}MSDCF$"#) || l.hasDCIMFile(where: { $0.ext == "ARW" }) { return match(.sony, "PRIVATE/M4ROOT, DCIM/nnnMSDCF or .ARW") }
        if l.hasSubdirectory(of: "DCIM", matching: #"^\d{3}_PANA$"#) || l.hasDirectory("PRIVATE/PANA_GRP") || l.hasDCIMFile(where: { $0.ext == "RW2" }) { return match(.panasonic, "DCIM/nnn_PANA, PRIVATE/PANA_GRP or .RW2") }
        if l.hasSubdirectory(of: "DCIM", matching: #"^\d{3}_FUJI$"#) || l.hasDCIMFile(where: { $0.ext == "RAF" }) { return match(.fujifilm, "DCIM/nnn_FUJI or .RAF") }
        // nnnEOS (e.g. 100EOSR5) and the *_CANON clip suffix (Cinema EOS
        // MP4 on SD) are *inferred*.
        if l.hasSubdirectory(of: "DCIM", matching: #"^(\d{3}CANON|\d{3}EOS|CANONMSC)"#) || l.hasDirectory("PRIVATE/CANON") || l.hasDCIMFile(where: { ["CR2", "CR3", "CRW", "CRM"].contains($0.ext) }) || l.hasDCIMFile(where: { $0.stem.hasSuffix("_CANON") }) { return match(.canon, "DCIM/nnnCANON, Canon RAW, or *_CANON clip") }
        if l.hasSubdirectory(of: "DCIM", matching: #"^\d{3}(NIKON|NZ_)"#) || l.hasDCIMFile(where: { ["NEF", "NRW"].contains($0.ext) }) { return match(.nikon, "DCIM/nnnNIKON, nnnNZ_ or .NEF") }

        // Last resort: shapes that say "camera card" without naming a brand.
        if l.hasDCIMFile(where: { genericMediaExtensions.contains($0.ext) }) { return CardLayoutMatch(cameraType: .genericDCIM, confidence: .medium, evidence: "DCIM with media") }
        let mediaFolders: Set<String> = ["MEDIA", "VIDEO", "PHOTO", "PICTURES", "MOVIES"]
        if l.hasFile(where: { file in
            guard let top = file.path.split(separator: "/").first, file.path.contains("/") else { return false }
            return mediaFolders.contains(String(top)) && genericMediaExtensions.contains(file.ext)
        }) { return CardLayoutMatch(cameraType: .genericMedia, confidence: .low, evidence: "media folder") }
        return nil
    }

    /// Brand label used by the orchestrator and folder-structure stage.
    /// nil for generic shapes.
    static func brandName(for type: CameraType) -> String? {
        switch type {
        case .sony, .sonyFX6, .sonyFX3, .sonyA7S: return "Sony"
        case .canon, .canonC70: return "Canon"
        case .arri, .arriAlexa, .arriAmira: return "ARRI"
        case .red, .redCamera, .redDragon: return "RED"
        case .blackmagic, .blackmagicPocket: return "Blackmagic"
        case .panasonic: return "Panasonic"
        case .fujifilm: return "Fujifilm"
        case .nikon: return "Nikon"
        case .gopro: return "GoPro"
        case .dji: return "DJI"
        case .insta360: return "Insta360"
        case .genericDCIM, .genericMedia, .generic: return nil
        }
    }

    // MARK: - Private

    private static func match(_ type: CameraType, _ evidence: String) -> CardLayoutMatch {
        CardLayoutMatch(cameraType: type, confidence: .high, evidence: evidence)
    }

    private static let genericMediaExtensions: Set<String> = [
        "JPG", "JPEG", "PNG", "TIFF", "TIF", "GIF", "BMP", "HEIC", "HEIF",
        "MP4", "MOV", "AVI", "MKV", "M4V", "MTS", "MXF",
        "CR2", "CR3", "NEF", "ARF", "ARW", "DNG", "RAF", "RW2",
    ]

    /// Sony VENICE / XAVC clip name: Cam ID + Reel, C + clip, date, and a
    /// two-character suffix, e.g. A001C001_250925AB.MXF. The pattern is
    /// *inferred* from published examples, not from Sony's spec.
    private static func isSonyProClipName(_ name: String) -> Bool {
        name.range(of: #"^[A-Z]\d{3}C\d{3}_\d{6}[A-Z0-9]{2}\."#, options: .regularExpression) != nil
    }

    /// ARRI clip name: A001C001_250925_R0Z3.mxf (*inferred* from ARRI's
    /// file-format page; the reel suffix length is not confirmed).
    private static func isARRIClipName(_ name: String) -> Bool {
        name.range(of: #"^[A-Z]\d{3}C\d{3}_\d{6}_R[A-Z0-9]{3,4}\.(MXF|MOV|ARI)$"#, options: .regularExpression) != nil
    }
}
