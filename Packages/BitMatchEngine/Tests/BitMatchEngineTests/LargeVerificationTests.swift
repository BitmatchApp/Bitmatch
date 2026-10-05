#if os(macOS)
import Foundation
import Darwin
import CryptoKit
import Testing
@testable import BitMatchEngine

struct LargeVerificationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_LARGE_VERIFY_ROOT"] != nil))
    func eightClipExFATToHFSTransfer() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["BITMATCH_LARGE_VERIFY_ROOT"])
        try #require(path.hasPrefix("/tmp/bitmatch-large-verify."))
        let root = URL(fileURLWithPath: path)
        let source = root.appendingPathComponent("source/Card")
        let destVolume = root.appendingPathComponent("destination")
        func fs(_ url: URL) throws -> String {
            var facts = statfs(); #expect(statfs(url.path, &facts) == 0)
            return withUnsafePointer(to: &facts.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
        }
        #expect(try fs(root.appendingPathComponent("source")) == "exfat")
        #expect(try fs(destVolume) == "hfs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var expected: [String: String] = [:]
        for index in 0..<8 {
            let name = String(format: "clip-%02d.bin", index)
            let file = source.appendingPathComponent(name)
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            var sha = SHA256()
            // 6 x 256 MiB + 2 x 3 GiB = 7.5 GiB. Deliberately smaller than
            // the reporter's card; preserves eight clips and overlapping tails.
            let chunks = index < 6 ? 64 : 768
            for _ in 0..<chunks {
                try autoreleasepool {
                    let data = Data(repeating: UInt8(index + 1), count: 4 * 1024 * 1024)
                    try handle.write(contentsOf: data); sha.update(data: data)
                }
            }
            try handle.synchronize(); try handle.close()
            expected[name] = sha.finalize().map { String(format: "%02x", $0) }.joined()
        }
        // macOS creates real AppleDouble companions on exFAT. Include them
        // in both the manifest expectation and unchanged-source proof.
        // Foundation's directory listing hides AppleDouble on this driver;
        // use the known fixture names with lstat rather than that listing.
        for index in 0..<8 {
            let file = source.appendingPathComponent(String(format: "._clip-%02d.bin", index))
            var facts = stat()
            if lstat(file.path, &facts) == 0 {
                expected[file.lastPathComponent] = try await ChecksumEngine.shared.generateChecksum(for: file, type: .sha256, progressCallback: nil)
            }
        }
        for workers in [1, 2] {
            let destination = destVolume.appendingPathComponent("Workers-\(workers)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let run = UUID()
            let op = try await TransferDiagnostics.$runID.withValue(run) {
                try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                    verificationConcurrency: workers).performFileOperation(sourceURL: source, destinationURLs: [destination],
                        verificationMode: .standard, settings: CameraLabelSettings(), estimatedTotalBytes: 8_053_063_680,
                        progressCallback: { _ in }, onFileResult: nil)
            }
            #expect(op.results.count == expected.count)
            #expect(op.results.allSatisfy { $0.success })
            for result in op.results {
                #expect(result.verificationResult?.destinationChecksum == expected[result.sourceURL.lastPathComponent])
                #expect(try await ChecksumEngine.shared.generateChecksum(for: result.destinationURL, type: .sha256, progressCallback: nil) == expected[result.sourceURL.lastPathComponent])
            }
            print("large transfer workers=\(workers) results=\(op.results.count) clips=8 mediaBytes=8053063680")
        }
        for (name, digest) in expected {
            #expect(try await ChecksumEngine.shared.generateChecksum(for: source.appendingPathComponent(name), type: .sha256, progressCallback: nil) == digest)
        }
    }
}
#endif
