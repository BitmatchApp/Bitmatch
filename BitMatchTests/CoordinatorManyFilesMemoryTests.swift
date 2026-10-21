#if os(macOS)
import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import PDFKit
import SwiftUI
import Synchronization
import XCTest
@testable import BitMatch
@testable import BitMatchEngine

/// Real coordinator, pipeline and observed SwiftUI views; host scratch only.
/// Row/history/PDF storage is O(N), not a constant-memory promise or #23 repro.
@MainActor
final class CoordinatorManyFilesMemoryTests: XCTestCase {
    func testMemoryGuardCancelsOwnedWork() async throws {
        let guardrail = ManyFilesMemory()
        XCTAssertTrue(guardrail.record(1_024))
        let worker = Task { try await Task.sleep(for: .seconds(60)) }
        let monitor = guardrail.monitor { worker.cancel() }
        do { try await worker.value; XCTFail("Guard did not cancel owned work") }
        catch { XCTAssertTrue(error is CancellationError) }
        monitor.cancel(); await monitor.value
        XCTAssertThrowsError(try guardrail.requireSafe())
    }

    func testMissingMemorySampleFailsClosed() {
        let guardrail = ManyFilesMemory()
        XCTAssertTrue(guardrail.record(nil))
        XCTAssertThrowsError(try guardrail.requireSafe())
    }

    func testActualCoordinatorManyFilesWithLiveViews() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BITMATCH_APP_MANY_FILES_MEMORY"] == "1" else {
            throw XCTSkip("Set BITMATCH_APP_MANY_FILES_MEMORY=1 for the guarded coordinator probe")
        }
        let count = Int(env["BITMATCH_APP_MANY_FILES_COUNT"] ?? "20000") ?? 0
        let reports = env["BITMATCH_APP_MANY_FILES_REPORTS"] ?? "off"
        let maxSeconds = Double(env["BITMATCH_APP_MANY_FILES_MAX_SECONDS"] ?? "600") ?? 0
        let mhlSetting = env["BITMATCH_APP_MANY_FILES_MHL"] ?? "1"
        guard (100...20000).contains(count), ["off", "both"].contains(reports),
              maxSeconds.isFinite, (60...1200).contains(maxSeconds), ["0", "1"].contains(mhlSetting) else { throw ManyFilesError.invalidFixture }
        let includeMHL = mhlSetting == "1"
        try FileHandle.standardOutput.write(contentsOf: Data("APP_MEMORY workerPID=\(getpid()) files=\(count) reports=\(reports) mhl=\(includeMHL)\n".utf8))
        let root = URL(fileURLWithPath: "/private/tmp/bitmatch-app-many-files-\(UUID())", isDirectory: true)
        let artifacts = root.appendingPathComponent("evidence")
        let source = root.appendingPathComponent("Card")
        let fm = FileManager.default
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("owned many-files app fixture".utf8).write(to: root.appendingPathComponent(".bitmatch-owned"), options: .withoutOverwriting)
        try await withPrivateProbeDiagnostics(root: root, artifacts: artifacts) { diagnostics in
            let suite = "BitMatchTests.ManyFiles.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: GeneralSettings.notificationPromptAskedKey)
            defaults.set(false, forKey: GeneralSettings.notifyFinishKey)
            defaults.set(false, forKey: GeneralSettings.notifyAttentionKey)
            let memory = ManyFilesMemory(maxSeconds: maxSeconds, includeMHL: includeMHL)
            let pipeline = TransferPipeline(fileSystem: MacOSFileSystemService.shared, checksum: ChecksumEngine.shared)
            let coordinator = SharedAppCoordinator(platformManager: RecordingPlatformManager(fileOperations: pipeline),
                transferJournal: LocalTransferJournal(fileURL: artifacts.appendingPathComponent("history.json")),
                projectStore: InMemoryPhotographerJobStore(), defaults: defaults,
                physicalDiskIdentityProvider: ManyFilesAbstractDisks())
            let renders = ManyFilesRenders()
            let host = NSHostingView(rootView: ManyFilesLiveView(coordinator: coordinator, renders: renders)
                .frame(width: 900, height: 1000).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 900, height: 1000),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host; window.isReleasedWhenClosed = false
            host.layoutSubtreeIfNeeded()
            defer { window.close() }
            let worker = Task { @MainActor in
                try await run(root: root, source: source, artifacts: artifacts, count: count, withReports: reports == "both", includeMHL: includeMHL,
                    coordinator: coordinator, memory: memory, host: host, renders: renders)
            }
            let monitor = memory.monitor {
                worker.cancel(); pipeline.cancelOperation()
                TransferDiagnostics.$recordingStoreOverride.withValue(diagnostics) {
                    Task { @MainActor in if coordinator.isOperationInProgress { coordinator.cancelOperation() } }
                }
            }
            let layout = Task { @MainActor in
                while !Task.isCancelled {
                    host.layoutSubtreeIfNeeded()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            do {
                try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel(); pipeline.cancelOperation() }
                try memory.requireSafe()
                guard testRun?.totalFailureCount == 0 else { throw ManyFilesError.assertionFailure }
                memory.mark("settling")
                try await Task.sleep(for: .seconds(2))
                monitor.cancel(); await monitor.value
                layout.cancel(); await layout.value
                try memory.requireSafe()
                try save(memory, artifacts: artifacts, outcome: "passed")
                // Keep compact evidence/history; remove only owned media after success.
                let ownedMedia = Set(["Card", "BackupA-0", "BackupB-0", "BackupA-1", "BackupB-1"])
                for entry in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where ownedMedia.contains(entry.lastPathComponent) {
                    try fm.removeItem(at: entry)
                }
                print("APP_MANY_FILES PASSED count=\(count) backups=2 reports=\(reports) mhl=\(includeMHL) artifacts=\(artifacts.path)")
            } catch {
                worker.cancel(); pipeline.cancelOperation()
                if coordinator.isOperationInProgress { coordinator.cancelOperation() }
                _ = await worker.result
                monitor.cancel(); await monitor.value
                layout.cancel(); await layout.value
                try? save(memory, artifacts: artifacts, outcome: "failed")
                print("APP_MANY_FILES FAILED retainedFixture=\(root.path)")
                throw error
            }
        }
    }

    private func withPrivateProbeDiagnostics<T>(root: URL, artifacts: URL,
                                                operation: (TransferDiagnosticStore) async throws -> T) async throws -> T {
        // This contains inherited coordinator/pipeline/report logging. ASC MHL's
        // detached writer does not inherit this scope. Keep the historical MHL-on
        // default, but use MHL=0 when isolating the copy/report memory workload.
        let fm = FileManager.default
        let diagnosticRoot = artifacts.appendingPathComponent("probe-diagnostics", isDirectory: true)
        try fm.createDirectory(at: diagnosticRoot, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let defaultsSuite = "BitMatchTests.ManyFiles.Diagnostics.\(UUID())"
        let privateDefaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { privateDefaults.removePersistentDomain(forName: defaultsSuite) }
        let crashEvidence = LocalCrashEvidenceStore(
            directory: diagnosticRoot.appendingPathComponent("PrivateCrashEvidence", isDirectory: true),
            defaults: privateDefaults, consentProvider: { false }
        )
        crashEvidence.setEnabled(false)
        let store = TransferDiagnosticStore(
            directory: diagnosticRoot.appendingPathComponent("TransferRing", isDirectory: true),
            systemEvidenceStore: crashEvidence
        )
        let fixtureIdentity = try directoryIdentity(root)
        let artifactsIdentity = try directoryIdentity(artifacts)
        let diagnosticsIdentity = try directoryIdentity(diagnosticRoot)

        func save(_ outcome: String) throws {
            let exported = try store.exportData()
            try exported.write(to: diagnosticRoot.appendingPathComponent("transfer-diagnostics.json"), options: .atomic)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let events = decoded["events"] as? [Any] ?? []
            let receipt: [String: Any] = [
                "formatVersion": 1, "outcome": outcome, "processID": getpid(),
                "fixtureRootIdentity": fixtureIdentity, "artifactsRootIdentity": artifactsIdentity,
                "diagnosticRootIdentity": diagnosticsIdentity, "eventCount": events.count,
                "privateCrashEvidenceEnabled": crashEvidence.snapshot().enabled,
                "scopeNote": "Selected test body is scoped; app/test-host startup before the opt-in method is not isolated."
            ]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: diagnosticRoot.appendingPathComponent("receipt.json"), options: .atomic)
        }

        let value: T
        do {
            value = try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
                try await operation(store)
            }
        } catch {
            try? save("failed")
            throw error
        }
        try save("passed")
        return value
    }

    private func directoryIdentity(_ url: URL) throws -> [String: UInt64] {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ManyFilesError.invalidFixture
        }
        return ["device": UInt64(info.st_dev), "inode": UInt64(info.st_ino)]
    }

    private func run(root: URL, source: URL, artifacts: URL, count: Int, withReports: Bool, includeMHL: Bool,
                     coordinator: SharedAppCoordinator, memory: ManyFilesMemory,
                     host: NSView, renders: ManyFilesRenders) async throws {
        memory.mark("fixture")
        let seed = Task.detached { try Self.seed(source, count: count) }
        let original = try await withTaskCancellationHandler { try await seed.value } onCancel: { seed.cancel() }
        try memory.requireSafe()
        try JSONEncoder().encode(original).write(to: artifacts.appendingPathComponent("source-sha256.json"), options: .atomic)
        for pass in 0..<(withReports ? 2 : 1) {
            let report = pass == 1
            let destinations = ["BackupA-\(pass)", "BackupB-\(pass)"].map { root.appendingPathComponent($0) }
            for destination in destinations { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
            coordinator.resetForNewOperation()
            coordinator.cameraLabelSettings.label = ""
            coordinator.reportSettings.makeReport = report
            coordinator.reportSettings.includeThumbnails = false
            coordinator.verificationMode = .standard
            coordinator.generateASCMHL = includeMHL
            coordinator.destinationURLs = destinations
            coordinator.sourceURL = source
            memory.mark("selection-\(pass)")
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while !coordinator.canStartOperation && ProcessInfo.processInfo.systemUptime < deadline {
                try memory.requireSafe(); try await Task.sleep(for: .milliseconds(25))
            }
            guard coordinator.canStartOperation else { throw ManyFilesError.notReady }
            let firstRender = renders.active
            var updates = 0
            var finalLiveRows = 0
            var lastFraction = 0.0
            var rewound = false
            let live = coordinator.liveResults.$rows.sink { rows in finalLiveRows = rows.count }
            let progress = coordinator.liveProgress.$progress.compactMap { $0 }.sink { value in
                updates += 1
                if value.overallProgress < lastFraction || value.overallProgress >= 1 { rewound = true }
                lastFraction = value.overallProgress
                memory.mark("run-\(pass)-\(value.currentStage.rawValue)")
            }
            let started = ProcessInfo.processInfo.systemUptime
            memory.mark("run-\(pass)")
            await coordinator.startOperation()
            live.cancel(); progress.cancel()
            host.layoutSubtreeIfNeeded()
            try memory.requireSafe()
            guard !rewound, updates > 1, finalLiveRows == count * 2,
                  renders.active > firstRender,
                  coordinator.results.count == count * 2, coordinator.results.allSatisfy(\.isVerifiedStatus),
                  let record = coordinator.outcomeRecord, record.state == .completed,
                  record.plannedFileCounts == [count, count], record.results.count == count * 2,
                  record.results.allSatisfy(\.isVerifiedStatus), record.independentDestinationCount == 2,
                  coordinator.transferJournal.records.count == pass + 1 else { throw ManyFilesError.incomplete }
            let operation = try XCTUnwrap(coordinator.currentOperation)
            guard operation.results.count == count * 2, operation.results.allSatisfy({ $0.success && $0.verificationResult?.isValid == true }),
                  Set(record.results.map(\.id)) == Set(coordinator.results.map(\.id)) else { throw ManyFilesError.incomplete }
            memory.mark("hashes-\(pass)")
            let checks = Task.detached {
                guard try Self.hashes(source) == original else { throw ManyFilesError.sourceChanged }
                for destination in destinations {
                    let output = SafetyValidator.resolvedDestinationRoot(source: source, destination: destination, settings: operation.settings)
                    let actual = try Self.hashes(output, mediaOnly: true)
                    guard actual == original else { throw ManyFilesError.destinationChanged }
                }
            }
            try await withTaskCancellationHandler { try await checks.value } onCancel: { checks.cancel() }
            try memory.requireSafe()
            var pdfPages = 0
            if report {
                memory.mark("pdfCheck-\(pass)")
                let reports = destinations[0].appendingPathComponent("Reports")
                let pdfs = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension.lowercased() == "pdf" }
                pdfPages = try autoreleasepool {
                    guard pdfs.count == 1, let pdf = PDFDocument(url: pdfs[0]), pdf.pageCount > 0,
                          let text = pdf.string, text.contains("VERIFICATION SUCCESSFUL") else { throw ManyFilesError.incomplete }
                    // Each selected source path must appear once per backup in the actual PDF manifest.
                    // PDFKit may split text runs after underscores even when the page is visually unwrapped.
                    // These fixed fixture names contain no whitespace; this is not a general path parser.
                    let pattern = try NSRegularExpression(pattern: #"Folder[0-9]+/file_\s*[0-9]+\.bin"#)
                    var occurrences: [String: Int] = [:]
                    pattern.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
                        if let match, let range = Range(match.range, in: text) {
                            occurrences[String(text[range].filter { !$0.isWhitespace }), default: 0] += 1
                        }
                    }
                    guard Set(occurrences.keys) == Set(original.keys), occurrences.values.allSatisfy({ $0 == 2 }) else {
                        throw ManyFilesError.incomplete
                    }
                    return pdf.pageCount
                }
                try FileManager.default.copyItem(at: pdfs[0], to: artifacts.appendingPathComponent("report-\(pass).pdf"))
            } else if FileManager.default.fileExists(atPath: destinations[0].appendingPathComponent("Reports").path) {
                throw ManyFilesError.incomplete
            }
            try memory.requireSafe()
            memory.completed(pass: pass, files: count, rows: count * 2, updates: updates,
                renders: renders.active - firstRender, report: report, pdfPages: pdfPages, seconds: ProcessInfo.processInfo.systemUptime - started)
            try save(memory, artifacts: artifacts, outcome: "running")
        }
    }

    private nonisolated static func seed(_ source: URL, count: Int) throws -> [String: String] {
        for folder in 0..<32 { try FileManager.default.createDirectory(at: source.appendingPathComponent("Folder\(folder)"), withIntermediateDirectories: false) }
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                var bytes = Data(repeating: UInt8(truncatingIfNeeded: index), count: 1024)
                var value = UInt64(index).bigEndian
                withUnsafeBytes(of: &value) { bytes.replaceSubrange(0..<8, with: $0) }
                try bytes.write(to: source.appendingPathComponent("Folder\(index % 32)/file_\(index).bin"), options: .withoutOverwriting)
            }
        }
        return try hashes(source)
    }

    private nonisolated static func hashes(_ root: URL, mediaOnly: Bool = false) throws -> [String: String] {
        var output: [String: String] = [:]
        let files = try autoreleasepool { try CardSource.enumerateRegularFiles(base: root) }
        for file in files {
            try Task.checkCancellation()
            if mediaOnly && (file.relativePath.hasPrefix("ascmhl/") || file.relativePath.hasPrefix("Reports/")) { continue }
            if mediaOnly && TransferStatusMarker.hasExactName(file.relativePath) {
                guard TransferStatusMarker.validatedStatus(at: file.url, relativePath: file.relativePath) == .filesVerified else {
                    throw ManyFilesError.destinationChanged
                }
                continue
            }
            output[file.relativePath] = try autoreleasepool {
                let handle = try FileHandle(forReadingFrom: file.url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while true {
                    try Task.checkCancellation()
                    let count = try autoreleasepool { () throws -> Int in
                        let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data(); hasher.update(data: bytes); return bytes.count
                    }
                    if count == 0 { break }
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        return output
    }

    private func save(_ memory: ManyFilesMemory, artifacts: URL, outcome: String) throws {
        var state = memory.snapshot(); state.outcome = outcome
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: artifacts.appendingPathComponent("memory.json"), options: .atomic)
    }
}

private struct ManyFilesAbstractDisks: PhysicalDiskIdentityProviding {
    func physicalDiskIdentity(for url: URL) -> String? { "synthetic-abstract-" + url.lastPathComponent }
}

@MainActor private final class ManyFilesRenders {
    var active = 0
    func render(_ running: Bool) { if running { active += 1 } }
}

private struct ManyFilesLiveView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @ObservedObject var progress: LiveProgressFeed
    let renders: ManyFilesRenders
    init(coordinator: SharedAppCoordinator, renders: ManyFilesRenders) {
        self.coordinator = coordinator; self.progress = coordinator.liveProgress; self.renders = renders
    }
    var body: some View {
        let _ = renders.render(coordinator.isOperationInProgress)
        return ScrollView {
            VStack {
                TransferQueueSection(coordinator: coordinator)
                if coordinator.isOperationInProgress {
                    ProgressScreen(presentation: .make(coordinator: coordinator),
                        actions: ProgressActions(pause: { Task { await coordinator.pauseOperation() } },
                            resume: { Task { await coordinator.resumeOperation() } },
                            cancel: { coordinator.cancelOperation() }), confirmingCancel: .constant(false))
                }
            }.padding()
        }
    }
}

private enum ManyFilesError: Error { case invalidFixture, memoryLimit, deadline, assertionFailure, notReady, incomplete, sourceChanged, destinationChanged }

private final class ManyFilesMemory: Sendable {
    struct Phase: Codable { var peakMiB: Int; var lastMiB: Int }
    struct State: Codable {
        var outcome = "running"; var phase = "initial"; var samples = 0
        var initialMiB = 0; var peakMiB = 0; var lastMiB = 0
        var guardTriggered = false; var missingSample = false
        var phases: [String: Phase] = [:]
        var runs: [[String: String]] = []
        let limitMiB = 1024
        let maxSeconds: TimeInterval
        let includeMHL: Bool
        let scope = "Actual app-test process, coordinator/pipeline/live NSHostingView; host scratch only, abstract disk identities, expected O(N) rows/history/PDF storage, not issue23 or constant-memory proof"
    }
    private let state: Mutex<State>
    private let started = ProcessInfo.processInfo.systemUptime
    private let maxSeconds: TimeInterval
    init(maxSeconds: TimeInterval = 600, includeMHL: Bool = true) {
        self.maxSeconds = maxSeconds
        state = Mutex(State(maxSeconds: maxSeconds, includeMHL: includeMHL))
    }
    func snapshot() -> State { state.withLock { $0 } }
    func mark(_ phase: String) { state.withLock { $0.phase = phase }; _ = sample() }
    func completed(pass: Int, files: Int, rows: Int, updates: Int, renders: Int, report: Bool, pdfPages: Int, seconds: TimeInterval) {
        state.withLock { $0.runs.append(["pass": "\(pass)", "files": "\(files)", "verifiedRows": "\(rows)",
            "progressUpdates": "\(updates)", "activeViewRenders": "\(renders)", "report": "\(report)", "pdfPages": "\(pdfPages)", "seconds": "\(seconds)"] ) }
    }
    func requireSafe() throws {
        if sample() { throw ManyFilesError.memoryLimit }
        if ProcessInfo.processInfo.systemUptime - started >= maxSeconds { throw ManyFilesError.deadline }
        try Task.checkCancellation()
    }
    func monitor(cancel: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                if self.sample() || ProcessInfo.processInfo.systemUptime - self.started >= self.maxSeconds { cancel(); return }
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
            }
        }
    }
    @discardableResult func sample() -> Bool {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return record(result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil)
    }
    @discardableResult func record(_ value: Int?) -> Bool {
        state.withLock { s in
            guard let value else { s.guardTriggered = true; s.missingSample = true; return true }
            if s.samples == 0 { s.initialMiB = value }
            s.samples += 1; s.lastMiB = value; s.peakMiB = max(s.peakMiB, value)
            let old = s.phases[s.phase]?.peakMiB ?? 0
            s.phases[s.phase] = Phase(peakMiB: max(old, value), lastMiB: value)
            if value >= s.limitMiB { s.guardTriggered = true }
            return s.guardTriggered
        }
    }
}
#endif
