#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

/// Real destination filesystems; failures are injected only into marked fixtures.
final class MountedFilesystemFaultTests: XCTestCase {
    private var source: URL!
    private var destination: URL!
    private var scratch: URL!
    private let original = Data(repeating: 0x47, count: 65536)

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_FAULT_MATRIX_MOUNT"],
              let expected = ProcessInfo.processInfo.environment["BITMATCH_FAULT_MATRIX_TYPE"] else {
            throw XCTSkip("Run Scripts/test-filesystem-fault-matrix.sh")
        }
        let mount = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: mount.appendingPathComponent(".bitmatch-fault-owned").path) else {
            throw NSError(domain: "FaultFixtureOwnership", code: 1)
        }
        var info = statfs()
        XCTAssertEqual(statfs(mount.path, &info), 0)
        let actual = withUnsafePointer(to: &info.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
        }
        XCTAssertEqual(actual, expected)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-real-fault-\(UUID())")
        source = scratch.appendingPathComponent("Card")
        destination = mount.appendingPathComponent("fault-\(UUID())")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try original.write(to: source.appendingPathComponent("clip.bin"))
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("sidecar.bin"))
    }

    override func tearDownWithError() throws {
        if let scratch { try FileManager.default.removeItem(at: scratch) }
        if let destination, FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }

    func testConflictingFilePreservedAcrossModes() async throws {
        for mode in VerificationMode.allCases {
            let root = try freshDestination(mode.rawValue)
            let copied = SafetyValidator.resolvedDestinationRoot(source: source, destination: root, settings: CameraLabelSettings())
            try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: true)
            let sentinel = Data(repeating: 0x99, count: original.count)
            let existing = copied.appendingPathComponent("clip.bin")
            try sentinel.write(to: existing)
            let op = try await run(root, mode: mode)
            XCTAssertTrue(op.results.contains { !$0.success }, "\(mode): conflict cannot be safe")
            XCTAssertEqual(try Data(contentsOf: existing), sentinel)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), original)
        }
    }

    func testDestinationRemovedAfterPreflightFailsClosedAcrossModes() async throws {
        for mode in VerificationMode.allCases {
            let root = try freshDestination(mode.rawValue)
            let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                destinationSetupHook: { try FileManager.default.removeItem(at: $0) })
            let op = try await run(root, mode: mode, service: service)
            XCTAssertEqual(op.results.count, 2)
            XCTAssertTrue(op.results.allSatisfy { !$0.success })
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), original)
        }
    }

    func testDestinationReplacedByFileAfterPreflightFailsClosedAcrossModes() async throws {
        for mode in VerificationMode.allCases {
            let root = try freshDestination(mode.rawValue)
            let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                destinationSetupHook: { url in
                    try FileManager.default.removeItem(at: url)
                    try Data("do not overwrite".utf8).write(to: url)
                })
            let op = try await run(root, mode: mode, service: service)
            XCTAssertTrue(op.results.allSatisfy { !$0.success })
            XCTAssertEqual(try Data(contentsOf: root), Data("do not overwrite".utf8))
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), original)
        }
    }

    func testOneRemovedDestinationDoesNotInvalidateGoodCopiesAcrossModes() async throws {
        for mode in VerificationMode.allCases {
            let good = try freshDestination("good-" + mode.rawValue)
            let bad = try freshDestination("bad-" + mode.rawValue)
            let service = TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared,
                destinationSetupHook: { if $0.lastPathComponent.hasPrefix("bad-") { try FileManager.default.removeItem(at: $0) } })
            let op = try await service.performFileOperation(sourceURL: source, destinationURLs: [good, bad],
                verificationMode: mode, settings: CameraLabelSettings(), estimatedTotalBytes: nil,
                progressCallback: { _ in }, onFileResult: nil)
            XCTAssertEqual(op.results.count, 4)
            XCTAssertEqual(op.results.filter(\.success).count, 2)
            XCTAssertEqual(op.results.filter { !$0.success }.count, 2)
            let copied = SafetyValidator.resolvedDestinationRoot(source: source, destination: good, settings: CameraLabelSettings())
            XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("clip.bin")), original)
        }
    }

    func testPreCancelledTransferThrowsAcrossModes() async throws {
        for mode in VerificationMode.allCases {
            let root = try freshDestination(mode.rawValue)
            let card = source!
            let task = Task.detached {
                while !Task.isCancelled { await Task.yield() }
                return try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                    .performFileOperation(sourceURL: card, destinationURLs: [root], verificationMode: mode,
                        settings: CameraLabelSettings(), estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            }
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled transfer returned success") }
            catch is CancellationError { }
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), original)
        }
    }

    func testExistingIncompleteMHLNeverOverwritten() throws {
        let media = destination.appendingPathComponent("clip.bin")
        try original.write(to: media)
        let history = destination.appendingPathComponent("ascmhl")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let sentinel = history.appendingPathComponent("incomplete.txt")
        try Data("preserve history".utf8).write(to: sentinel)
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: destination,
            files: [verifiedFile()], startTime: Date(), toolVersion: "matrix"))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve history".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.appendingPathComponent("ascmhl_chain.xml").path))
    }

    func testTruncatedDestinationCannotPublishMHL() throws {
        try Data(original.prefix(100)).write(to: destination.appendingPathComponent("clip.bin"))
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: destination,
            files: [verifiedFile()], startTime: Date(), toolVersion: "matrix"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("ascmhl/ascmhl_chain.xml").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), original)
    }

    func testWriteFlushCloseAndPublishErrorsIsolateTheBadDestination() async throws {
        for mode in VerificationMode.allCases {
            for stage in ["write-full", "flush-io", "close-io", "publish-denied"] {
                let good = try freshDestination("good-\(mode.rawValue)-\(stage)")
                let bad = try freshDestination("bad-\(mode.rawValue)-\(stage)")
                var hooks = DestinationWriter.FanOutHooks()
                switch stage {
                case "write-full": hooks.beforeWrite = { index, _, _ in if index == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) } }
                case "flush-io": hooks.beforeFlush = { index, _ in if index == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) } }
                case "close-io": hooks.beforeClose = { index, _ in if index == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) } }
                default: hooks.beforePublish = { index, _ in if index == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) } }
                }
                let op = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks)
                    .performFileOperation(sourceURL: source, destinationURLs: [good, bad], verificationMode: mode,
                        settings: CameraLabelSettings(), estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
                XCTAssertEqual(op.results.count, 4, stage)
                XCTAssertEqual(op.results.filter(\.success).count, 2, stage)
                XCTAssertEqual(op.results.filter { !$0.success }.count, 2, stage)
                let copied = SafetyValidator.resolvedDestinationRoot(source: source, destination: good, settings: CameraLabelSettings())
                XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("clip.bin")), original)
                XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), original)
                try assertNoTemporaryFiles(bad)
            }
        }
    }

    func testVerificationReadErrorsNeverMakeTheBadDestinationVerified() async throws {
        for mode in [VerificationMode.standard, .thorough, .paranoid] {
            let good = try freshDestination("good-" + mode.rawValue)
            let bad = try freshDestination("bad-" + mode.rawValue)
            let hooks = DestinationWriter.FanOutHooks(beforeDestinationRead: { index, _ in
                if index == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            })
            let op = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks)
                .performFileOperation(sourceURL: source, destinationURLs: [good, bad], verificationMode: mode,
                    settings: CameraLabelSettings(), estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
            XCTAssertEqual(op.results.count, 4)
            XCTAssertEqual(op.results.filter(\.success).count, 2)
            XCTAssertEqual(op.results.filter { !$0.success }.count, 2)
            XCTAssertEqual(op.results.filter { $0.verificationResult?.isValid == true }.count, 2)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), original)
        }
    }

    func testCancellationDuringWriteOrVerificationPropagatesAndCleansTemps() async throws {
        for mode in VerificationMode.allCases {
            for stage in ["write", "verification"] where stage != "verification" || mode != .quick {
                let root = try freshDestination("\(mode.rawValue)-\(stage)")
                var hooks = DestinationWriter.FanOutHooks()
                if stage == "write" { hooks.beforeWrite = { _, _, _ in throw CancellationError() } }
                else { hooks.beforeDestinationRead = { _, _ in throw CancellationError() } }
                do {
                    _ = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared, fanOutHooks: hooks)
                        .performFileOperation(sourceURL: source, destinationURLs: [root], verificationMode: mode,
                            settings: CameraLabelSettings(), estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
                    XCTFail("Interrupted \(stage) returned an operation")
                } catch is CancellationError { }
                try assertNoTemporaryFiles(root)
                XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("clip.bin")), original)
            }
        }
    }

    private func assertNoTemporaryFiles(_ root: URL) throws {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return XCTFail("Unable to inspect fixture cleanup") }
        for case let url as URL in files {
            XCTAssertFalse(url.lastPathComponent.hasPrefix(".bitmatch.tmp."), "Leaked temporary file")
        }
    }

    func testManyTinyDeepTreeAndLargeFilePayloadsThroughMHL() async throws {
        for workload in ["many-tiny", "deep-tree", "large-file"] {
            let card = scratch.appendingPathComponent(workload)
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
            var expected: [String: String] = [:]
            let files: [(String, Data)]
            if workload == "many-tiny" {
                files = (0..<1000).map { ("file-\($0).bin", Data(repeating: UInt8(truncatingIfNeeded: $0), count: $0 % 65)) }
            } else if workload == "deep-tree" {
                files = (1...24).map { depth in
                    (Array(repeating: "Nested Folder", count: depth).joined(separator: "/") + "/日本語 café.bin", Data(repeating: UInt8(depth), count: 1024))
                }
            } else {
                files = [("large.bin", Data(repeating: 0x6A, count: 64 * 1024 * 1024)), ("empty.bin", Data())]
            }
            for (relative, bytes) in files {
                let url = card.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: url)
                expected[relative] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            for mode in [VerificationMode.standard, .paranoid] {
                let root = try freshDestination("\(workload)-\(mode.rawValue)")
                let operation = try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                    .performFileOperation(sourceURL: card, destinationURLs: [root], verificationMode: mode,
                        settings: CameraLabelSettings(), estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
                XCTAssertEqual(operation.results.count, expected.count, workload)
                XCTAssertTrue(operation.results.allSatisfy { $0.success && $0.verificationResult?.isValid == true }, workload)
                let plan = TransferCompletion.ascmhlPlan(results: operation.results, sourceFiles: operation.sourceManifest,
                    destinations: [root], source: card, settings: CameraLabelSettings())
                XCTAssertTrue(plan.issues.isEmpty)
                let issues = try TransferCompletion.writeASCMHL(plan.jobs, planIssues: plan.issues,
                    startTime: operation.startTime, source: card, toolVersion: "payload-matrix")
                XCTAssertTrue(issues.isEmpty, "\(workload): \(issues)")
                let copied = SafetyValidator.resolvedDestinationRoot(source: card, destination: root, settings: CameraLabelSettings())
                XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathComponent("ascmhl/ascmhl_chain.xml").path))
                for (relative, digest) in expected {
                    for base in [card, copied] {
                        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: base.appendingPathComponent(relative))).map { String(format: "%02x", $0) }.joined(), digest)
                    }
                }
                print("PAYLOAD_CASE \(workload) \(mode.rawValue) files=\(expected.count)")
            }
        }
    }

    private func verifiedFile() -> ASCMHLGenerator.VerifiedFile {
        .init(relativePath: "clip.bin", size: Int64(original.count),
            expectedSHA256: SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
    }

    private func freshDestination(_ name: String) throws -> URL {
        let url = destination.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ root: URL, mode: VerificationMode, service: TransferPipeline? = nil) async throws -> FileOperation {
        try await (service ?? TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared))
            .performFileOperation(sourceURL: source, destinationURLs: [root], verificationMode: mode,
                settings: CameraLabelSettings(), estimatedTotalBytes: nil, progressCallback: { _ in }, onFileResult: nil)
    }
}
#endif
