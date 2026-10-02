import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

final class TransferSoakTests: XCTestCase {
    func testSeededStandardTransferToTwoDestinations() async throws {
        guard ProcessInfo.processInfo.environment["BITMATCH_RUN_SOAK"] == "1" else {
            throw XCTSkip("Set BITMATCH_RUN_SOAK=1 to run the seeded transfer soak test")
        }

        let environment = ProcessInfo.processInfo.environment
        let seed = try parseUInt64(environment["BITMATCH_SOAK_SEED"], name: "BITMATCH_SOAK_SEED", default: 20_260_711)
        let iterations = try parsePositiveInt(
            environment["BITMATCH_SOAK_ITERATIONS"],
            name: "BITMATCH_SOAK_ITERATIONS",
            default: 25
        )
        var iterationSummaries: [SoakIterationSummary] = []

        try await FileOperationsTestLock.shared.run {
            for iteration in 0..<iterations {
                let iterationSeed = seed &+ UInt64(iteration)
                let fixture = try DisposableTransferFixture(
                    seed: iterationSeed,
                    fileCount: 8,
                    bytesPerFile: 256 * 1024
                )
                defer { fixture.cleanup() }
                let source = soakCanonicalFileURL(fixture.source)
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
                guard operation.results.allSatisfy(\.success) else {
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

                iterationSummaries.append(SoakIterationSummary(
                    iteration: iteration,
                    seed: iterationSeed,
                    manifestFiles: fixture.manifest.count,
                    verifiedOutputs: verifiedOutputs
                ))
            }
        }

        let summary = SoakSummary(
            formatVersion: 1,
            baseSeed: seed,
            requestedIterations: iterations,
            completedIterations: iterationSummaries.count,
            verificationMode: "standard",
            destinationsPerIteration: 2,
            iterations: iterationSummaries
        )
        if let resultPath = environment["BITMATCH_SOAK_RESULT"], !resultPath.isEmpty {
            try writeSoakSummary(summary, to: URL(fileURLWithPath: resultPath))
        }
    }
}

private struct SoakSummary: Codable {
    let formatVersion: Int
    let baseSeed: UInt64
    let requestedIterations: Int
    let completedIterations: Int
    let verificationMode: String
    let destinationsPerIteration: Int
    let iterations: [SoakIterationSummary]
}

private struct SoakIterationSummary: Codable {
    let iteration: Int
    let seed: UInt64
    let manifestFiles: Int
    let verifiedOutputs: Int
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
    case hashMismatch(relativePath: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedResultCount(expected, actual, details):
            return "Expected \(expected) soak results, received \(actual): \(details)"
        case let .failedOperationResults(details):
            return "Soak operation contained failed results: \(details)"
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
