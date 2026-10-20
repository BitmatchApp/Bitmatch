@preconcurrency import AVFoundation
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import PDFKit
import XCTest
@testable import BitMatch
import BitMatchEngine

/// Opt-in app-level evidence checks over the real mounted image pool used by
/// test-full-transfer-matrix.sh. No completed record or successful row is seeded.
/// The runner unmounts the owned images before deleting these unique case folders.
@MainActor
final class MountedWorkflowEvidenceMatrixTests: XCTestCase {
    private let filesystems = ["apfs", "hfs", "exfat", "apfsx", "fat"]

    func testQueuedPoliciesPersistThroughReportsHistoryAndMasterReport() async throws {
        let pool = try ownedPool()
        let run = UUID().uuidString
        let source = pool.appendingPathComponent("source-apfs/Workflow Evidence Card-\(run)")
        try await seed(source)
        let original = try hashes(source)
        var completed = 0
        var metadataRefusals = 0
        for (index, filesystem) in filesystems.enumerated() {
            for ignore in [false, true] {
                let key = "evidence-\(filesystem)-ignore-\(ignore)-\(run)"
                let destinationFilesystems = [filesystem, filesystems[(index + 1) % filesystems.count]]
                let destinations = destinationFilesystems.map {
                    pool.appendingPathComponent("destination-\($0)/\(key)")
                }
                for destination in destinations { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
                let suite = "BitMatchMountedEvidence.\(UUID())"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                // A queued policy must survive a conflicting current preference.
                defaults.set(!ignore, forKey: "BitMatchExcludeAppleDouble")
                let journalURL = pool.appendingPathComponent("\(key)-history.json")
                let journal = LocalTransferJournal(fileURL: journalURL)
                var settings = CameraLabelSettings(label: "A Cam café", position: .suffix, separator: .dash, groupByCamera: true)
                if ignore { settings.excludedAppleDoublePaths = try AppleDoubleSelection.review(source: source) }
                var prefs = ReportPrefs(notes: "Take 2, \"good\"\nKeep all sidecars", operatorName: "Alex & Sam")
                prefs.includeThumbnails = true
                let mode = [VerificationMode.standard, .thorough, .paranoid][index % 3]
                let id = try journal.enqueue(sourceURL: source, destinationURLs: destinations,
                    verificationMode: mode, cameraSettings: settings, reportSettings: prefs, generateASCMHL: true)
                let operations = MountedEvidenceOperations()
                let coordinator = SharedAppCoordinator(platformManager: MountedEvidencePlatformManager(fileOperations: operations),
                    transferJournal: journal, defaults: defaults)
                coordinator.startQueue()
                let ended = await waitUntil(timeout: .seconds(45)) {
                    !coordinator.queueIsRunning && !coordinator.isOperationInProgress
                }
                if !ended { coordinator.cancelOperation() }
                XCTAssertTrue(ended, key)
                // Decode the saved bytes without opening a second exclusive journal owner.
                let savedRecords = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: journalURL))
                let record = try XCTUnwrap(savedRecords.first { $0.id == id })
                let failedRows = record.results.filter { !$0.isVerifiedStatus && ResultOutcome(statusText: $0.status) != .excludedAppleDouble }
                let competingBytes = await operations.witnesses.snapshots
                for row in failedRows {
                    XCTAssertFalse(ignore, "An excluded source metadata file must not be attempted")
                    XCTAssertEqual(URL(fileURLWithPath: row.path).lastPathComponent, "._clip.mov", row.status)
                    let path = try XCTUnwrap(row.destinationPath)
                    XCTAssertTrue(path.contains("/destination-fat/") || path.contains("/destination-exfat/"), row.status)
                    let refusal = try XCTUnwrap(competingBytes[path])
                    XCTAssertEqual(refusal.code, NSFileWriteFileExistsError)
                    XCTAssertEqual(refusal.domain, "DestinationWriter")
                    XCTAssertEqual(ResultOutcome(statusText: row.status), .failed)
                    XCTAssertEqual(try digestFile(URL(fileURLWithPath: path)), refusal.sha256, "Competing metadata changed after refusal")
                }
                metadataRefusals += failedRows.count
                let wholeCardPassed = !ignore && failedRows.isEmpty
                XCTAssertEqual(record.state, wholeCardPassed ? .completed : .issues, "\(key): \(record.summary)")
                XCTAssertEqual(record.results.count, original.count * 2, key)
                let selectedCount = original.count - (ignore ? 1 : 0)
                XCTAssertEqual(record.plannedFileCounts, [selectedCount, selectedCount], key)
                XCTAssertEqual(record.results.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }.count, ignore ? 2 : 0, key)
                XCTAssertEqual(record.results.filter(\.isVerifiedStatus).count, (original.count - (ignore ? 1 : 0)) * 2 - failedRows.count, key)
                XCTAssertEqual(TransferLibraryPresentation.safetyState(for: record) == .safeToErase, wholeCardPassed, key)
                XCTAssertEqual(try hashes(source), original, "Source changed: \(key)")
                for (backup, destination) in destinations.enumerated() {
                    let output = try SafetyValidator.resolvedDestinationRootChecked(source: source, destination: destination, settings: settings)
                    XCTAssertTrue(PathContainment.isWithin(output.path, root: destination.path), key)
                    let backupFailed = failedRows.contains { row in
                        row.destinationPath.map { PathContainment.isWithin($0, root: output.path) } == true
                    }
                    for (relative, digest) in original {
                        let path = output.appendingPathComponent(relative)
                        if relative == "._clip.mov" && (ignore || backupFailed) {
                            // Ignoring source metadata does not suppress metadata created by
                            // macOS itself. Preserve a competing companion instead of replacing it.
                            if FileManager.default.fileExists(atPath: path.path) {
                                XCTAssertTrue(try AppleDoubleSelection.review(source: output).contains(relative), key)
                                if !ignore { XCTAssertNotEqual(try digestFile(path), digest, key) }
                            }
                        } else { XCTAssertEqual(try digestFile(path), digest, "\(key) \(relative)") }
                    }
                    XCTAssertEqual(FileManager.default.fileExists(atPath: output.appendingPathComponent("ascmhl/ascmhl_chain.xml").path), !backupFailed, "\(key) backup=\(backup) fs=\(destinationFilesystems[backup])")
                }
                let persisted = try JSONDecoder().decode([LocalTransferRecord].self, from: Data(contentsOf: journalURL))
                XCTAssertEqual(persisted.first?.state, record.state, key)
                XCTAssertEqual(persisted.first?.results.count, record.results.count, key)
                let historyJSON = try TransferHistoryDocument(record: record, asCSV: false).data
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: historyJSON) as? [String: Any])
                XCTAssertEqual(object["savedSafeToErase"] as? Bool, wholeCardPassed, key)
                XCTAssertEqual(object["operatorName"] as? String, "Alex & Sam", key)
                XCTAssertEqual(object["notes"] as? String, prefs.notes, key)
                XCTAssertEqual((object["results"] as? [[String: Any]])?.count, record.results.count, key)
                XCTAssertNil(object["bookmark"], key)
                let csv = String(decoding: try TransferHistoryDocument(record: record, asCSV: true).data, as: UTF8.self)
                XCTAssertTrue(csv.contains("Alex & Sam"), key)
                XCTAssertTrue(csv.contains("\"\"good\"\""), key)
                XCTAssertTrue(csv.contains("savedSafeToErase"), key)
                let historyPDF = try await ReportExporter.historyPDF(record: record, includeThumbnails: true)
                let historyText = try pdfText(historyPDF)
                XCTAssertTrue(historyText.contains("Regenerated from saved history"), key)
                XCTAssertTrue(historyText.contains("Operator: Alex & Sam"), key)
                let previewCandidates = 2 // Real movie plus the corrupt movie; metadata is not a clip preview.
                XCTAssertTrue(historyText.contains("Clip previews: 1/\(previewCandidates)"), "\(key): \(historyText)")
                let reports = try FileManager.default.contentsOfDirectory(at: destinations[0].appendingPathComponent("Reports"), includingPropertiesForKeys: nil)
                let pdf = try XCTUnwrap(reports.first { $0.pathExtension == "pdf" })
                let automaticText = try pdfText(Data(contentsOf: pdf))
                XCTAssertTrue(automaticText.contains("Operator: Alex & Sam"), key)
                XCTAssertTrue(automaticText.contains("Clip previews: 1/\(previewCandidates)"), key)
                XCTAssertEqual(automaticText.contains("intentionally excluded"), ignore, key)
                let json = try XCTUnwrap(reports.first { $0.pathExtension == "json" })
                let automaticJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
                XCTAssertEqual(automaticJSON["safeToErase"] as? Bool, wholeCardPassed, key)
                let scan = await ReportScanner.scanReports(at: destinations[0])
                XCTAssertTrue(scan.skipped.isEmpty, key)
                XCTAssertEqual(scan.cards.count, 1, key)
                let master = try await SharedReportGenerationService().generateMasterReport(transfers: scan.cards, configuration: .default())
                XCTAssertEqual(master.reportData.summary.totalTransfers, 1, key)
                XCTAssertEqual(master.reportData.summary.totalFiles, original.count, key)
                let masterText = try pdfText(master.pdfData)
                XCTAssertTrue(masterText.contains("MASTER TRANSFER REPORT"), key)
                XCTAssertFalse(masterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
                if completed < 2, let artifacts = ProcessInfo.processInfo.environment["BITMATCH_MATRIX_ARTIFACTS"] {
                    let folder = URL(fileURLWithPath: artifacts)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let label = ignore ? "selected" : "complete"
                    try Data(contentsOf: pdf).write(to: folder.appendingPathComponent("\(label)-automatic-with-preview.pdf"))
                    try historyPDF.write(to: folder.appendingPathComponent("\(label)-saved-history-with-preview.pdf"))
                    try master.pdfData.write(to: folder.appendingPathComponent("\(label)-master.pdf"))
                }
                completed += 1
                print("MOUNTED_WORKFLOW_CASE \(key) mode=\(mode.rawValue) files=\(original.count) backups=2 preview=1/\(previewCandidates) metadataRefusals=\(failedRows.count) history=real")
            }
        }
        XCTAssertEqual(completed, 10)
        print("MOUNTED_WORKFLOW_SUMMARY cases=\(completed) transfers=\(completed) historyExports=30 automaticReports=10 masterReports=10 previews=20 metadataRefusals=\(metadataRefusals)")
    }

    func testCancelBeforeMHLAndRetryRetainsBothAttemptsAndExistingHistories() async throws {
        let pool = try ownedPool()
        let run = UUID().uuidString
        let source = pool.appendingPathComponent("source-apfs/Cancel Retry Card-\(run)")
        try await seed(source)
        try FileManager.default.removeItem(at: source.appendingPathComponent("._clip.mov"))
        let original = try hashes(source)
        var completed = 0
        for filesystem in filesystems {
            let destination = pool.appendingPathComponent("destination-\(filesystem)/cancel-retry-\(run)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let suite = "BitMatchMountedCancel.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let journal = LocalTransferJournal(fileURL: pool.appendingPathComponent("cancel-\(filesystem)-\(run)-history.json"))
            let id = try journal.enqueue(sourceURL: source, destinationURLs: [destination], verificationMode: .standard,
                cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs(), generateASCMHL: true)
            let operations = MountedBeforeHandoffGate()
            let coordinator = SharedAppCoordinator(platformManager: MountedEvidencePlatformManager(fileOperations: operations), transferJournal: journal, defaults: defaults)
            coordinator.startQueue()
            let reached = await waitUntil(timeout: .seconds(30)) { await operations.gate.reached }
            XCTAssertTrue(reached, filesystem)
            coordinator.cancelOperation()
            let ended = await waitUntil(timeout: .seconds(10)) { !coordinator.isOperationInProgress }
            XCTAssertTrue(ended, filesystem)
            let cancelled = try XCTUnwrap(journal.records.first { $0.id == id })
            XCTAssertEqual(cancelled.state, .cancelled, filesystem)
            XCTAssertEqual(cancelled.results.count, original.count, filesystem)
            XCTAssertNotEqual(TransferLibraryPresentation.safetyState(for: cancelled), .safeToErase, filesystem)
            let cancelledJSON = try TransferHistoryDocument(record: cancelled, asCSV: false).data
            let cancelledObject = try XCTUnwrap(JSONSerialization.jsonObject(with: cancelledJSON) as? [String: Any])
            XCTAssertEqual(cancelledObject["savedSafeToErase"] as? Bool, false, filesystem)
            let cancelledPDF = try await ReportExporter.historyPDF(record: cancelled, includeThumbnails: false)
            XCTAssertTrue(try pdfText(cancelledPDF).contains("NOT SAFE TO ERASE"), filesystem)
            if filesystem == "apfs", let artifacts = ProcessInfo.processInfo.environment["BITMATCH_MATRIX_ARTIFACTS"] {
                let folder = URL(fileURLWithPath: artifacts)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try cancelledPDF.write(to: folder.appendingPathComponent("cancelled-saved-history.pdf"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Reports").path), filesystem)
            let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: CameraLabelSettings())
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("ascmhl").path), filesystem)
            let live = SharedAppCoordinator(platformManager: MountedEvidencePlatformManager(fileOperations: TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)), transferJournal: journal, defaults: defaults)
            live.retryTransfer(id)
            let retry = try XCTUnwrap(journal.records.first { $0.retryOf == id }?.id)
            let settled = await waitUntil(timeout: .seconds(40)) { !live.queueIsRunning && !live.isOperationInProgress }
            XCTAssertTrue(settled, filesystem)
            let finished = try XCTUnwrap(journal.records.first { $0.id == retry })
            XCTAssertEqual(finished.state, .completed, "\(filesystem): \(finished.summary)")
            XCTAssertEqual(finished.retryOf, id, filesystem)
            XCTAssertEqual(finished.results.count, original.count, filesystem)
            XCTAssertTrue(finished.results.allSatisfy { $0.isVerifiedStatus && $0.wasReused }, filesystem)
            let originalAttempt = try XCTUnwrap(journal.records.first { $0.id == id })
            XCTAssertEqual(originalAttempt.state, cancelled.state, "Retry changed original evidence")
            XCTAssertEqual(originalAttempt.summary, cancelled.summary)
            XCTAssertEqual(originalAttempt.results.map(\.id), cancelled.results.map(\.id))
            XCTAssertEqual(originalAttempt.endedAt, cancelled.endedAt)
            let history = try hashes(output.appendingPathComponent("ascmhl"))
            XCTAssertFalse(history.isEmpty, filesystem)
            // Requesting MHL again must refuse an existing history, preserve its
            // bytes and keep the overall verdict amber despite verified media.
            let repeatedID = try live.enqueue(source: source, destinations: [destination], verificationMode: .standard,
                cameraSettings: CameraLabelSettings(), generateASCMHL: true, reportSettings: ReportPrefs())
            live.startQueue()
            let repeatedSettled = await waitUntil(timeout: .seconds(40)) { !live.queueIsRunning && !live.isOperationInProgress }
            XCTAssertTrue(repeatedSettled, filesystem)
            let repeated = try XCTUnwrap(journal.records.first { $0.id == repeatedID })
            XCTAssertEqual(repeated.state, .issues, repeated.summary)
            XCTAssertTrue(repeated.results.allSatisfy { $0.isVerifiedStatus && $0.wasReused }, filesystem)
            XCTAssertNotEqual(TransferLibraryPresentation.safetyState(for: repeated), .safeToErase, filesystem)
            XCTAssertTrue(repeated.summary.contains("ASC MHL"), repeated.summary)
            XCTAssertEqual(try hashes(output.appendingPathComponent("ascmhl")), history, filesystem)
            XCTAssertEqual(try hashes(source), original, filesystem)
            completed += 1
            print("MOUNTED_CANCEL_RETRY_CASE \(filesystem) original=cancelled retry=verified reused=\(finished.results.count) existingMHLRequest=issues historyPreserved=true")
        }
        XCTAssertEqual(completed, 5)
        print("MOUNTED_CANCEL_RETRY_SUMMARY filesystems=\(completed) transfers=15")
    }

    func testMountedOverlapConfigurationRejectedWithoutWrites() async throws {
        let pool = try ownedPool()
        var refused = 0
        for filesystem in filesystems {
            let source = pool.appendingPathComponent("source-\(filesystem)/Invalid Overlap Card-\(UUID())")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("Source must stay unchanged".utf8).write(to: source.appendingPathComponent("clip.bin"))
            let original = try hashes(source)
            let suite = "BitMatchMountedInvalid.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let journal = LocalTransferJournal(fileURL: pool.appendingPathComponent("invalid-\(filesystem).json"))
            let coordinator = SharedAppCoordinator(platformManager: MountedEvidencePlatformManager(fileOperations: TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)), transferJournal: journal, defaults: defaults)
            XCTAssertThrowsError(try coordinator.enqueue(source: source, destinations: [source]))
            XCTAssertTrue(journal.records.isEmpty, filesystem)
            XCTAssertEqual(try hashes(source), original, filesystem)
            refused += 1
        }
        XCTAssertEqual(refused, 5)
        print("MOUNTED_INVALID_CONFIG_SUMMARY refused=\(refused) destinationWrites=0")
    }

    private func ownedPool() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["BITMATCH_MATRIX_ROOT"] else { throw XCTSkip("Run MATRIX_FOCUS=evidence Scripts/test-full-transfer-matrix.sh") }
        let root = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".bitmatch-matrix-owned").path) else { throw NSError(domain: "MountedWorkflowOwnership", code: 1) }
        var devices = Set<dev_t>()
        for role in ["source", "destination"] {
            for (name, expected) in [("apfs", "apfs"), ("hfs", "hfs"), ("exfat", "exfat"), ("apfsx", "apfs"), ("fat", "msdos")] {
                let mount = root.appendingPathComponent("\(role)-\(name)")
                var filesystem = statfs()
                guard statfs(mount.path, &filesystem) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let actual = withUnsafeBytes(of: filesystem.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                XCTAssertEqual(actual, expected)
                var identity = stat()
                guard stat(mount.path, &identity) == 0, devices.insert(identity.st_dev).inserted else { throw NSError(domain: "MountedWorkflowSeparateImages", code: 1) }
            }
        }
        return root
    }

    private func seed(_ source: URL) async throws {
        try FileManager.default.createDirectory(at: source.appendingPathComponent("DCIM/Sidecars"), withIntermediateDirectories: true)
        try Data(repeating: 0x47, count: 1024 * 1024).write(to: source.appendingPathComponent("DCIM/clip.bin"))
        try Data("<clip>日本語 café</clip>".utf8).write(to: source.appendingPathComponent("DCIM/Sidecars/clip.xml"))
        try Data().write(to: source.appendingPathComponent("empty.raw"))
        try Data("legitimate filename, not AppleDouble".utf8).write(to: source.appendingPathComponent("._notes.txt"))
        try Data("camera metadata".utf8).write(to: source.appendingPathComponent(".camera-metadata"))
        try Data("not a playable movie".utf8).write(to: source.appendingPathComponent("broken.mov"))
        var bytes = [UInt8](repeating: 0, count: 42)
        func put(_ value: UInt32, _ offset: Int) { for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) } }
        put(0x00051607, 0); put(0x00020000, 4); bytes[25] = 1
        put(2, 26); put(38, 30); put(4, 34)
        try Data(bytes).write(to: source.appendingPathComponent("._clip.mov"))
        try await makeMovie(source.appendingPathComponent("clip.mov"))
    }

    private func makeMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<2 {
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            let pixels = address.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                for x in 0..<64 {
                    let offset = y * stride + x * 4
                    pixels[offset] = 255
                    pixels[offset + 1] = x < 32 ? 224 : 32
                    pixels[offset + 2] = y < 32 ? 224 : 32
                    pixels[offset + 3] = index == 0 ? 64 : 192
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let ready = await waitUntil(timeout: .seconds(10)) { input.isReadyForMoreMediaData }
            XCTAssertTrue(ready)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, String(describing: writer.error))
    }

    private func hashes(_ root: URL) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: CardSource.enumerateRegularFiles(base: root).map { ($0.relativePath, try digestFile($0.url)) })
    }
    private func digestFile(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
    private func pdfText(_ data: Data) throws -> String {
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 0)
        return try XCTUnwrap(document.string)
    }
}

private actor MountedHandoffGate {
    private(set) var reached = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var cancelled = false
    func hold() async throws {
        reached = true
        if !cancelled { await withCheckedContinuation { waiter = $0 } }
        throw CancellationError()
    }
    func cancel() { cancelled = true; waiter?.resume(); waiter = nil }
}

/// The real copy+verification completes, then the test holds the handoff until an
/// explicit coordinator cancellation. No operation results or digest are faked.
private final class MountedBeforeHandoffGate: FileOperationsService, @unchecked Sendable {
    let gate = MountedHandoffGate()
    private let pipeline = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode, settings: CameraLabelSettings,
                              estimatedTotalBytes: Int64?, progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?) async throws -> FileOperation {
        _ = try await pipeline.performFileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs, verificationMode: verificationMode,
            settings: settings, estimatedTotalBytes: estimatedTotalBytes, progressCallback: progressCallback, onFileResult: onFileResult)
        try await gate.hold()
        throw CancellationError()
    }
    func cancelOperation() { pipeline.cancelOperation(); Task { await gate.cancel() } }
    func pauseOperation() async { await pipeline.pauseOperation() }
    func resumeOperation() async { await pipeline.resumeOperation() }
}

/// Real macOS services and pipeline, without a modal error dialog in a test.
private final class MountedEvidencePlatformManager: PlatformManager {
    private let real = MacOSPlatformManager.shared
    nonisolated let fileOperations: FileOperationsService
    init(fileOperations: FileOperationsService) { self.fileOperations = fileOperations }
    nonisolated var fileSystem: FileSystemService { real.fileSystem }
    nonisolated var checksum: ChecksumService { real.checksum }
    nonisolated var cameraDetection: CameraDetectionService { real.cameraDetection }
    nonisolated var supportsDragAndDrop: Bool { real.supportsDragAndDrop }
    func presentAlert(title: String, message: String) async {}
    func presentError(_ error: Error) async {}
    func openURL(_ url: URL) async -> Bool { false }
}

private struct MountedMetadataRefusal: Sendable {
    let domain: String
    let code: Int
    let sha256: String
}

private actor MountedMetadataWitnesses {
    private(set) var snapshots: [String: MountedMetadataRefusal] = [:]
    func record(_ result: FileOperationResult) throws {
        guard !result.success, result.sourceURL.lastPathComponent == "._clip.mov" else { return }
        let data = try Data(contentsOf: result.destinationURL)
        let error = result.error as NSError?
        snapshots[result.destinationURL.path] = MountedMetadataRefusal(domain: error?.domain ?? "missing", code: error?.code ?? 0,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

/// Retains competing bytes at the actual refusal, before MHL/report work, then
/// forwards every unmodified engine result to the real coordinator.
private final class MountedEvidenceOperations: FileOperationsService, @unchecked Sendable {
    let witnesses = MountedMetadataWitnesses()
    private let pipeline = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
    func performFileOperation(sourceURL: URL, destinationURLs: [URL], verificationMode: VerificationMode, settings: CameraLabelSettings,
                              estimatedTotalBytes: Int64?, progressCallback: @escaping ProgressCallback, onFileResult: FileResultCallback?) async throws -> FileOperation {
        let witnesses = self.witnesses
        return try await pipeline.performFileOperation(sourceURL: sourceURL, destinationURLs: destinationURLs,
            verificationMode: verificationMode, settings: settings, estimatedTotalBytes: estimatedTotalBytes,
            progressCallback: progressCallback, onFileResult: { result in
                try? await witnesses.record(result)
                await onFileResult?(result)
            })
    }
    func cancelOperation() { pipeline.cancelOperation() }
    func pauseOperation() async { await pipeline.pauseOperation() }
    func resumeOperation() async { await pipeline.resumeOperation() }
}
