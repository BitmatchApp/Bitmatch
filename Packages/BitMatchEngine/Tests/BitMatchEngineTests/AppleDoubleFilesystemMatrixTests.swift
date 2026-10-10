#if os(macOS)
import Foundation
import CryptoKit
import Synchronization
import XCTest
@testable import BitMatchEngine

/// Real drivers and real macOS-created metadata, not filename-only stand-ins.
/// Disk images exercise filesystem semantics, not physical reader/dock faults.
final class AppleDoubleFilesystemMatrixTests: XCTestCase {
    func testGeneratedMetadataAcrossAPFSHFSAndExFATInitialRepeatAndFilteredCopies() async throws {
        try await FileOperationsTestLock.shared.run {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("bitmatch-issue16-matrix-\(UUID())")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var mounted: [URL] = []
            var allDetached = true
            func run(_ executable: String, _ args: [String]) throws {
                let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw NSError(domain: "MatrixSetup", code: Int(process.terminationStatus)) }
            }
            defer {
                for mount in mounted.reversed() {
                    do { try run("/usr/bin/hdiutil", ["detach", "-quiet", mount.path]) }
                    catch { allDetached = false; XCTFail("Owned image retained at \(root.path): \(error)") }
                }
                if allDetached { try? fm.removeItem(at: root) }
            }
            var sources: [URL] = []
            var backups: [URL] = []
            for (index, fs) in ["APFS", "HFS+", "ExFAT"].enumerated() {
                for role in ["source", "backup"] {
                    let image = root.appendingPathComponent("\(role)-\(index)")
                    let mount = root.appendingPathComponent("mnt-\(role)-\(index)")
                    try fm.createDirectory(at: mount, withIntermediateDirectories: true)
                    try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "3g", "-type", "SPARSE", "-fs", fs, "-volname", "BM16\(index)\(role)", "-o", image.path])
                    try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path + ".sparseimage"])
                    mounted.append(mount)
                    if role == "source" { sources.append(mount) } else { backups.append(mount) }
                }
            }
            // Generate the canonical companion on exFAT through xattr, then use
            // those real bytes for APFS/HFS+ sources, where xattrs are native.
            let seed = sources[2].appendingPathComponent("seed.bin")
            try Data("seed".utf8).write(to: seed)
            try run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000001;BM16Source;", seed.path])
            let companionBytes = try Data(contentsOf: sources[2].appendingPathComponent("._seed.bin"))
            for (sourceIndex, volume) in sources.enumerated() {
                let card = volume.appendingPathComponent("Card")
                try fm.createDirectory(at: card, withIntermediateDirectories: true)
                let media = card.appendingPathComponent("clip.bin")
                let bytes = Data(repeating: UInt8(sourceIndex + 17), count: 64 * 1024)
                try bytes.write(to: media)
                if sourceIndex == 2 {
                    try run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;00000001;BM16Source;", media.path])
                } else {
                    try companionBytes.write(to: card.appendingPathComponent("._clip.bin"))
                }
                try Data("legitimate camera sidecar".utf8).write(to: card.appendingPathComponent("._notes.txt"))
                let before = try CardSource.enumerateRegularFiles(base: card)
                let sourceHashes = try Dictionary(uniqueKeysWithValues: before.map { ($0.relativePath, SHA256.hash(data: try Data(contentsOf: $0.url))) })
                let excluded = try AppleDoubleSelection.review(source: card)
                XCTAssertEqual(excluded, ["._clip.bin"], "source filesystem \(sourceIndex)")
                for backupIndex in backups.indices {
                    let secondary = (backupIndex + 1) % backups.count
                    let targets = [backups[backupIndex], backups[secondary]].map { $0.appendingPathComponent("pair-\(sourceIndex)-\(backupIndex)") }
                    for target in targets { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
                    var settings = CameraLabelSettings()
                    // Initial and repeat preserve everything by default.
                    for attempt in 0..<2 {
                        let trace = Mutex<[String]>([])
                        let traceEnabled = sourceIndex == 0 && backupIndex == 2 && attempt == 0
                        let hooks: DestinationWriter.FanOutHooks? = traceEnabled ? .init(
                            beforePublish: { index, root in
                                guard index == 0 else { return }
                                let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent("._clip.bin").path)
                                trace.withLock { $0.append("before publication: companion exists=\(exists)") }
                            }, afterPublish: { index, root in
                                guard index == 0 else { return }
                                let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent("._clip.bin").path)
                                trace.withLock { $0.append("after publication: companion exists=\(exists)") }
                            }) : nil
                        let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks)
                            .performFileOperation(sourceURL: card, destinationURLs: targets, verificationMode: .standard,
                                settings: settings, progressCallback: { _ in }, onFileResult: nil)
                        XCTAssertEqual(operation.results.count, before.count * 2)
                        if traceEnabled {
                            let observations = trace.withLock { $0 }
                            XCTAssertTrue(observations.contains("before publication: companion exists=false"))
                            XCTAssertTrue(observations.contains("after publication: companion exists=true"))
                            print("Issue16 fresh exFAT trace: " + observations.joined(separator: "; "))
                        }
                        for result in operation.results {
                            let relative = result.sourceURL.relativePath(to: card)
                            if result.success {
                                XCTAssertEqual(result.verificationResult?.isValid, true)
                                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: result.destinationURL)), sourceHashes[relative])
                            } else {
                                // Confirmed fresh-copy behavior: publication on
                                // exFAT may create a different metadata companion.
                                // Refusal is required; overwriting it is not a fix.
                                XCTAssertEqual(relative, "._clip.bin")
                                XCTAssertTrue(result.destinationURL.path.hasPrefix(backups[2].path))
                                XCTAssertTrue(result.error?.localizedDescription.contains("hidden companion") == true)
                                XCTAssertNotEqual(SHA256.hash(data: try Data(contentsOf: result.destinationURL)), sourceHashes[relative])
                            }
                        }
                    }
                    // Deliberately conflicting real metadata must remain intact;
                    // exclusion avoids comparing/writing it without hiding media failures.
                    let output = targets[0].appendingPathComponent("Card")
                    var changed = try Data(contentsOf: output.appendingPathComponent("._clip.bin"))
                    changed[changed.count - 1] ^= 1
                    try changed.write(to: output.appendingPathComponent("._clip.bin"))
                    let conflict = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                        .performFileOperation(sourceURL: card, destinationURLs: targets, verificationMode: .standard,
                            settings: settings, progressCallback: { _ in }, onFileResult: nil)
                    XCTAssertTrue(conflict.results.contains { $0.sourceURL.lastPathComponent == "._clip.bin" && !$0.success })
                    settings.excludedAppleDoublePaths = excluded
                    let filtered = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                        .performFileOperation(sourceURL: card, destinationURLs: targets, verificationMode: .standard,
                            settings: settings, progressCallback: { _ in }, onFileResult: nil)
                    XCTAssertEqual(filtered.results.filter(\.excludedAppleDouble).count, 2)
                    XCTAssertTrue(filtered.results.filter { !$0.excludedAppleDouble }.allSatisfy { $0.verificationResult?.isValid == true })
                    XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("._clip.bin")), changed)
                    XCTAssertEqual(filtered.sourceManifest?.count, before.count)
                    // First filtered copy into empty targets, then a repeat.
                    let freshTargets = [backups[backupIndex], backups[secondary]].map {
                        $0.appendingPathComponent("filtered-\(sourceIndex)-\(backupIndex)")
                    }
                    for target in freshTargets { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
                    for _ in 0..<2 {
                        let fresh = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                            .performFileOperation(sourceURL: card, destinationURLs: freshTargets, verificationMode: .standard,
                                settings: settings, progressCallback: { _ in }, onFileResult: nil)
                        XCTAssertEqual(fresh.results.filter(\.excludedAppleDouble).count, 2)
                        for result in fresh.results where !result.excludedAppleDouble {
                            XCTAssertEqual(result.verificationResult?.isValid, true)
                            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: result.destinationURL)),
                                           sourceHashes[result.sourceURL.relativePath(to: card)])
                        }
                    }
                }
                let after = try CardSource.enumerateRegularFiles(base: card)
                XCTAssertEqual(after.map(\.relativePath).sorted(), before.map(\.relativePath).sorted())
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: after.map { ($0.relativePath, $0.modificationDate) }),
                               Dictionary(uniqueKeysWithValues: before.map { ($0.relativePath, $0.modificationDate) }))
                for entry in after {
                    XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: entry.url)), sourceHashes[entry.relativePath])
                }
            }
            print("Issue16 matrix: 3 source × 3 primary backup filesystems, 2 backups, initial/repeat/conflict/filtered/fresh-filtered/repeated-filtered = 54 transfers; fresh exFAT metadata conflicts retained, selected-file output and unchanged-source hashes checked.")
        }
    }
}
#endif
