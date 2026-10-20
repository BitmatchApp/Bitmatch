import AppKit
import Testing
@testable import BitMatch
import BitMatchEngine

struct MacMenuBarCompanionTests {
    @Test @MainActor func idleIconHasVisibleTemplatePixelsAtMenuBarSize() throws {
        try expectVisibleTemplate(MenuBarStatusIcon.image(isActive: false, fraction: nil))
    }

    @Test(arguments: [0.0, 0.5, 0.99]) @MainActor
    func measuredProgressIconHasVisibleTemplatePixels(_ fraction: Double) throws {
        try expectVisibleTemplate(MenuBarStatusIcon.image(isActive: true, fraction: fraction))
    }

    @Test @MainActor func indeterminateIconHasVisibleTemplatePixels() throws {
        try expectVisibleTemplate(MenuBarStatusIcon.image(isActive: true, fraction: nil))
    }

    @Test @MainActor func idleAndProgressStatesDrawDifferentContent() throws {
        let images = [
            MenuBarStatusIcon.image(isActive: false, fraction: nil),
            MenuBarStatusIcon.image(isActive: true, fraction: 0),
            MenuBarStatusIcon.image(isActive: true, fraction: 0.5),
            MenuBarStatusIcon.image(isActive: true, fraction: 0.99),
            MenuBarStatusIcon.image(isActive: true, fraction: nil)
        ]
        let masks = try images.map { try alphaMask(of: $0) }
        #expect(Set(masks).count == images.count)
    }

    @Test @MainActor func progressImagesAreQuantizedAndNeverClaimCompletion() {
        let middle = MenuBarStatusIcon.image(isActive: true, fraction: 0.5)
        #expect(middle === MenuBarStatusIcon.image(isActive: true, fraction: 0.509))
        let finishing = MenuBarStatusIcon.image(isActive: true, fraction: 0.99)
        #expect(finishing === MenuBarStatusIcon.image(isActive: true, fraction: 0.9999))
        #expect(finishing === MenuBarStatusIcon.image(isActive: true, fraction: 1))
        #expect(finishing === MenuBarStatusIcon.image(isActive: true, fraction: 2))
        #expect(MenuBarStatusIcon.image(isActive: true, fraction: -1)
                === MenuBarStatusIcon.image(isActive: true, fraction: 0))
        let unknown = MenuBarStatusIcon.image(isActive: true, fraction: nil)
        #expect(unknown === MenuBarStatusIcon.image(isActive: true, fraction: .nan))
        #expect(unknown === MenuBarStatusIcon.image(isActive: true, fraction: .infinity))
    }

    @Test(arguments: [false, true]) @MainActor
    func iconCanRenderAwayFromMainActor(_ isActive: Bool) async throws {
        let cached = MenuBarStatusIcon.image(isActive: isActive, fraction: 0.37)
        let image = try #require(cached.copy() as? NSImage)
        image.cacheMode = .never
        image.recache()
        let isolatedImage = BackgroundImage(image: image)
        let rendered = await Task.detached {
            autoreleasepool {
                (Thread.isMainThread, isolatedImage.image.tiffRepresentation)
            }
        }.value

        #expect(!rendered.0)
        let data = try #require(rendered.1)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var hasVisiblePixel = false
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                hasVisiblePixel = hasVisiblePixel || (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
            }
        }
        #expect(hasVisiblePixel)
    }

    // The private copy is configured on MainActor, then read only by its one
    // background task. No NSImage mutation crosses threads.
    private struct BackgroundImage: @unchecked Sendable {
        let image: NSImage
    }

    @MainActor private func expectVisibleTemplate(_ image: NSImage) throws {
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate)
        let alpha = try alphaMask(of: image)
        #expect(alpha.contains { $0 > 0 })
        #expect(alpha.contains(0))
    }

    @MainActor private func alphaMask(of image: NSImage) throws -> [UInt8] {
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        #expect(bitmap.pixelsWide >= 18)
        #expect(bitmap.pixelsWide <= 72)
        #expect(bitmap.pixelsHigh == bitmap.pixelsWide)
        var alpha: [UInt8] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = try #require(bitmap.colorAt(x: x, y: y))
                alpha.append(UInt8(min(max(color.alphaComponent, 0), 1) * 255))
            }
        }
        return alpha
    }

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
