import Foundation
import CryptoKit
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

final class TransferSoakTests: XCTestCase, @unchecked Sendable {
    func testSourceGuardDetectsMutationAndInventoryChanges() throws {
        let fixture = try DisposableTransferFixture(seed: 13, fileCount: 1, bytesPerFile: 16)
        defer { if testRun?.totalFailureCount == 0 { fixture.cleanup() } }
        let source = soakCanonicalFileURL(fixture.source)
        XCTAssertEqual(try verifySoakSource(source, expected: fixture.manifest), 2)
        let file = source.appendingPathComponent("DCIM/100MEDIA/MEDIA_0000.bin")
        let original = try Data(contentsOf: file)
        try Data(repeating: 0xFE, count: original.count).write(to: file)
        XCTAssertThrowsError(try verifySoakSource(source, expected: fixture.manifest))
        try original.write(to: file)
        let extra = source.appendingPathComponent("unexpected.bin")
        try Data([1]).write(to: extra)
        XCTAssertThrowsError(try verifySoakSource(source, expected: fixture.manifest))
        try FileManager.default.removeItem(at: extra)
        let empty = source.appendingPathComponent("EMPTY_SIDECARS")
        try FileManager.default.removeItem(at: empty)
        XCTAssertThrowsError(try verifySoakSource(source, expected: fixture.manifest))
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        XCTAssertEqual(try verifySoakSource(source, expected: fixture.manifest), 2)
    }

    func testSeededStandardTransferToTwoDestinations() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_RUN_SOAK"] == "1" else {
            throw XCTSkip("Set BITMATCH_RUN_SOAK=1 to run the seeded transfer soak test")
        }

        try FileHandle.standardOutput.write(contentsOf: Data("SOAK workerPID=\(getpid())\n".utf8))
        let environment = ProcessInfo.processInfo.environment
        let seed = try parseUInt64(environment["BITMATCH_SOAK_SEED"], name: "BITMATCH_SOAK_SEED", default: 20_260_711)
        let iterations = try parsePositiveInt(
            environment["BITMATCH_SOAK_ITERATIONS"],
            name: "BITMATCH_SOAK_ITERATIONS",
            default: 25
        )
        var iterationSummaries: [SoakIterationSummary] = []

        let startingFailures = testRun?.totalFailureCount ?? 0
        let resultURL = environment["BITMATCH_SOAK_RESULT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        func save(outcome: String, summaries: [SoakIterationSummary]) throws {
            if let resultURL {
                try writeSoakSummary(SoakSummary(formatVersion: 2, baseSeed: seed,
                    requestedIterations: iterations, completedIterations: summaries.count,
                    verificationMode: "standard", destinationsPerIteration: 2, outcome: outcome,
                    iterations: summaries), to: resultURL)
            }
        }
        do {
            try await FileOperationsTestLock.shared.run {
                for iteration in 0..<iterations {
                    try Task.checkCancellation()
                    let iterationSeed = seed &+ UInt64(iteration)
                    let fixture = try DisposableTransferFixture(
                        seed: iterationSeed,
                        fileCount: 8,
                        bytesPerFile: 256 * 1024,
                        baseDirectory: environment["BITMATCH_SOAK_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                    )
                    var completed = false
                    defer {
                        if completed { fixture.cleanup() }
                        else { print("SOAK retainedFixture=\(fixture.source.deletingLastPathComponent().path) seed=\(iterationSeed)") }
                    }
                    let source = soakCanonicalFileURL(fixture.source)
                    try FileHandle.standardOutput.write(contentsOf: Data("SOAK fixtureRoot=\(fixture.source.deletingLastPathComponent().path) seed=\(iterationSeed)\n".utf8))
                    let beforeCount = try verifySoakSource(source, expected: fixture.manifest)
                    let operation = try await TransferPipeline(
                        fileSystem: LocalFileAccess(),
                        checksum: ChecksumEngine.shared
                    ).performFileOperation(
                        sourceURL: source,
                        destinationURLs: fixture.destinations,
                        verificationMode: .standard,
                        settings: CameraLabelSettings(),
                        estimatedTotalBytes: nil,
                        progressCallback: { _ in },
                        onFileResult: nil
                    )

                    let expectedResultCount = fixture.manifest.count * fixture.destinations.count
                    guard operation.results.count == expectedResultCount else {
                        throw SoakVerificationError.unexpectedResultCount(
                            expected: expectedResultCount,
                            actual: operation.results.count,
                            details: describeSoakResults(operation.results)
                        )
                    }
                    let expectedPaths = Set(fixture.destinations.flatMap { destination in
                        let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: .init())
                        return fixture.manifest.keys.map { output.appendingPathComponent($0).path }
                    })
                    guard Set(operation.results.map { $0.destinationURL.path }) == expectedPaths,
                          operation.results.allSatisfy({ $0.success && $0.verificationResult?.isValid == true }) else {
                        throw SoakVerificationError.failedOperationResults(describeSoakResults(operation.results))
                    }

                    var verifiedOutputs = 0
                    for result in operation.results {
                        let relativePath = try relativeManifestPath(for: result, source: source)
                        let expectedHash = try XCTUnwrap(fixture.manifest[relativePath])
                        let actualHash = try await ChecksumEngine.shared.generateChecksum(
                            for: result.destinationURL,
                            type: .sha256,
                            progressCallback: nil
                        )
                        guard actualHash == expectedHash else {
                            throw SoakVerificationError.hashMismatch(
                                relativePath: relativePath,
                                expected: expectedHash,
                                actual: actualHash
                            )
                        }
                        verifiedOutputs += 1
                    }

                    let afterCount = try verifySoakSource(source, expected: fixture.manifest)
                    try Task.checkCancellation()
                    guard testRun?.totalFailureCount == startingFailures else {
                        throw SoakVerificationError.assertionFailure
                    }
                    iterationSummaries.append(SoakIterationSummary(
                        iteration: iteration,
                        seed: iterationSeed,
                        manifestFiles: fixture.manifest.count,
                        verifiedOutputs: verifiedOutputs,
                        sourceHashesBefore: beforeCount, sourceHashesAfter: afterCount,
                        sourceDirectoriesBeforeAfter: 3,
                        payloadPattern: UInt8(truncatingIfNeeded: iterationSeed)
                    ))
                    try save(outcome: "running", summaries: iterationSummaries)
                    completed = true
                    try FileHandle.standardOutput.write(contentsOf: Data("SOAK iteration=\(iteration + 1) seed=\(iterationSeed) sourceBefore=\(beforeCount) sourceAfter=\(afterCount) destinations=\(verifiedOutputs)\n".utf8))
                }
            }

            try Task.checkCancellation()
            guard iterationSummaries.count == iterations, testRun?.totalFailureCount == startingFailures else {
                throw SoakVerificationError.assertionFailure
            }
            try save(outcome: "passed", summaries: iterationSummaries)
        } catch {
            try? save(outcome: "failed", summaries: iterationSummaries)
            throw error
        }

    }
}

private struct SoakSummary: Codable, Sendable {
    let formatVersion: Int
    let baseSeed: UInt64
    let requestedIterations: Int
    let completedIterations: Int
    let verificationMode: String
    let destinationsPerIteration: Int
    let outcome: String
    let iterations: [SoakIterationSummary]
}

private struct SoakIterationSummary: Codable, Sendable {
    let iteration: Int
    let seed: UInt64
    let manifestFiles: Int
    let verifiedOutputs: Int
    let sourceHashesBefore: Int
    let sourceHashesAfter: Int
    let sourceDirectoriesBeforeAfter: Int
    let payloadPattern: UInt8
}

private func parseUInt64(_ value: String?, name: String, default defaultValue: UInt64) throws -> UInt64 {
    guard let value, !value.isEmpty else { return defaultValue }
    guard let parsed = UInt64(value) else {
        throw SoakConfigurationError.invalidValue(name: name, value: value)
    }
    return parsed
}

private func parsePositiveInt(_ value: String?, name: String, default defaultValue: Int) throws -> Int {
    guard let value, !value.isEmpty else { return defaultValue }
    guard let parsed = Int(value), parsed > 0 else {
        throw SoakConfigurationError.invalidValue(name: name, value: value)
    }
    return parsed
}

private enum SoakConfigurationError: LocalizedError {
    case invalidValue(name: String, value: String)

    var errorDescription: String? {
        switch self {
        case let .invalidValue(name, value):
            return "\(name) has invalid value: \(value)"
        }
    }
}

private enum SoakVerificationError: LocalizedError {
    case unexpectedResultCount(expected: Int, actual: Int, details: String)
    case failedOperationResults(String)
    case sourceChanged
    case assertionFailure
    case hashMismatch(relativePath: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedResultCount(expected, actual, details):
            return "Expected \(expected) soak results, received \(actual): \(details)"
        case let .failedOperationResults(details):
            return "Soak operation contained failed results: \(details)"
        case .sourceChanged:
            return "Source inventory or SHA-256 contents changed"
        case .assertionFailure:
            return "Soak assertions or final iteration coverage failed"
        case let .hashMismatch(relativePath, expected, actual):
            return "SHA-256 mismatch for \(relativePath): expected \(expected), received \(actual)"
        }
    }
}

private func relativeManifestPath(for result: FileOperationResult, source: URL) throws -> String {
    let prefix = source.path + "/"
    guard result.sourceURL.path.hasPrefix(prefix) else {
        throw SoakConfigurationError.invalidValue(name: "result source path", value: result.sourceURL.path)
    }
    return String(result.sourceURL.path.dropFirst(prefix.count))
}

private func writeSoakSummary(_ summary: SoakSummary, to resultURL: URL) throws {
    let parent = resultURL.deletingLastPathComponent().standardizedFileURL
    let marker = parent.appendingPathComponent(".bitmatch-disposable-fixture")
    guard FileManager.default.fileExists(atPath: marker.path) else {
        throw SoakConfigurationError.invalidValue(
            name: "BITMATCH_SOAK_RESULT parent (missing .bitmatch-disposable-fixture)",
            value: parent.path
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(summary).write(to: resultURL, options: .atomic)
}

private func soakCanonicalFileURL(_ url: URL) -> URL {
    // Use the engine's canonicalization: realpath expands /var to
    // /private/var, which does not match the engine-issued result paths.
    url.standardizedFileURL.resolvingSymlinksKeepingCase()
}

private func describeSoakResults(_ results: [FileOperationResult]) -> String {
    results.map {
        "src=\($0.sourceURL.path), dst=\($0.destinationURL.path), success=\($0.success), status=\($0.statusDescription)"
    }.joined(separator: " | ")
}

/// Read the actual source inventory before and after, without checksum-cache reuse.
private func verifySoakSource(_ source: URL, expected: [String: String]) throws -> Int {
    let directories = Set(try CardSource.enumerateTree(base: source).filter { $0.kind == .directory }.map(\.relativePath))
    guard directories == ["DCIM", "DCIM/100MEDIA", "EMPTY_SIDECARS"] else { throw SoakVerificationError.sourceChanged }
    let files = try CardSource.enumerateRegularFiles(base: source)
    guard Set(files.map(\.relativePath)) == Set(expected.keys) else { throw SoakVerificationError.sourceChanged }
    for file in files {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let count = try autoreleasepool {
                let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
                hasher.update(data: data)
                return data.count
            }
            if count == 0 { break }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected[file.relativePath] else { throw SoakVerificationError.sourceChanged }
    }
    return files.count
}
