import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

final class TransferFaultIntegrationTests: XCTestCase {
    private static let serializationGate = DispatchSemaphore(value: 1)

    override func setUp() {
        super.setUp()
        Self.serializationGate.wait()
    }

    override func tearDown() {
        Self.serializationGate.signal()
        super.tearDown()
    }

    func testSourceMutationIsReportedAsFailureWithoutCorruptingPublishedOutput() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 401, fileCount: 2, bytesPerFile: 64 * 1024)
            defer { fixture.cleanup() }
            let source = canonicalFileURL(fixture.source)
            let targetRelativePath = "DCIM/100MEDIA/MEDIA_0000.bin"
            let targetSourceURL = source.appendingPathComponent(targetRelativePath)
            let service = makeService()
            let mutationTrigger = OneShot()

            let operation = try await service.performFileOperation(
                sourceURL: source,
                destinationURLs: [fixture.destinations[0]],
                verificationMode: .standard,
                settings: CameraLabelSettings(),
                estimatedTotalBytes: nil,
                progressCallback: { _ in },
                onFileResult: { result in
                    // Local destinations verify through a descriptor-pinned,
                    // fd-safe checksum read that intentionally does not go
                    // through an injectable ChecksumService (that would
                    // reopen the destination by path, defeating the symlink
                    // -swap protection). So instead of hooking verification,
                    // mutate the source the instant its copy result is
                    // published -- guaranteed to happen before the pipelined
                    // verify task for this file is even created -- to
                    // simulate a card that changes between copy and verify.
                    guard result.verificationResult == nil,
                          result.sourceURL.path == targetSourceURL.path,
                          mutationTrigger.take() else { return }
                    try? Data("source changed after publication".utf8).write(to: targetSourceURL, options: .atomic)
                }
            )

            let targetResult = try XCTUnwrap(operation.results.first {
                $0.sourceURL.path == source.appendingPathComponent(targetRelativePath).path
            }, "Results: \(describe(operation.results))")
            XCTAssertFalse(targetResult.success)
            XCTAssertFalse(resultRow(from: targetResult).isSuccessStatus)
            let publishedHash = try await ChecksumEngine.shared.generateChecksum(
                for: targetResult.destinationURL,
                type: .sha256,
                progressCallback: nil
            )
            XCTAssertEqual(publishedHash, fixture.manifest[targetRelativePath])
            // A mid-run source change fails the whole run closed, so no row
            // stays successful; the published bytes must still be intact.
            try await assertAllPublishedOutputHashes(in: operation, match: fixture.manifest)
        }
    }

    func testConflictingPreExistingFileRemainsUntouchedAndIsReportedAsFailure() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 402, fileCount: 2, bytesPerFile: 4 * 1024)
            defer { fixture.cleanup() }
            let source = canonicalFileURL(fixture.source)
            let settings = CameraLabelSettings()
            let outputRoot = SafetyValidator.resolvedDestinationRoot(
                source: source,
                destination: fixture.destinations[0],
                settings: settings
            )
            let relativePath = "DCIM/100MEDIA/MEDIA_0000.bin"
            let conflict = outputRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: conflict.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let sentinel = Data("pre-existing user data".utf8)
            try sentinel.write(to: conflict)

            let operation = try await makeService().performFileOperation(
                sourceURL: source,
                destinationURLs: [fixture.destinations[0]],
                verificationMode: .standard,
                settings: settings,
                estimatedTotalBytes: nil,
                progressCallback: { _ in },
                onFileResult: nil
            )

            XCTAssertEqual(try Data(contentsOf: conflict), sentinel)
            let failed = try XCTUnwrap(
                operation.results.first { $0.destinationURL.path == conflict.path },
                "Results: \(describe(operation.results))"
            )
            XCTAssertFalse(failed.success)
            XCTAssertFalse(resultRow(from: failed).isSuccessStatus)
            try await assertSuccessfulOutputHashes(in: operation, match: fixture.manifest)
        }
    }

    func testCancellationRemovesTemporaryFiles() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 403, fileCount: 12, bytesPerFile: 2 * 1024 * 1024)
            defer { fixture.cleanup() }
            let source = canonicalFileURL(fixture.source)
            let service = makeService()
            let cancellation = OneShot()
            let successfulResult = CapturedSuccessfulResult()

            do {
                _ = try await service.performFileOperation(
                    sourceURL: source,
                    destinationURLs: [fixture.destinations[0]],
                    verificationMode: .standard,
                    settings: CameraLabelSettings(),
                    estimatedTotalBytes: nil,
                    progressCallback: { _ in },
                    onFileResult: { result in
                        if result.success {
                            successfulResult.capture(result)
                        }
                        if result.success, cancellation.take() {
                            service.cancelOperation()
                        }
                    }
                )
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Expected.
            }

            let publishedResult = try XCTUnwrap(
                successfulResult.value,
                "Cancellation did not retain a known successful output"
            )
            try await assertOutputHash(
                for: publishedResult,
                source: source,
                manifest: fixture.manifest
            )

            let temporaryFiles = recursivelyEnumeratedPaths(at: fixture.destinations[0]).filter {
                $0.lastPathComponent.hasPrefix(".bitmatch.tmp.")
            }
            XCTAssertTrue(temporaryFiles.isEmpty, "Cancellation left temporary files: \(temporaryFiles)")
        }
    }

    func testInaccessibleDestinationReportsFailuresWhileOtherDestinationSucceeds() async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 404, fileCount: 2, bytesPerFile: 4 * 1024)
            defer { fixture.cleanup() }
            let source = canonicalFileURL(fixture.source)
            let settings = CameraLabelSettings()
            let goodDestination = fixture.destinations[0]
            let faultDestination = try validatedFaultDestination(from: fixture)
            let inaccessibleRoot = SafetyValidator.resolvedDestinationRoot(
                source: source,
                destination: faultDestination,
                settings: settings
            )
            try FileManager.default.createDirectory(at: inaccessibleRoot, withIntermediateDirectories: true)
            let faultFileSystem = FaultInjectingFileSystemService(
                faultDestination: faultDestination,
                inaccessibleRoot: inaccessibleRoot
            )
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inaccessibleRoot.path)
            }

            let operation = try await TransferPipeline(
                fileSystem: faultFileSystem,
                checksum: ChecksumEngine.shared,
                destinationSetupHook: { faultFileSystem.injectFault(for: $0) }
            ).performFileOperation(
                sourceURL: source,
                destinationURLs: [goodDestination, faultDestination],
                verificationMode: .standard,
                settings: settings,
                estimatedTotalBytes: nil,
                progressCallback: { _ in },
                onFileResult: nil
            )

            let goodRoot = SafetyValidator.resolvedDestinationRoot(
                source: source,
                destination: goodDestination,
                settings: settings
            )
            let goodResults = operation.results.filter { $0.destinationURL.path.hasPrefix(goodRoot.path + "/") }
            let faultResults = operation.results.filter {
                $0.destinationURL.path.hasPrefix(inaccessibleRoot.path + "/")
                    && manifestRelativePath(for: $0, source: source, manifest: fixture.manifest) != nil
            }
            XCTAssertTrue(faultFileSystem.didInjectFault, "Fault filesystem did not make destination inaccessible")
            XCTAssertEqual(goodResults.count, fixture.manifest.count, describe(operation.results))
            XCTAssertTrue(goodResults.allSatisfy(\.success), describe(operation.results))
            XCTAssertEqual(faultResults.count, fixture.manifest.count, describe(operation.results))
            XCTAssertTrue(faultResults.allSatisfy { !$0.success })
            XCTAssertTrue(faultResults.map(resultRow).allSatisfy { !$0.isSuccessStatus })
            XCTAssertTrue(operation.results.filter { !$0.success }.map(resultRow).allSatisfy { !$0.isSuccessStatus })
            try await assertSuccessfulOutputHashes(in: operation, match: fixture.manifest)
        }
    }
}

private func canonicalFileURL(_ url: URL) -> URL {
    // Match the engine's existence-independent root canonicalization
    // (standardized + resolvingSymlinksKeepingCase). C realpath() fully
    // resolves /var to /private/var while Foundation does not, so a
    // realpath-based prefix never matches engine-issued result URLs.
    url.standardizedFileURL.resolvingSymlinksKeepingCase()
}

private func manifestRelativePath(
    for result: FileOperationResult,
    source: URL,
    manifest: [String: String]
) -> String? {
    let prefix = source.path + "/"
    guard result.sourceURL.path.hasPrefix(prefix) else { return nil }
    let relativePath = String(result.sourceURL.path.dropFirst(prefix.count))
    return manifest[relativePath] == nil ? nil : relativePath
}

private func describe(_ results: [FileOperationResult]) -> String {
    results.map {
        "src=\($0.sourceURL.path), dst=\($0.destinationURL.path), success=\($0.success), status=\($0.statusDescription)"
    }.joined(separator: " | ")
}

private func makeService(
    fileSystem: any FileAccess = LocalFileAccess()
) -> TransferPipeline {
    TransferPipeline(
        fileSystem: fileSystem,
        checksum: ChecksumEngine.shared
    )
}

private func resultRow(from result: FileOperationResult) -> ResultRow {
    ResultRow(
        path: result.sourceURL.path,
        status: result.statusDescription,
        size: result.fileSize,
        checksum: result.verificationResult?.sourceChecksum,
        destination: result.destinationURL.deletingLastPathComponent().lastPathComponent,
        destinationPath: result.destinationURL.path
    )
}

private func assertSuccessfulOutputHashes(
    in operation: FileOperation,
    match manifest: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let successfulResults = operation.results.filter(\.success)
    guard !successfulResults.isEmpty else {
        XCTFail("Expected at least one successful output", file: file, line: line)
        return
    }
    for result in successfulResults {
        let sourcePrefix = operation.sourceURL.path + "/"
        guard result.sourceURL.path.hasPrefix(sourcePrefix) else {
            XCTFail("Result source escaped fixture", file: file, line: line)
            continue
        }
        let relativePath = String(result.sourceURL.path.dropFirst(sourcePrefix.count))
        let expected = try XCTUnwrap(manifest[relativePath], file: file, line: line)
        let actual = try await ChecksumEngine.shared.generateChecksum(
            for: result.destinationURL,
            type: .sha256,
            progressCallback: nil
        )
        XCTAssertEqual(actual, expected, "Unexpected hash for \(relativePath)", file: file, line: line)
    }
}

private func assertAllPublishedOutputHashes(
    in operation: FileOperation,
    match manifest: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    guard !operation.results.isEmpty else {
        XCTFail("Expected published outputs", file: file, line: line)
        return
    }
    for result in operation.results {
        let sourcePrefix = operation.sourceURL.path + "/"
        guard result.sourceURL.path.hasPrefix(sourcePrefix) else {
            XCTFail("Result source escaped fixture", file: file, line: line)
            continue
        }
        let relativePath = String(result.sourceURL.path.dropFirst(sourcePrefix.count))
        let expected = try XCTUnwrap(manifest[relativePath], file: file, line: line)
        let actual = try await ChecksumEngine.shared.generateChecksum(
            for: result.destinationURL,
            type: .sha256,
            progressCallback: nil
        )
        XCTAssertEqual(actual, expected, "Published output corrupted for \(relativePath)", file: file, line: line)
    }
}

private func assertOutputHash(
    for result: FileOperationResult,
    source: URL,
    manifest: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let sourcePrefix = source.path + "/"
    let relativePath = try XCTUnwrap(
        result.sourceURL.path.hasPrefix(sourcePrefix)
            ? String(result.sourceURL.path.dropFirst(sourcePrefix.count))
            : nil,
        "Successful result source escaped fixture",
        file: file,
        line: line
    )
    let expected = try XCTUnwrap(manifest[relativePath], file: file, line: line)
    let actual = try await ChecksumEngine.shared.generateChecksum(
        for: result.destinationURL,
        type: .sha256,
        progressCallback: nil
    )
    XCTAssertEqual(actual, expected, "Unexpected hash for \(relativePath)", file: file, line: line)
}

private func recursivelyEnumeratedPaths(at root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return []
    }
    return enumerator.compactMap { $0 as? URL }
}

private func validatedFaultDestination(from fixture: DisposableTransferFixture) throws -> URL {
    guard let path = ProcessInfo.processInfo.environment["BITMATCH_FAULT_VOLUME"], !path.isEmpty else {
        return fixture.destinations[1]
    }
    let destination = canonicalFileURL(URL(fileURLWithPath: path, isDirectory: true))
    let marker = destination.appendingPathComponent(".bitmatch-disposable-fixture")
    guard FileManager.default.fileExists(atPath: marker.path) else {
        throw XCTSkip("BITMATCH_FAULT_VOLUME is not marked as a disposable fixture")
    }
    return destination
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return false }
        available = false
        return true
    }
}

private final class CapturedSuccessfulResult: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: FileOperationResult?

    var value: FileOperationResult? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func capture(_ result: FileOperationResult) {
        lock.lock()
        defer { lock.unlock() }
        if captured == nil {
            captured = result
        }
    }
}

private final class FaultInjectingFileSystemService: FakeFileAccess {
    private let faultDestination: URL
    private let inaccessibleRoot: URL
    private let lock = NSLock()
    private var injected = false

    init(faultDestination: URL, inaccessibleRoot: URL) {
        self.faultDestination = faultDestination.standardizedFileURL
        self.inaccessibleRoot = inaccessibleRoot
        super.init(backing: LocalFileAccess())
    }

    var didInjectFault: Bool {
        lock.lock()
        defer { lock.unlock() }
        return injected
    }

    /// Runs from the engine's destination setup hook: after the safety
    /// checks, just before the destination is opened.
    nonisolated func injectFault(for url: URL) {
        guard url.standardizedFileURL == faultDestination else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !injected else { return }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: inaccessibleRoot.path
            )
            injected = true
        } catch {
            injected = false
        }
    }
}
