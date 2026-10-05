import Foundation
import Testing
@testable import BitMatchEngine

// Reported names/layout from issue #8; contents are synthetic, not Sony metadata or footage.
struct SonyVeniceIssue8Tests {
    private static func diskImage(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
        catch { return -1 }
    }

    static let paths = """
A001CNXB/.DS_Store
A001CNXB/MEDIAPRO.XML
A001CNXB/General
A001CNXB/General/Sony
A001CNXB/General/Sony/Planning
A001CNXB/Clip
A001CNXB/Clip/A001C002_26091476R01.BIM
A001CNXB/Clip/A001C013_2609140GR01.BIM
A001CNXB/Clip/A001C015_2609147F.MOV
A001CNXB/Clip/A001C008_2609148KM01.XML
A001CNXB/Clip/A001C004_260914AK.MOV
A001CNXB/Clip/A001C010_260914IHR01.BIM
A001CNXB/Clip/A001C007_26091490R01.BIM
A001CNXB/Clip/A001C006_260914XT.MOV
A001CNXB/Clip/A001C011_260914NW.MOV
A001CNXB/Clip/A001C011_260914NWR01.BIM
A001CNXB/Clip/A001C012_260914JVM01.XML
A001CNXB/Clip/A001C014_2609149VM01.XML
A001CNXB/Clip/A001C003_260914IJM01.XML
A001CNXB/Clip/A001C001_260914A8R01.BIM
A001CNXB/Clip/A001C013_2609140G.MOV
A001CNXB/Clip/A001C005_260914K7R01.BIM
A001CNXB/Clip/A001C004_260914AKR01.BIM
A001CNXB/Clip/A001C006_260914XTM01.XML
A001CNXB/Clip/A001C015_2609147FR01.BIM
A001CNXB/Clip/A001C009_260914UQM01.XML
A001CNXB/Clip/A001C012_260914JV.MOV
A001CNXB/Clip/A001C008_2609148K.MOV
A001CNXB/Clip/A001C009_260914UQR01.BIM
A001CNXB/Clip/A001C003_260914IJ.MOV
A001CNXB/Clip/A001C010_260914IH.MOV
A001CNXB/Clip/A001C006_260914XTR01.BIM
A001CNXB/Clip/A001C005_260914K7.MOV
A001CNXB/Clip/A001C015_2609147FM01.XML
A001CNXB/Clip/A001C009_260914UQ.MOV
A001CNXB/Clip/A001C004_260914AKM01.XML
A001CNXB/Clip/A001C005_260914K7M01.XML
A001CNXB/Clip/A001C001_260914A8M01.XML
A001CNXB/Clip/A001C002_26091476.MOV
A001CNXB/Clip/A001C001_260914A8.MOV
A001CNXB/Clip/A001C003_260914IJR01.BIM
A001CNXB/Clip/A001C011_260914NWM01.XML
A001CNXB/Clip/A001C014_2609149V.MOV
A001CNXB/Clip/A001C014_2609149VR01.BIM
A001CNXB/Clip/A001C012_260914JVR01.BIM
A001CNXB/Clip/A001C007_26091490M01.XML
A001CNXB/Clip/A001C007_26091490.MOV
A001CNXB/Clip/A001C008_2609148KR01.BIM
A001CNXB/Clip/A001C010_260914IHM01.XML
A001CNXB/Clip/A001C013_2609140GM01.XML
A001CNXB/Clip/A001C002_26091476M01.XML
A001CNXB/DISCMETA.XML
A001CNXB/Edit
A001CNXB/Sub
A001CNXB/Take
A001CNXB/Thmbnl
A001CNXB/UserData
A001CNXB/CUEUP.XML
""".split(separator: "\n").map(String.init)

    @Test(arguments: [VerificationMode.quick, .standard, .thorough, .paranoid])
    func internalStorageReportedTree(mode: VerificationMode) async throws {
        try await checkReportedTree(mode: mode, filesystem: "local")
    }

    // hdiutil waits are intentionally opt-in so mounted-image setup does not starve
    // short-deadline concurrency tests in the normal parallel Swift Testing run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_ISSUE8_MOUNTED"] == "1"),
          arguments: [VerificationMode.quick, .standard, .thorough, .paranoid], ["ExFAT", "JHFS+"])
    func mountedSourceReportedTree(mode: VerificationMode, filesystem: String) async throws {
        try await checkReportedTree(mode: mode, filesystem: filesystem)
    }

    // Private reporter metadata stays outside the repository. Only an explicit local
    // path enables these cases; MOV bytes, when requested, remain synthetic.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_ISSUE8_METADATA"] != nil),
          arguments: [VerificationMode.quick, .standard, .thorough, .paranoid], [false, true])
    func reporterMetadata(mode: VerificationMode, includeSyntheticMovies: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BITMATCH_ISSUE8_METADATA"])
        try await checkReportedTree(mode: mode, filesystem: "local",
                                    metadata: URL(fileURLWithPath: path), includeMovies: includeSyntheticMovies)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_ISSUE8_METADATA"] != nil),
          arguments: ["ExFAT", "JHFS+"], [false, true])
    func reporterMetadataMounted(filesystem: String, includeSyntheticMovies: Bool) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BITMATCH_ISSUE8_METADATA"])
        try await checkReportedTree(mode: .standard, filesystem: filesystem,
                                    metadata: URL(fileURLWithPath: path), includeMovies: includeSyntheticMovies)
    }

    private func checkReportedTree(mode: VerificationMode, filesystem: String,
                                   metadata: URL? = nil, includeMovies: Bool = true) async throws {
        try await FileOperationsTestLock.shared.run {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-issue8-\(UUID().uuidString)")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let mount = root.appendingPathComponent("mnt")
            var mounted = false
            defer {
                // Never remove the mount's contents if detach fails; retain the fixture for cleanup.
                let detached = !mounted || Self.diskImage(["detach", "-quiet", mount.path]) == 0
                #expect(detached)
                if detached { try? fm.removeItem(at: root) }
            }
            var sourceBase = root.appendingPathComponent("SOURCE")
            if filesystem != "local" {
                try fm.createDirectory(at: mount, withIntermediateDirectories: true)
                let image = root.appendingPathComponent("source.sparseimage")
                try #require(Self.diskImage(["create", "-quiet", "-size", "256m", "-type", "SPARSE", "-fs", filesystem, "-volname", "BMSONY8", "-o", image.path]) == 0)
                try #require(Self.diskImage(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path]) == 0)
                mounted = true
                sourceBase = mount
            }
            let source = sourceBase.appendingPathComponent("A001CNXB")
            let backup = root.appendingPathComponent("BACKUP")
            let destination = backup.appendingPathComponent("A001CNXB")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            let directories: Set<String> = ["General", "General/Sony", "General/Sony/Planning", "Clip", "Edit", "Sub", "Take", "Thmbnl", "UserData"]
            var manifest: [String: Data] = [:]
            for fullPath in Self.paths {
                let relative = String(fullPath.dropFirst("A001CNXB/".count))
                let url = source.appendingPathComponent(relative)
                if directories.contains(relative) {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data: Data
                    if let metadata {
                        let supplied = metadata.appendingPathComponent(relative)
                        if fm.fileExists(atPath: supplied.path) {
                            data = try Data(contentsOf: supplied)
                        } else if includeMovies && url.pathExtension == "MOV" {
                            data = Data(("synthetic " + relative + "\n").utf8)
                        } else { continue }
                    } else { data = Data(("synthetic " + relative + "\n").utf8) }
                    try data.write(to: url)
                    manifest[relative] = data
                }
            }
            #expect(manifest.count == (metadata == nil ? 49 : (includeMovies ? 48 : 33)))
            let pipeline = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
            let initialEntries = try CardSource.enumerateRegularFiles(base: source)
            let initialContents = try Dictionary(uniqueKeysWithValues: initialEntries.map {
                ($0.relativePath, try Data(contentsOf: $0.url))
            })
            for attempt in 0..<2 {
                let operation = try await pipeline.performFileOperation(
                    sourceURL: source, destinationURLs: [backup], verificationMode: mode,
                    settings: CameraLabelSettings(), estimatedTotalBytes: nil,
                    progressCallback: { _ in }, onFileResult: { _ in })
                #expect(operation.results.count == initialContents.count)
                if mode == .quick && attempt == 1 {
                    // Quick cannot prove existing bytes: refusal is intentional, never overwrite.
                    #expect(operation.results.allSatisfy { $0.outcome == .failed && $0.error != nil })
                } else {
                    #expect(operation.results.allSatisfy { mode == .quick ? $0.outcome == .copiedUnverified : $0.outcome == .verified })
                }
                let current = try Dictionary(uniqueKeysWithValues: CardSource.enumerateRegularFiles(base: source).map {
                    ($0.relativePath, try Data(contentsOf: $0.url))
                })
                #expect(current == initialContents)
                for (name, bytes) in initialContents {
                    #expect(try Data(contentsOf: source.appendingPathComponent(name)) == bytes)
                    #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == bytes)
                }
                for name in directories {
                    var isDirectory: ObjCBool = false
                    #expect(fm.fileExists(atPath: destination.appendingPathComponent(name).path, isDirectory: &isDirectory))
                    #expect(isDirectory.boolValue)
                }
            }
            let comparer = FolderComparer(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            func compare() async throws -> CompareStats {
                try await comparer.compare(left: source, right: destination, verificationMode: mode, progress: { _ in })
            }
            var stats = try await compare()
            #expect(stats.onlyInLeftCount == 0 && stats.onlyInRightCount == 0 && stats.mismatchedCount == 0)
            // Plant: remove destination-only metadata filtering in FolderComparer; this must fail.
            try Data("Finder view state".utf8).write(to: destination.appendingPathComponent("Clip/.DS_Store"))
            try Data("Finder companion".utf8).write(to: destination.appendingPathComponent("Clip/._A001C001_260914A8.MOV"))
            stats = try await compare()
            #expect(stats.onlyInRightCount == 0 && stats.mismatchedCount == 0)
            try Data("real extra".utf8).write(to: destination.appendingPathComponent("Clip/EXTRA.BIM"))
            stats = try await compare()
            #expect(stats.onlyInRightPaths == ["Clip/EXTRA.BIM"])
            try fm.removeItem(at: destination.appendingPathComponent("Clip/EXTRA.BIM"))
            let clip = includeMovies ? "Clip/A001C001_260914A8.MOV" : "Clip/A001C001_260914A8R01.BIM"
            var damaged = try #require(manifest[clip]); damaged[0] ^= 1
            try damaged.write(to: destination.appendingPathComponent(clip))
            stats = try await compare()
            #expect(stats.mismatchedCount == (mode == .quick ? 0 : 1))
            #expect(try Data(contentsOf: source.appendingPathComponent(clip)) == manifest[clip])
        }
    }
}
