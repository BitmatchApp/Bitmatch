import CryptoKit
import Foundation
import Testing
@testable import BitMatchEngine

/// Reuse of an existing destination file must use the same checks as copy
/// verification: Paranoid is byte-by-byte plus SHA-256 (docs/THESIS.md,
/// Decisions), Thorough is SHA-256 plus MD5.
struct ExistingDestinationReuseTests {

    /// Source and destination differ in bytes but not in size, and the
    /// injected checksum service reports the destination's digest for the
    /// source. That stands in for a SHA-256 collision, which cannot be built
    /// for real. Only the byte comparison can catch it.
    @Test
    func paranoidReuseRejectsDifferingBytesEvenWhenChecksumsAgree() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let sourceContents = Data(repeating: 0x53, count: 4099)
            var destinationContents = sourceContents
            destinationContents[2048] = 0x44
            let fixture = try ReuseFixture(source: sourceContents, destination: destinationContents)
            defer { fixture.remove() }

            let checksums = RecordingChecksumService(reportDigestsOf: destinationContents)
            let outcome = try await fixture.copy(verificationMode: .paranoid, checksumService: checksums)

            #expect(!outcome.reused)
            #expect(!outcome.errors.isEmpty)
            #expect(try Data(contentsOf: fixture.existingDestinationFile) == destinationContents)
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func paranoidReuseAcceptsIdenticalFileUsingSHA256Only() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let contents = Data((0..<4099).map { UInt8($0 % 251) })
            let fixture = try ReuseFixture(source: contents, destination: contents)
            defer { fixture.remove() }

            let checksums = RecordingChecksumService(reportDigestsOf: contents)
            let outcome = try await fixture.copy(verificationMode: .paranoid, checksumService: checksums)

            #expect(outcome.reused)
            #expect(outcome.errors.isEmpty)
            #expect(checksums.requestedTypes == [.sha256])
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func thoroughReuseAcceptsIdenticalFileUsingSHA256AndMD5() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let contents = Data((0..<4099).map { UInt8($0 % 251) })
            let fixture = try ReuseFixture(source: contents, destination: contents)
            defer { fixture.remove() }

            let checksums = RecordingChecksumService(reportDigestsOf: contents)
            let outcome = try await fixture.copy(verificationMode: .thorough, checksumService: checksums)

            #expect(outcome.reused)
            #expect(outcome.errors.isEmpty)
            #expect(checksums.requestedTypes == [.sha256, .md5])
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func reuseReadsDestinationOnceForChecksumsAndKeepsParanoidComparison() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            for (mode, expectedPasses) in [(VerificationMode.standard, 1), (.thorough, 1), (.paranoid, 2)] {
                let contents = Data((0..<4099).map { UInt8($0 % 251) })
                let fixture = try ReuseFixture(source: contents, destination: contents)
                defer { fixture.remove() }
                let probe = ReuseReadProbe()
                let outcome = try await fixture.copy(
                    verificationMode: mode,
                    checksumService: RecordingChecksumService(reportDigestsOf: contents),
                    hooks: .init(destinationDidOpenForRead: { _, _ in probe.didOpen() })
                )
                #expect(outcome.reused)
                #expect(probe.opens == expectedPasses)
            }
            #else
            #expect(true)
            #endif
        }
    }

    @Test
    func thoroughReuseRejectsMismatchInSecondDigestAfterOneDestinationPass() async throws {
        try await FileOperationsTestLock.shared.run {
            #if os(macOS)
            let contents = Data((0..<4099).map { UInt8($0 % 251) })
            let fixture = try ReuseFixture(source: contents, destination: contents)
            defer { fixture.remove() }
            let probe = ReuseReadProbe()
            let outcome = try await fixture.copy(
                verificationMode: .thorough,
                checksumService: RecordingChecksumService(reportDigestsOf: contents, corruptMD5: true),
                hooks: .init(destinationDidOpenForRead: { _, _ in probe.didOpen() })
            )
            #expect(!outcome.reused)
            #expect(!outcome.errors.isEmpty)
            #expect(probe.opens == 1)
            #else
            #expect(true)
            #endif
        }
    }
}

#if os(macOS)
private struct ReuseFixture {
    let root: URL
    let source: URL
    let destination: URL
    let existingDestinationFile: URL
    static let relativePath = "DCIM/clip.bin"

    init(source sourceContents: Data, destination destinationContents: Data) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("bitmatch_reuse_\(UUID().uuidString)")
        source = root.appendingPathComponent("Source")
        destination = root.appendingPathComponent("Destination")
        existingDestinationFile = destination.appendingPathComponent("Card-001/\(Self.relativePath)")
        try fm.createDirectory(at: source.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        try fm.createDirectory(at: existingDestinationFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sourceContents.write(to: source.appendingPathComponent(Self.relativePath))
        try destinationContents.write(to: existingDestinationFile)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func copy(
        verificationMode: VerificationMode,
        checksumService: any ChecksumService,
        hooks: DestinationWriter.FanOutHooks? = nil
    ) async throws -> (reused: Bool, errors: [String]) {
        let pinnedRoot = try PinnedDestinationDirectory.open(destination: destination, rootComponents: ["Card-001"])
        let events = ReuseEventCollector()
        try await DestinationWriter.copyAllSafelyFanOut(
            from: source,
            toPinnedRoots: [.init(index: 0, root: pinnedRoot)],
            verificationMode: verificationMode,
            workers: 1,
            checksumService: checksumService,
            preEnumeratedFiles: try CardSource.enumerateRegularFiles(base: source).map(\.url),
            hooks: hooks,
            onProgress: { _, _, _ in await events.recordProgress() },
            onError: { _, _, error in await events.recordError(error.localizedDescription) }
        )
        let progressCount = await events.progressCount
        let errors = await events.errors
        return (progressCount > 0, errors)
    }
}

private final class ReuseReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var opens: Int { lock.withLock { count } }
    func didOpen() { lock.withLock { count += 1 } }
}
#endif

private actor ReuseEventCollector {
    private(set) var progressCount = 0
    private(set) var errors: [String] = []

    func recordProgress() { progressCount += 1 }
    func recordError(_ message: String) { errors.append(message) }
}

/// Records which algorithms the source side is hashed with, and answers
/// with the digest of `reportedContents` instead of reading the file.
private final class RecordingChecksumService: ChecksumService, @unchecked Sendable {
    private let reportedContents: Data
    private let corruptMD5: Bool
    private let lock = NSLock()
    private var types: [ChecksumAlgorithm] = []

    init(reportDigestsOf contents: Data, corruptMD5: Bool = false) {
        reportedContents = contents
        self.corruptMD5 = corruptMD5
    }

    var requestedTypes: [ChecksumAlgorithm] {
        lock.lock()
        defer { lock.unlock() }
        return types
    }

    func generateChecksum(
        for fileURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> String {
        lock.withLock { types.append(type) }
        if type == .md5, corruptMD5 { return String(repeating: "0", count: 32) }
        return Self.hex(of: reportedContents, type: type)
    }

    func verifyFileIntegrity(
        sourceURL: URL,
        destinationURL: URL,
        type: ChecksumAlgorithm,
        progressCallback: ProgressCallback?
    ) async throws -> VerificationResult {
        Issue.record("Reuse must not verify through destination URLs")
        throw CancellationError()
    }

    func performByteComparison(
        sourceURL: URL,
        destinationURL: URL,
        progressCallback: ProgressCallback?
    ) async throws -> Bool {
        Issue.record("Reuse must byte-compare through the pinned destination handle")
        throw CancellationError()
    }

    private static func hex(of data: Data, type: ChecksumAlgorithm) -> String {
        switch type {
        case .sha256: return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .md5: return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .sha1: return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
