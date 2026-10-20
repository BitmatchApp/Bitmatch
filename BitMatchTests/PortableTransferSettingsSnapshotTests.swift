import XCTest
import SwiftUI
import AppKit
import Vision
@testable import BitMatch
import BitMatchEngine

@MainActor
final class PortableTransferSettingsSnapshotTests: XCTestCase {
    func testMacImportReviewLayout() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1"
            || environment["TEST_RUNNER_BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Enable workflow snapshots for settings captures")
        }
        let current = PortableTransferSettings(verificationMode: .standard, generateASCMHL: true,
            ignoreAppleDouble: true, reports: .init(makeReport: true, includeThumbnails: false),
            naming: .init(position: .prefix, separator: .underscore, autoNumber: true, groupByCamera: false))
        let full = PortableTransferSettings(verificationMode: .quick, generateASCMHL: false,
            ignoreAppleDouble: false, reports: .init(makeReport: false, includeThumbnails: true),
            naming: .init(position: .suffix, separator: .dash, autoNumber: false, groupByCamera: true))
        let few = PortableTransferSettings(verificationMode: current.verificationMode,
            generateASCMHL: current.generateASCMHL, ignoreAppleDouble: current.ignoreAppleDouble,
            reports: full.reports, naming: current.naming)
        let fullReview = TransferSettingsReview(current: current, proposed: full)
        let fewReview = TransferSettingsReview(current: current, proposed: few)
        XCTAssertEqual(fullReview.changes.count, 9)
        XCTAssertEqual(fewReview.changes.count, 2)
        let fullHeight = try captureReview(fullReview, name: "mac-import-nine-changes", requiresScroll: true)
        let fewHeight = try captureReview(fewReview, name: "mac-import-two-changes", requiresScroll: false)
        XCTAssertLessThan(fewHeight, fullHeight - 80, "A short review should size to its content")
    }

    private func captureReview(_ review: TransferSettingsReview, name: String, requiresScroll: Bool) throws -> CGFloat {
        let host = NSHostingView(rootView: TransferSettingsReviewView(review: review, apply: {}, cancel: {})
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark).transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let height = host.fittingSize.height
        XCTAssertGreaterThan(height, 180)
        XCTAssertLessThanOrEqual(height, 600)
        window.setContentSize(CGSize(width: 480, height: height))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var seen = Set<String>()
        var actionBounds: [String: CGRect] = [:]
        func record(_ suffix: String) throws {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
            let observations = request.results ?? []
            for observation in observations {
                if let text = observation.topCandidates(1).first?.string.lowercased() { seen.insert(text) }
            }
            let heading = try XCTUnwrap(observations.first {
                $0.topCandidates(1).first?.string.lowercased() == "import settings"
            }, "The review title must remain visible")
            let headingInset = (1 - heading.boundingBox.maxY) * height
            XCTAssertGreaterThan(headingInset, 10)
            XCTAssertLessThan(headingInset, 60, "The title belongs at the top, without an empty vertical band")
            for title in ["cancel", "apply"] {
                let action = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string.lowercased() == title })
                XCTAssertLessThan(action.boundingBox.maxY * height, 65, "Review actions must stay at the bottom")
                if let previous = actionBounds[title] {
                    XCTAssertEqual(action.boundingBox.midY, previous.midY, accuracy: 0.005, "Actions must not scroll")
                } else { actionBounds[title] = action.boundingBox }
            }
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = name + suffix
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        try record("-top")
        if requiresScroll {
            let scroll = try XCTUnwrap(findOverflowingScrollView(in: host), "Nine changes need a scrollable review")
            let document = try XCTUnwrap(scroll.documentView)
            let extent = max(0, document.bounds.height - scroll.contentView.bounds.height)
            for (suffix, fraction) in [("-middle", 0.5), ("-bottom", 1.0)] {
                let offset = document.isFlipped ? extent * fraction : extent * (1 - fraction)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
                try record(suffix)
            }
        } else {
            XCTAssertNil(findOverflowingScrollView(in: host), "Two changes should fit without a tall empty sheet")
        }
        let text = seen.joined(separator: " ")
        for change in review.changes { XCTAssertTrue(text.contains(change.title.lowercased()), "Unreachable change: \(change.title)") }
        if review.proposed.verificationMode == .quick {
            XCTAssertTrue(text.contains("does not verify contents"), "Quick assurance warning must be reachable")
        }
        XCTAssertTrue(text.contains("changes apply to future transfers"))
        return height
    }

    func testCaptureMacTransferSettings() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1"
            || environment["TEST_RUNNER_BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Enable workflow snapshots for settings captures")
        }
        let folders = try CoordinatorFolders()
        defer { folders.cleanup() }
        let app = SharedAppCoordinator(platformManager: RecordingPlatformManager(fileOperations: RecordingFileOperations()),
            transferJournal: LocalTransferJournal(fileURL: folders.journalURL),
            projectStore: InMemoryPhotographerJobStore(), defaults: folders.defaults)
        let companions = MacAppEnvironment.makeForTesting(coordinator: app)
        let updater = UpdaterController(coordinator: app)
        let previousPane = UserDefaults.standard.object(forKey: "BitMatchSelectedSettingsPane")
        UserDefaults.standard.set("General", forKey: "BitMatchSelectedSettingsPane")
        defer {
            if let previousPane { UserDefaults.standard.set(previousPane, forKey: "BitMatchSelectedSettingsPane") }
            else { UserDefaults.standard.removeObject(forKey: "BitMatchSelectedSettingsPane") }
        }
        try capture(PreferencesWindow(coordinator: app, cameraAutoSource: companions.cameraAutoSource,
            remoteBackups: companions.remoteBackups, updater: updater), size: CGSize(width: 680, height: 720),
            name: "mac-transfer-settings", expected: ["notifications", "notify when a card needs attention"],
            scrolledExpected: ["transfer settings", "import settings", "export settings", "updates", "check now"],
            exactHeading: "notifications")
        UserDefaults.standard.set("Reports", forKey: "BitMatchSelectedSettingsPane")
        try capture(PreferencesWindow(coordinator: app, cameraAutoSource: companions.cameraAutoSource,
            remoteBackups: companions.remoteBackups, updater: updater), size: CGSize(width: 680, height: 720),
            name: "mac-report-settings", expected: ["reports", "create pdf"],
            scrolledExpected: ["include clip thumbnails in pdfs", "unavailable clips stay listed"],
            exactHeading: "reports", allowFittingContent: true)
        let current = app.portableTransferSettings
        let proposed = PortableTransferSettings(verificationMode: .quick, generateASCMHL: !current.generateASCMHL,
            ignoreAppleDouble: !current.ignoreAppleDouble,
            reports: .init(makeReport: !current.reports.makeReport, includeThumbnails: !current.reports.includeThumbnails),
            naming: .init(position: .suffix, separator: .dash, autoNumber: false, groupByCamera: true))
        try capture(TransferSettingsReviewView(review: .init(current: current, proposed: proposed), apply: {}, cancel: {}),
            size: CGSize(width: 480, height: 600), name: "mac-transfer-settings-preview", expected: ["verification", "quick"])
    }

    private func capture<V: View>(_ view: V, size: CGSize, name: String, expected: [String],
        scrolledExpected: [String]? = nil, exactHeading: String? = nil, allowFittingContent: Bool = false) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark).transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        host.frame = CGRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        try attach(host, name: name, expected: expected, exactHeading: exactHeading)
        if let scrolledExpected {
            guard let scroll = findOverflowingScrollView(in: host) else {
                XCTAssertTrue(allowFittingContent, "Tall Settings content must have a real scroll viewport")
                try attach(host, name: name + "-fits", expected: scrolledExpected)
                return
            }
            let document = try XCTUnwrap(scroll.documentView)
            let bottom = document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: CGPoint(x: 0, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            try attach(host, name: name + "-scrolled", expected: scrolledExpected)
            let top = document.isFlipped ? 0 : max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: top))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            try attach(host, name: name + "-top-restored", expected: expected, exactHeading: exactHeading)
        }
    }

    private func findOverflowingScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, !scroll.isHiddenOrHasHiddenAncestor,
           let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height + 1 {
            return scroll
        }
        return view.subviews.lazy.compactMap { self.findOverflowingScrollView(in: $0) }.first
    }

    private func attach(_ host: NSView, name: String, expected: [String], exactHeading: String? = nil) throws {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        for value in expected { XCTAssertTrue(text.contains(value), "\(name) missing \(value): \(text)") }
        if let exactHeading {
            let heading = (request.results ?? []).first { $0.topCandidates(1).first?.string.lowercased() == exactHeading }
            XCTAssertNotNil(heading, "\(name) must show its complete \(exactHeading) heading")
            if let heading { XCTAssertLessThan(heading.boundingBox.maxY, 0.995, "Heading must sit inside the viewport") }
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
