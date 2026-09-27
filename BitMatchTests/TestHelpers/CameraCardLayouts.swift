// CameraCardLayouts.swift
// BitMatchTests
//
// Folder trees that real cameras write to their cards, built as empty
// placeholder files for camera-detection tests. Each layout records where
// its shape comes from and what is only inferred. Audit:
// the 2026-09-25 camera-detection audit.
//
// Files are empty unless `contents` gives text. Detection that reads file
// headers (RAF, CR3) therefore sees no model and falls back to the brand.

import Foundation

struct CameraCardLayout {
    let name: String
    /// Public source(s) for the layout.
    let source: String
    /// What the source did not confirm. Empty when nothing was inferred.
    let inferred: String
    let directories: [String]
    let files: [String]
    var contents: [String: String] = [:]

    /// Builds the tree in a fresh temporary directory and returns its root.
    /// The caller removes it.
    func build() throws -> URL {
        let fm = FileManager.default
        // Lowercase prefix plus an uppercase-hex UUID: neither can spell a
        // detector pattern such as DCIM, MISC, ARRI, RED or BPAV.
        let root = fm.temporaryDirectory
            .appendingPathComponent("bitmatch_cardlayout_\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in directories {
            try fm.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        for file in files {
            let url = root.appendingPathComponent(file)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((contents[file] ?? "").utf8).write(to: url)
        }
        return root
    }
}

enum CameraCardLayouts {

    // MARK: Sony

    /// VENICE / VENICE 2, X-OCN on an AXS card (GitHub #8).
    static let sonyVeniceAXS = CameraCardLayout(
        name: "Sony VENICE X-OCN on AXS",
        source: "https://www.abelcine.com/articles/blog-and-knowledge/tutorials-and-guides/x-ocn-workflows-with-the-sony-venice ; https://pro.sony/s3/2023/09/21144038/Sony_X-OCN_White_Paper_v1.1.pdf",
        inferred: "Top folder is Cam ID + Reel (confirmed); whether each clip has its own subfolder and which XML sidecars exist is not confirmed, so this uses flat MXF clips only.",
        directories: [],
        files: [
            "A001/A001C001_250925AB.MXF",
            "A001/A001C002_250925AB.MXF",
        ]
    )

    /// VENICE / VENICE 2, XAVC on an SxS card.
    static let sonyVeniceSxS = CameraCardLayout(
        name: "Sony VENICE XAVC on SxS",
        source: "https://www.abelcine.com/articles/blog-and-knowledge/tech-news/venice-firmware-30 ; https://www.abelcine.com/articles/blog-and-knowledge/tutorials-and-guides/how-to-import-f5f55-footage-in-fcp-avid-and-premiere",
        inferred: "MEDIAPRO.XML attributes are illustrative; MPC-3610 is VENICE's model number. Firmware 3.0+ can rename XDROOT to Cam ID + Reel, which this layout does not cover.",
        directories: ["XDROOT/General", "XDROOT/Sub"],
        files: [
            "XDROOT/MEDIAPRO.XML",
            "XDROOT/Clip/A001C001_250925AB.MXF",
        ],
        contents: [
            "XDROOT/MEDIAPRO.XML": #"<MediaProfile><Properties><System systemKind="MPC-3610 ver.3.00"/></Properties></MediaProfile>"#,
        ]
    )

    /// FX6 / FX9 / FS7 / F55 XAVC on XQD, CFexpress or SxS.
    static let sonyXAVCPro = CameraCardLayout(
        name: "Sony FX6 XAVC",
        source: "https://www.abelcine.com/articles/blog-and-knowledge/tutorials-and-guides/how-to-import-f5f55-footage-in-fcp-avid-and-premiere ; https://community.adobe.com/t5/premiere-pro-discussions/xdroot-xdcam-import/td-p/9823511",
        inferred: "General/Sub subfolders and the clip name are from memory; MEDIAPRO.XML attributes are illustrative.",
        directories: ["XDROOT/General", "XDROOT/Sub"],
        files: [
            "XDROOT/MEDIAPRO.XML",
            "XDROOT/Clip/A001C001_250925AB.MXF",
        ],
        contents: [
            "XDROOT/MEDIAPRO.XML": #"<MediaProfile><Properties><System systemKind="ILME-FX6V ver.5.010"/></Properties></MediaProfile>"#,
        ]
    )

    /// XDCAM EX (EX1/EX3) on SxS.
    static let sonyXDCAMEX = CameraCardLayout(
        name: "Sony XDCAM EX",
        source: "https://community.avid.com/cfs-filesystemfile.ashx/__key/CommunityServer.Components.PostAttachments/00.00.60.25.02/XDCAM-HD_5F00_EX-folder-structure.pdf",
        inferred: "Clip file names are illustrative.",
        directories: ["BPAV/TAKR"],
        files: [
            "BPAV/MEDIAPRO.XML",
            "BPAV/CUEUP.XML",
            "BPAV/CLPR/429_0001_01/429_0001_01.MP4",
            "BPAV/CLPR/429_0001_01/429_0001_01M01.XML",
        ]
    )

    /// Alpha / FX3 / FX30: XAVC S video plus DCIM stills on one card.
    static let sonyAlpha = CameraCardLayout(
        name: "Sony Alpha / FX3",
        source: "https://www.sonyalphaforum.com/topic/9230-cant-find-sony-a7iii-video-files-on-your-computer/ ; https://www.dpreview.com/forums/thread/4521107",
        inferred: "MEDIAPRO.XML location in M4ROOT and its attributes are from memory.",
        directories: [],
        files: [
            "DCIM/100MSDCF/DSC00001.ARW",
            "PRIVATE/M4ROOT/MEDIAPRO.XML",
            "PRIVATE/M4ROOT/CLIP/C0001.MP4",
            "PRIVATE/M4ROOT/CLIP/C0001M01.XML",
        ],
        contents: [
            "PRIVATE/M4ROOT/MEDIAPRO.XML": #"<MediaProfile><Properties><System systemKind="ILCE-7SM3 ver.1.00"/></Properties></MediaProfile>"#,
        ]
    )

    // MARK: Canon

    /// EOS stills only.
    static let canonEOSStills = CameraCardLayout(
        name: "Canon EOS stills",
        source: "https://support.usa.canon.com/kb/s/article/ART153030",
        inferred: "File names are the well-known defaults, not quoted by the source.",
        directories: ["MISC"],
        files: ["DCIM/100CANON/IMG_0001.CR3"]
    )

    /// EOS card with an MP4 movie next to the stills (R5/R6 record MP4).
    static let canonEOSWithMP4 = CameraCardLayout(
        name: "Canon EOS stills + MP4",
        source: "https://support.usa.canon.com/kb/s/article/ART153030",
        inferred: "MVI_ name and .MP4 container are the well-known defaults, not quoted by the source.",
        directories: ["MISC"],
        files: [
            "DCIM/100CANON/IMG_0001.CR3",
            "DCIM/100CANON/MVI_0002.MP4",
        ]
    )

    /// Cinema EOS XF-AVC (C300 II/III, C500 II, C70 on CFexpress).
    static let canonXFAVC = CameraCardLayout(
        name: "Canon XF-AVC",
        source: "https://support.usa.canon.com/kb/s/article/ART165712 ; https://www.abelcine.com/articles/blog-and-knowledge/tutorials-and-guides/how-to-import-c300-mark-ii-footage-in-avid-fcp-x-premiere-and-resolve",
        inferred: "Clip file names inside the clip folder are illustrative.",
        directories: [],
        files: [
            "CONTENTS/CLIPS001/INDEX.MIF",
            "CONTENTS/CLIPS001/AA2123/AA212301.MXF",
            "CONTENTS/CLIPS001/AA2123/AA212301.CIF",
        ]
    )

    /// C70 MP4 / XF-HEVC S on SD, with slow/fast-motion audio in PRIVATE.
    static let canonC70SD = CameraCardLayout(
        name: "Canon C70 MP4 on SD",
        source: "https://www.manualslib.com/manual/2096455/Canon-Eos-C70.html?page=37",
        inferred: "DCIM subfolder name follows the documented XXX_mmdd pattern; file names are illustrative.",
        directories: [],
        files: [
            "DCIM/100_0925/A001C001_250925AA_CANON.MP4",
            "PRIVATE/AUDIO/A001C002_250925AA_CANON.WAV",
        ]
    )

    // MARK: ARRI

    /// ALEXA Mini LF: reel folder, one MXF per take, ARRI support folder.
    static let arriMiniLF = CameraCardLayout(
        name: "ARRI ALEXA Mini LF",
        source: "https://www.arri.com/en/learn-help/learn-help-camera-system/pre-postproduction/file-formats-data-handling ; https://help.codex.online/content/Workflows/ALEXA_Mini_Workflow",
        inferred: "Clip subfolder name and the .ale location are not confirmed; the ALE model string's letter case is not confirmed.",
        directories: ["ARRI/LOOKFILES", "ARRI/FRAMELINES"],
        files: [
            "A001R0Z3/A001C001_250925_R0Z3/A001C001_250925_R0Z3.mxf",
            "A001R0Z3/A001R0Z3.ale",
        ],
        contents: [
            "A001R0Z3/A001R0Z3.ale": "Heading\nFIELD_DELIM\tTABS\nFPS\t24\n\nColumn\nName\tCamera Model\n\nData\nA001C001_250925_R0Z3\tALEXA Mini LF\n",
        ]
    )

    // MARK: RED

    static let redR3D = CameraCardLayout(
        name: "RED R3D",
        source: "https://docs.red.com/955-0004_v50/REDCINE-XProOperationGuide/Content/4_LoadOrganize/R3D_Structure.htm ; https://docs.red.com/955-0196_v1.6/Content/5_How_To/Media/ClipName.htm",
        inferred: "Not checked against a KOMODO or V-RAPTOR card.",
        directories: [],
        files: [
            "A001_0925AB.RDM/A001_C001_0925AB.RDC/A001_C001_0925AB_001.R3D",
            "A001_0925AB.RDM/A001_C001_0925AB.RDC/A001_C001_0925AB_002.R3D",
            "A001_0925AB.RDM/A001_C002_0925AB.RDC/A001_C002_0925AB_001.R3D",
        ]
    )

    // MARK: Blackmagic

    static let blackmagicBRAW = CameraCardLayout(
        name: "Blackmagic BRAW",
        source: "https://forum.blackmagicdesign.com/viewtopic.php?f=2&t=105347",
        inferred: "Forum source (not the manual); one other source mentions a reel folder at the root.",
        directories: [],
        files: [
            "A001_09251512_C001.braw",
            "A001_09251520_C002.braw",
        ]
    )

    // MARK: Panasonic

    static let panasonicLumixStills = CameraCardLayout(
        name: "Panasonic Lumix stills",
        source: "https://help.na.panasonic.com/answers/how-to-set-the-folder-and-file-names-lumix/",
        inferred: "MISC and PRIVATE/PANA_GRP at the root come from a forum summary.",
        directories: ["MISC", "PRIVATE/PANA_GRP"],
        files: ["DCIM/100_PANA/P1000001.RW2"]
    )

    static let panasonicP2 = CameraCardLayout(
        name: "Panasonic P2",
        source: "https://eww.pass.panasonic.co.jp/pro-av/support/content/faq/EN/p2card_handling_en.htm ; https://ingex.sourceforge.net/P2_structure.html",
        inferred: "Clip file names are illustrative.",
        directories: ["CONTENTS/PROXY", "CONTENTS/VOICE"],
        files: [
            "LASTCLIP.TXT",
            "CONTENTS/CLIP/0001AB.XML",
            "CONTENTS/VIDEO/0001AB.MXF",
            "CONTENTS/AUDIO/0001AB00.MXF",
            "CONTENTS/ICON/0001AB.BMP",
        ]
    )

    // MARK: Fujifilm / Nikon

    static let fujifilmStills = CameraCardLayout(
        name: "Fujifilm stills",
        source: "https://pal2tech.com/guides/camera/fujifilm-camera-file-and-folder-naming-setup/",
        inferred: "",
        directories: [],
        files: ["DCIM/100_FUJI/DSCF0001.RAF"]
    )

    static let fujifilmWithMovie = CameraCardLayout(
        name: "Fujifilm stills + MOV",
        source: "https://pal2tech.com/guides/camera/fujifilm-camera-file-and-folder-naming-setup/",
        inferred: "Movie file name and .MOV container are from memory.",
        directories: [],
        files: [
            "DCIM/100_FUJI/DSCF0001.RAF",
            "DCIM/100_FUJI/DSCF0002.MOV",
        ]
    )

    static let nikonStills = CameraCardLayout(
        name: "Nikon stills",
        source: "https://onlinemanual.nikonimglib.com/z8/en/psm_file_naming_116.html",
        inferred: "Folder name 100NIKON is the DCF default; Z bodies may use e.g. 100NZ_9, which the detectors treat the same way.",
        directories: [],
        files: ["DCIM/100NIKON/DSC_0001.NEF"]
    )

    // MARK: Action / drone / 360

    static let goPro = CameraCardLayout(
        name: "GoPro HERO",
        source: "https://community.gopro.com/s/article/GoPro-Camera-File-Naming-Convention ; https://community.gopro.com/s/article/How-to-Find-the-Root-Level-of-Your-SD-Card",
        inferred: "",
        directories: ["MISC"],
        files: [
            "DCIM/100GOPRO/GX010001.MP4",
            "DCIM/100GOPRO/GX010001.THM",
            "DCIM/100GOPRO/GL010001.LRV",
        ]
    )

    /// Older DJI drones (Mavic 2, Mini 2).
    static let djiLegacy = CameraCardLayout(
        name: "DJI (100MEDIA)",
        source: "https://forum.dji.com/thread-277539-1-1.html ; https://mavicpilots.com/threads/mini2-file-names-of-the-jpg-and-mp4.106407/",
        inferred: "Forum sources.",
        directories: ["MISC/THM"],
        files: [
            "DCIM/100MEDIA/DJI_0001.MP4",
            "DCIM/100MEDIA/DJI_0002.JPG",
        ]
    )

    /// Newer DJI (Mavic 3, Mini 4 Pro, Avata 2).
    static let djiCurrent = CameraCardLayout(
        name: "DJI (DJI_001)",
        source: "https://forum.dji.com/forum.php?mod=viewthread&tid=311643",
        inferred: "Forum source; .SRT/.LRF companions are from memory.",
        directories: [],
        files: [
            "DCIM/DJI_001/DJI_20250925130032_0001_D.MP4",
            "DCIM/DJI_001/DJI_20250925130032_0001_D.SRT",
            "DCIM/DJI_001/DJI_20250925130032_0001_D.LRF",
        ]
    )

    static let insta360 = CameraCardLayout(
        name: "Insta360",
        source: "https://onlinemanual.insta360.com/x3/en-us/operating-tutorials/storage/fileformat",
        inferred: "",
        directories: [],
        files: [
            "DCIM/Camera01/VID_20250925_213000_00_001.insv",
            "DCIM/Camera01/LRV_20250925_213000_01_001.lrv",
            "DCIM/Camera01/IMG_20250925_213100_00_002.insp",
        ]
    )

    static let all: [CameraCardLayout] = [
        sonyVeniceAXS, sonyVeniceSxS, sonyXAVCPro, sonyXDCAMEX, sonyAlpha,
        canonEOSStills, canonEOSWithMP4, canonXFAVC, canonC70SD,
        arriMiniLF, redR3D, blackmagicBRAW,
        panasonicLumixStills, panasonicP2,
        fujifilmStills, fujifilmWithMovie, nikonStills,
        goPro, djiLegacy, djiCurrent, insta360,
    ]
}
