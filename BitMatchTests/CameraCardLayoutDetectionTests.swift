// CameraCardLayoutDetectionTests.swift
import Foundation
import Testing
@testable import BitMatch

/// Camera detection against the card layouts in `CameraCardLayouts`.
///
/// Two kinds of test:
/// - Guards pin detection that is right today. Each names the one-line
///   production change that should make it fail.
/// - `withKnownIssue` tests record detection that is wrong today (see
///   docs/audits/2026-09-25-camera-detection.md). They are strict: when a
///   fix lands, the known issue stops reproducing, the test fails, and the
///   wrapper should be removed so the test becomes a guard.
///
/// Placeholder files are empty. The orchestrator asks Spotlight (mdls)
/// about MP4/MOV/JPG files, and that answer depends on the machine. It now
/// asks only after the card layout has named the brand, and uses the
/// answer only when it names the same brand, so a label on those fixtures
/// still starts with the layout's brand.
struct CameraCardLayoutDetectionTests {

    private func withCard<T>(
        _ layout: CameraCardLayout,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let root = try layout.build()
        defer { try? FileManager.default.removeItem(at: root) }
        return try await body(root)
    }

    private func samePath(_ a: URL?, _ b: URL) -> Bool {
        a?.standardizedFileURL.path == b.standardizedFileURL.path
    }

    // MARK: - Fixture sanity

    @Test func everyLayoutBuildsItsDeclaredTree() async throws {
        for layout in CameraCardLayouts.all {
            #expect(!layout.source.isEmpty, "\(layout.name) has no source")
            try await withCard(layout) { root in
                for path in layout.directories + layout.files {
                    #expect(
                        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                        "\(layout.name): missing \(path)"
                    )
                }
            }
        }
    }

    // MARK: - Mac auto-detect (CameraStructureDetector): guards

    /// Plant: in CardLayoutClassifier.classify, delete the
    /// `PRIVATE/M4ROOT ... nnnMSDCF ... ARW` Sony rule (the card then lands
    /// on the generic DCIM rule).
    @Test func structureDetectorFindsSonyAlpha() async throws {
        let card = try await withCard(CameraCardLayouts.sonyAlpha) {
            await CameraStructureDetector.detectCameraType(at: $0)
        }
        #expect(card?.cameraType == .sony)
    }

    /// Plant: in CardLayoutClassifier.classify, delete the `nnnCANON` Canon
    /// rule (the card then lands on the generic DCIM rule).
    @Test func structureDetectorFindsCanonStills() async throws {
        let card = try await withCard(CameraCardLayouts.canonEOSStills) {
            await CameraStructureDetector.detectCameraType(at: $0)
        }
        #expect(card?.cameraType == .canon)
    }

    /// Plant: in CardLayoutClassifier.classify, delete the `nnn_PANA`
    /// Panasonic rule.
    @Test func structureDetectorFindsLumixStills() async throws {
        let card = try await withCard(CameraCardLayouts.panasonicLumixStills) {
            await CameraStructureDetector.detectCameraType(at: $0)
        }
        #expect(card?.cameraType == .panasonic)
    }

    /// Plant: in CardLayoutClassifier.classify, delete the `nnn_FUJI`
    /// Fujifilm rule.
    @Test func structureDetectorFindsFujifilmStills() async throws {
        let card = try await withCard(CameraCardLayouts.fujifilmStills) {
            await CameraStructureDetector.detectCameraType(at: $0)
        }
        #expect(card?.cameraType == .fujifilm)
    }

    /// Plant: in CardLayoutClassifier.classify, delete the `INSV` Insta360
    /// rule.
    @Test func structureDetectorFindsInsta360() async throws {
        let card = try await withCard(CameraCardLayouts.insta360) {
            await CameraStructureDetector.detectCameraType(at: $0)
        }
        #expect(card?.cameraType == .insta360)
    }

    // MARK: - Mac auto-detect (CameraStructureDetector): more guards

    /// Auto-select (Mac, opt-in) uses `mediaPath` as the transfer source.
    /// It must be the card root, or part of the card is silently left out
    /// (Promise 1). The Sony detector used to return PRIVATE/, dropping
    /// DCIM stills. Fails if `performDetection` passes `detection.mediaPath`
    /// instead of the volume.
    @Test func sonyAlphaMediaPathIsCardRoot() async throws {
        let layout = CameraCardLayouts.sonyAlpha
        let root = try layout.build()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = await CameraStructureDetector.detectCameraType(at: root)
        #expect(card != nil)
        #expect(samePath(card?.mediaPath, root))
    }

    /// Canon C70 on SD: the MP4 in DCIM used to match the Sony catch-all.
    /// Plant: in CardLayoutClassifier.classify, delete
    /// `|| l.hasDCIMFile(where: { $0.stem.hasSuffix("_CANON") })` from the
    /// Canon rule (the card then lands on the generic DCIM rule).
    @Test func canonC70SDIsCanonWithRootMediaPath() async throws {
        let layout = CameraCardLayouts.canonC70SD
        let root = try layout.build()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = await CameraStructureDetector.detectCameraType(at: root)
        #expect(samePath(card?.mediaPath, root))
        #expect(card?.cameraType == .canon)
    }

    /// Layouts the Mac detector used to miss (nil) or give to another
    /// brand; the old answer is noted per row. Brand-unique markers now
    /// come before any DCIM catch-all (audit findings B and E).
    /// Plants, each on its own, in CardLayoutClassifier.classify:
    /// - delete the Sony X-OCN clip-name rule (VENICE AXS → nil);
    /// - delete the GoPro rule (GoPro → generic DCIM);
    /// - insert `if l.hasDirectory("DCIM") && l.hasDirectory("MISC") { return match(.canon, "") }`
    ///   above the GoPro rule (GoPro and DJI → Canon: the old catch-all).
    @Test func structureDetectorNamesEveryBrand() async throws {
        let expectations: [(CameraCardLayout, CameraType)] = [
            (CameraCardLayouts.sonyVeniceAXS, .sony),       // was nil
            (CameraCardLayouts.sonyVeniceSxS, .sony),       // was nil: XDROOT not checked
            (CameraCardLayouts.sonyXAVCPro, .sony),         // was nil: XDROOT not checked
            (CameraCardLayouts.sonyXDCAMEX, .sony),         // was nil: BPAV not checked
            (CameraCardLayouts.canonEOSWithMP4, .canon),    // was .sony: MP4 in DCIM
            (CameraCardLayouts.canonXFAVC, .canon),         // was nil: no DCIM
            (CameraCardLayouts.arriMiniLF, .arri),          // was nil: ARRI/ holds no media
            (CameraCardLayouts.redR3D, .redCamera),         // was nil: root is *.RDM, not RED/
            (CameraCardLayouts.blackmagicBRAW, .blackmagic),// was nil: clips at root, not BRAW/
            (CameraCardLayouts.panasonicP2, .panasonic),    // was nil: no P2/ folder
            (CameraCardLayouts.fujifilmWithMovie, .fujifilm), // was .canon: MOV in Canon list
            (CameraCardLayouts.nikonStills, .nikon),        // was .canon: 100NIKON matched \d{3}[A-Z]+
            (CameraCardLayouts.goPro, .gopro),              // was .sony: MP4 in DCIM
            (CameraCardLayouts.djiLegacy, .dji),            // was .sony: MP4 in DCIM
            (CameraCardLayouts.djiCurrent, .dji),           // was .sony: MP4 in DCIM
        ]
        for (layout, expected) in expectations {
            let root = try layout.build()
            defer { try? FileManager.default.removeItem(at: root) }
            let card = await CameraStructureDetector.detectCameraType(at: root)
            #expect(card?.cameraType == expected, "\(layout.name) detected as \(card?.cameraType.rawValue ?? "nothing")")
            #expect(samePath(card?.mediaPath, root), "\(layout.name): mediaPath is not the card root")
        }
    }

    /// Plant: in `VolumeAnalysis.rootAnchoredCameraName`, replace the
    /// classifier with the recursive orchestrator. These loose clips then
    /// satisfy its extension-count heuristic and get a camera name.
    @Test func looseAndDeepMediaAreNotRootAnchoredCardLayouts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-loose-media-\(UUID())", isDirectory: true)
        let deep = root.appendingPathComponent("Projects/Yesterday/Camera Backup/Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<12 {
            try Data([0]).write(to: deep.appendingPathComponent("clip-\(index).mov"))
        }
        #expect(CardLayoutClassifier.classify(at: root) == nil)
        #expect(VolumeAnalysis.rootAnchoredCameraName(at: root) == nil)
    }

    /// Promise 5: the Mac auto-detect and the label pipeline name the same
    /// brand for every layout, because both ask CardLayoutClassifier.
    /// Plant: in CameraStructureDetector.performDetection change
    /// `cameraType: detection.cameraType,` to `cameraType: .generic,`.
    @Test func autoDetectAndLabelAgreeOnBrand() async throws {
        for layout in CameraCardLayouts.all {
            let root = try layout.build()
            defer { try? FileManager.default.removeItem(at: root) }
            let card = await CameraStructureDetector.detectCameraType(at: root)
            let label = CameraDetectionOrchestrator.shared.detectCamera(at: root)
            let brand = card.flatMap { CardLayoutClassifier.brandName(for: $0.cameraType) }
            #expect(brand != nil, "\(layout.name): auto-detect named no brand")
            if let brand {
                #expect(label?.hasPrefix(brand) == true, "\(layout.name): auto-detect says \(brand), label says \(label ?? "nil")")
            }
        }
    }

    // MARK: - Orchestrator (labels, all platforms): guards

    /// Plant: in CardLayoutClassifier.brandName change `return "Sony"` to
    /// `return "Canon"`.
    @Test func orchestratorLabelsVeniceSxSAsSony() async throws {
        let result = try await withCard(CameraCardLayouts.sonyVeniceSxS) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result?.hasPrefix("Sony") == true)
    }

    /// Plant: in SonyDetectionService.mapSonySystemKind delete
    /// `("ILME-FX6", "FX6"),`.
    @Test func orchestratorReadsFX6ModelFromMediaPro() async throws {
        let result = try await withCard(CameraCardLayouts.sonyXAVCPro) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result == "Sony FX6")
    }

    /// Plant: in CardLayoutClassifier.classify, delete the XF-AVC
    /// `CLIPSnnn` rule (the card then falls to "Professional").
    @Test func orchestratorLabelsXFAVCAsCanon() async throws {
        let result = try await withCard(CameraCardLayouts.canonXFAVC) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result == "Canon")
    }

    /// Plant: in CardLayoutClassifier.classify, delete the P2
    /// `CONTENTS/VIDEO` rule (the card then falls to "Professional").
    @Test func orchestratorLabelsP2AsPanasonic() async throws {
        let result = try await withCard(CameraCardLayouts.panasonicP2) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result == "Panasonic")
    }

    /// Plant: in CardLayoutClassifier.brandName change `return "RED"` to
    /// `return "Professional"`.
    @Test func orchestratorLabelsR3DAsRED() async throws {
        let result = try await withCard(CameraCardLayouts.redR3D) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result == "RED")
    }

    /// Plant: in CardLayoutClassifier.brandName change
    /// `return "Blackmagic"` to `return "Professional"`.
    @Test func orchestratorLabelsBRAWAsBlackmagic() async throws {
        let result = try await withCard(CameraCardLayouts.blackmagicBRAW) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result == "Blackmagic")
    }

    /// GitHub #8 camera. X-OCN clips are MXF in a Cam ID + Reel folder;
    /// the extension stage used to call it "Professional".
    /// Plant: in CardLayoutClassifier.classify, delete the Sony X-OCN
    /// clip-name rule (the one calling `isSonyProClipName`).
    @Test func orchestratorLabelsVeniceAXSAsSony() async throws {
        let result = try await withCard(CameraCardLayouts.sonyVeniceAXS) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result?.hasPrefix("Sony") == true, "VENICE AXS card labelled \(result ?? "nil")")
    }

    /// MPC-3610 (VENICE) in MEDIAPRO.XML names the model.
    /// Plant: in SonyDetectionService.mapSonySystemKind delete
    /// `("MPC-3610", "VENICE"),`.
    @Test func orchestratorNamesVenice() async throws {
        let result = try await withCard(CameraCardLayouts.sonyVeniceSxS) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result == "Sony VENICE")
    }

    /// Lumix stills: the Canon stage used to run first and match any card
    /// with DCIM plus MISC.
    /// Plant: in CardLayoutClassifier.classify insert
    /// `if l.hasDirectory("DCIM") && l.hasDirectory("MISC") { return match(.canon, "") }`
    /// above the GoPro rule (the old catch-all).
    @Test func orchestratorLabelsLumixAsPanasonic() async throws {
        let result = try await withCard(CameraCardLayouts.panasonicLumixStills) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result == "Panasonic")
    }

    /// Full orchestrator on a GoPro card. The layout decides the brand
    /// before Spotlight runs, and Spotlight's answer is used only when it
    /// names the same brand, so neither "(null) (null)" nor "Canon" wins.
    /// Plant: the DCIM + MISC Canon line from the test above.
    @Test func orchestratorLabelsGoPro() async throws {
        let result = try await withCard(CameraCardLayouts.goPro) {
            CameraDetectionOrchestrator.shared.detectCamera(at: $0)
        }
        #expect(result == "GoPro")
    }

    // MARK: - Stage tests: guards

    /// Stage test: BPAV is a Sony-only card root.
    /// Plant: in CardLayoutClassifier.classify, delete the
    /// `XDROOT ... BPAV ... MEDIAPRO.XML` Sony rule.
    @Test func folderStructureLabelsXDCAMEXAsSony() async throws {
        let result = try await withCard(CameraCardLayouts.sonyXDCAMEX) {
            FolderStructureDetectionService.shared.detectCameraFromStructure(at: $0)
        }
        #expect(result == "Sony")
    }

    /// Stage test: ARRI support folder at the card root.
    /// Plant: in CardLayoutClassifier.classify, delete the ARRI rule.
    @Test func folderStructureLabelsMiniLFAsARRI() async throws {
        let result = try await withCard(CameraCardLayouts.arriMiniLF) {
            FolderStructureDetectionService.shared.detectCameraFromStructure(at: $0)
        }
        #expect(result == "ARRI")
    }

    /// DCIM + MISC used to hit the Canon pattern before the GoPro/DJI ones.
    /// Plant: the DCIM + MISC Canon line from orchestratorLabelsLumixAsPanasonic.
    @Test func folderStructureLabelsGoProAndDJI() async throws {
        let gopro = try await withCard(CameraCardLayouts.goPro) {
            FolderStructureDetectionService.shared.detectCameraFromStructure(at: $0)
        }
        #expect(gopro == "GoPro")
        let dji = try await withCard(CameraCardLayouts.djiLegacy) {
            FolderStructureDetectionService.shared.detectCameraFromStructure(at: $0)
        }
        #expect(dji == "DJI")
    }

    /// Stage test. Plant: in FujiDetectionService.swift:24 change
    /// `== "RAF"` to `== "RAW"`.
    @Test func fujiStageFindsRAF() async throws {
        let result = try await withCard(CameraCardLayouts.fujifilmStills) {
            FujiDetectionService.shared.detectFujiCamera(at: $0)
        }
        #expect(result == "Fujifilm")
    }

    /// "ILCE-7SM3" also contains "ILCE-7S". The table used to be a
    /// Dictionary, whose order changes per process; it is now ordered with
    /// longer keys first.
    /// Plant: in SonyDetectionService.mapSonySystemKind change
    /// `("ILCE-7SM3", "A7S III"),` to `("ILCE-7SM9", "A7S III"),`
    /// (ILCE-7S then answers "A7S").
    @Test func sonyStageReadsA7SIII() async throws {
        let result = try await withCard(CameraCardLayouts.sonyAlpha) {
            SonyDetectionService.shared.detectSonyCamera(at: $0)
        }
        #expect(result == "Sony A7S III")
    }

    // MARK: - Stage tests: ALE model names

    /// A mixed-case model string in an ALE ("ALEXA Mini LF") names the
    /// Mini LF, not the LF (audit finding G).
    /// Plant: in `ARRIDetectionService.extractCameraFromALE`, test
    /// `trimmedLine` instead of `upperLine`.
    @Test func arriStageReadsMiniLFFromALE() async throws {
        let result = try await withCard(CameraCardLayouts.arriMiniLF) {
            ARRIDetectionService.shared.detectARRICamera(at: $0)
        }
        #expect(result == "ARRI Alexa Mini LF")
    }
}
