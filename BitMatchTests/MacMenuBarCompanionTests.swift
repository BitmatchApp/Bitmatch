import AppKit
import Testing
@testable import BitMatch
import BitMatchEngine

struct MacMenuBarCompanionTests {
    @Test @MainActor func mainWindowAccessorReportsItsHostInsteadOfAnotherWindow() {
        let decoy = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        decoy.isReleasedWhenClosed = false
        main.isReleasedWhenClosed = false
        defer { decoy.close(); main.close() }

        var reported: NSWindow?
        let observer = MainWindowAccessor.WindowObserverView()
        observer.onWindow = { reported = $0 }
        decoy.makeKeyAndOrderFront(nil)
        main.contentView?.addSubview(observer)
        #expect(reported === main)
    }

    @Test func destinationCopyCountNeverBecomesAVerifiedVerdict() {
        #expect(MenuBarDestinationLabel.text(for: .waiting) == "Waiting")
        #expect(MenuBarDestinationLabel.text(for: .copying) == "Copying")
        // The engine counts both successful and failed files as processed.
        #expect(MenuBarDestinationLabel.text(for: .copied) == "Processed · result pending")
        #expect(MenuBarDestinationLabel.text(for: .verifying) == "Verifying")
    }

    @Test func recentStatusUsesDerivedSavedVerdictForOldRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menu-plan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Card")
        let destination = root.appendingPathComponent("Backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var record = LocalTransferRecord(id: UUID(), createdAt: Date(),
            source: try LocalTransferResource(url: source),
            destinations: [try LocalTransferResource(url: destination)],
            verificationMode: .standard, cameraSettings: CameraLabelSettings(), reportSettings: ReportPrefs())
        #expect(MenuBarRecentTransfer.status(for: record)?.text == nil)
        record.state = .completed
        record.results = [ResultRow(path: source.appendingPathComponent("clip.mov").path,
            status: ResultOutcome.verified.statusText, size: 1, checksum: "abc", destination: "Backup",
            destinationPath: destination.appendingPathComponent("clip.mov").path)]
        #expect(MenuBarRecentTransfer.latest(in: [record])?.status == "Needs review")
        #expect(MenuBarRecentTransfer.latest(in: [record])?.needsAttention == true)
        record.plannedFileCounts = [1]
        #expect(MenuBarRecentTransfer.latest(in: [record])?.status == "Completed · review results in BitMatch")
        record.state = .cancelled
        #expect(MenuBarRecentTransfer.status(for: record)?.text == "Transfer cancelled")
        record.state = .interrupted
        #expect(MenuBarRecentTransfer.status(for: record)?.text == "Transfer interrupted")
    }
}
