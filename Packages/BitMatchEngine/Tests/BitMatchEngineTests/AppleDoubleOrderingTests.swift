#if os(macOS)
import Foundation
import Synchronization
import XCTest
@testable import BitMatchEngine

final class AppleDoubleOrderingTests: XCTestCase {
    func testCompanionPublicationCannotRetireAnAlreadyCopiedSidecar() async throws {
        try await FileOperationsTestLock.shared.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-appledouble-order-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("Card")
            let backup = root.appendingPathComponent("Backup")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            let media = source.appendingPathComponent("clip.bin")
            let sidecar = source.appendingPathComponent("._clip.bin")
            let mediaBytes = Data(repeating: 13, count: 4096)
            let sidecarBytes = Data("original metadata".utf8)
            try mediaBytes.write(to: media)
            try sidecarBytes.write(to: sidecar)
            let pinned = try PinnedDestinationDirectory.open(destination: backup, rootComponents: ["Card"])
            let current = Mutex("")
            // One worker makes the adverse old order deterministic. The hook
            // models the companion publication retiring its existing metadata.
            try await DestinationWriter.copyAllSafelyFanOut(from: source,
                toPinnedRoots: [.init(index: 0, root: pinned)], verificationMode: .standard,
                workers: 1, checksumService: ChecksumEngine.shared,
                preEnumeratedFiles: [sidecar, media], hooks: .init(
                    beforeSourceOpen: { url in current.withLock { $0 = url.lastPathComponent } },
                    afterPublish: { _, destination in
                        if current.withLock({ $0 }) == "clip.bin" {
                            let metadata = destination.appendingPathComponent("._clip.bin")
                            if FileManager.default.fileExists(atPath: metadata.path) {
                                try FileManager.default.removeItem(at: metadata)
                            }
                        }
                    }), onProgress: { _, _, _, _ in }, onError: { _, path, error in
                        XCTFail("\(path): \(error)")
                    })
            XCTAssertEqual(try Data(contentsOf: pinned.logicalRootURL.appendingPathComponent("clip.bin")), mediaBytes)
            XCTAssertEqual(try Data(contentsOf: pinned.logicalRootURL.appendingPathComponent("._clip.bin")), sidecarBytes)
            XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBytes)
            XCTAssertEqual(try Data(contentsOf: media), mediaBytes)
        }
    }
}
#endif
