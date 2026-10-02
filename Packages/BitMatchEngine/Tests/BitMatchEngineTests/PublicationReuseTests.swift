#if os(macOS)
import Foundation
import XCTest
@testable import BitMatchEngine

final class PublicationReuseTests: XCTestCase {
    func testDifferentFileAppearingAtPublicationIsPreserved() async throws {
        try await FileOperationsTestLock.shared.run {
            for mode in VerificationMode.allCases {
                let fixture = try DisposableTransferFixture(seed: 20261003, fileCount: 1, bytesPerFile: 4096)
                defer { fixture.cleanup() }
                let path = try XCTUnwrap(fixture.manifest.keys.sorted().first)
                for other in fixture.manifest.keys where other != path {
                    try FileManager.default.removeItem(at: fixture.source.appendingPathComponent(other))
                }
                let original = try Data(contentsOf: fixture.source.appendingPathComponent(path))
                let conflicting = Data(repeating: 99, count: original.count)
                let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                    fanOutHooks: .init(beforePublish: { _, root in
                        try conflicting.write(to: root.appendingPathComponent(path), options: .withoutOverwriting)
                    }))
                let operation = try await service.performFileOperation(sourceURL: fixture.source,
                    destinationURLs: fixture.destinations, verificationMode: mode, settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
                XCTAssertEqual(operation.results.count, fixture.destinations.count)
                for result in operation.results {
                    XCTAssertFalse(result.success, "\(mode)")
                    XCTAssertEqual(try Data(contentsOf: result.destinationURL), conflicting)
                }
                XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent(path)), original)
            }
        }
    }

    func testMatchingFileAppearingAtPublicationCanBeVerifiedWithoutOverwrite() async throws {
        try await FileOperationsTestLock.shared.run {
            for mode in VerificationMode.allCases {
                let fixture = try DisposableTransferFixture(seed: 20261002, fileCount: 1, bytesPerFile: 4096)
                defer { fixture.cleanup() }
                let entry = try XCTUnwrap(fixture.manifest.sorted { $0.key < $1.key }.first)
                for path in fixture.manifest.keys where path != entry.key {
                    try FileManager.default.removeItem(at: fixture.source.appendingPathComponent(path))
                }
                let bytes = try Data(contentsOf: fixture.source.appendingPathComponent(entry.key))
                let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                    fanOutHooks: .init(beforePublish: { _, root in
                        try bytes.write(to: root.appendingPathComponent(entry.key), options: .withoutOverwriting)
                    }))
                let operation = try await service.performFileOperation(sourceURL: fixture.source,
                    destinationURLs: fixture.destinations, verificationMode: mode, settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
                XCTAssertEqual(operation.results.count, fixture.destinations.count)
                for result in operation.results {
                    XCTAssertEqual(result.success, mode != .quick, "\(mode)")
                    XCTAssertEqual(result.wasReused, mode != .quick, "\(mode)")
                    XCTAssertEqual(try Data(contentsOf: result.destinationURL), bytes)
                }
            }
        }
    }
}
#endif
