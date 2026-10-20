import Foundation
import Testing
import XCTest
import SwiftUI
import UIKit
import Vision
@testable import BitMatch_iPad
import BitMatchEngine

@MainActor
struct PortableTransferSettingsIOSTests {
    @Test func mobileSettingsRoundTripPreviewCancelApplyAndPersistence() throws {
        let name = "BitMatch-iPadTests.PortableSettings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        func coordinator() -> SharedAppCoordinator {
            SharedAppCoordinator(platformManager: IOSPlatformManager.shared,
                transferJournal: LocalTransferJournal(fileURL: root.appendingPathComponent("journal-\(UUID()).json")),
                projectStore: UserDefaultsPhotographerJobStore(defaults: defaults), defaults: defaults)
        }
        let app = coordinator()
        app.reportSettings.operatorName = "Private operator"
        app.reportSettings.notes = "Private notes"
        app.cameraLabels.settings.label = "Private camera"
        let original = app.portableTransferSettings
        let proposed = mobileSettingsProposal()
        let model = TransferSettingsImportModel()
        try model.preview(proposed.encoded(), coordinator: app)
        #expect(app.portableTransferSettings == original)
        model.cancel()
        #expect(app.portableTransferSettings == original)
        #expect(model.review == nil)
        try model.preview(proposed.encoded(), coordinator: app)
        app.isOperationInProgress = true
        #expect(throws: TransferSettingsImportError.busy) { try model.apply(to: app) }
        app.isOperationInProgress = false
        try model.apply(to: app)
        #expect(app.portableTransferSettings == proposed)
        #expect(app.reportSettings.operatorName == "Private operator")
        #expect(app.reportSettings.notes == "Private notes")
        #expect(app.cameraLabels.settings.label == "Private camera")
        #expect(coordinator().portableTransferSettings == proposed)
        let text = String(decoding: try proposed.encoded(), as: UTF8.self)
        #expect(!text.contains("Private"))
    }

    @Test func mobileDecoderRejectsUnsupportedAndOversizedFiles() throws {
        let valid = try mobileSettingsProposal().encoded()
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["schemaVersion"] = 2
        #expect(throws: TransferSettingsImportError.unsupportedVersion) {
            _ = try PortableTransferSettings.decode(JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: TransferSettingsImportError.tooLarge) {
            _ = try PortableTransferSettings.decode(Data(repeating: 32, count: PortableTransferSettings.maximumBytes + 1))
        }
        #expect(throws: TransferSettingsImportError.invalidFile) { _ = try PortableTransferSettings.decode(Data("no".utf8)) }
    }
}

private func mobileSettingsProposal() -> PortableTransferSettings {
    .init(verificationMode: .quick, generateASCMHL: false, ignoreAppleDouble: false,
        reports: .init(makeReport: false, includeThumbnails: true),
        naming: .init(position: .suffix, separator: .dash, autoNumber: false, groupByCamera: true))
}

@MainActor
final class PortableTransferSettingsSnapshotTests: XCTestCase {
    func testRenderNarrowPhoneAndPadImportPreview() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1"
            || environment["TEST_RUNNER_BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS"] == "1" else {
            throw XCTSkip("Enable workflow snapshots for settings preview captures")
        }
        let current = PortableTransferSettings(verificationMode: .standard, generateASCMHL: true, ignoreAppleDouble: true,
            reports: .init(makeReport: true, includeThumbnails: false),
            naming: .init(position: .prefix, separator: .underscore, autoNumber: true, groupByCamera: false))
        let review = TransferSettingsReview(current: current, proposed: mobileSettingsProposal())
        XCTAssertEqual(review.changes.count, 9)
        for (name, size) in [("smallphone-transfer-settings-preview", CGSize(width: 320, height: 568)),
                             ("phone-transfer-settings-preview", CGSize(width: 390, height: 844)),
                             ("narrowpad-transfer-settings-preview", CGSize(width: 500, height: 700))] {
            let host = UIHostingController(rootView: TransferSettingsReviewView(review: review, apply: {}, cancel: {})
                .preferredColorScheme(.dark)
                .frame(width: size.width, height: size.height)
                .transaction { $0.disablesAnimations = true })
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                // Let UIKit finish the window's disappearance before removing
                // the hosting controller; the fixture must not strand a
                // NavigationStack appearance transition between captures.
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                window.rootViewController = nil
            }
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            host.view.layoutIfNeeded()
            try capture(host.view, size: size, name: name, expected: ["verification", "apply", "cancel"])
            // A short screen must keep the disclosure and actions reachable;
            // a tall render alone would conceal missing scrolling behavior.
            let scroll = try XCTUnwrap(findScrollView(in: host.view))
            // Form measures its later rows lazily. Re-settle after scrolling
            // rather than mistaking its initial estimated height for the end.
            for _ in 0..<4 {
                scroll.setContentOffset(CGPoint(x: 0,
                    y: max(-scroll.adjustedContentInset.top,
                        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                host.view.layoutIfNeeded()
            }
            try capture(host.view, size: size, name: name + "-scrolled", expected: ["quick checks file sizes", "future transfers", "apply", "cancel"])
        }
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > 0 { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    private func capture(_ view: UIView, size: CGSize, name: String, expected: [String]) throws {
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        for value in expected { XCTAssertTrue(text.contains(value), "\(name) missing \(value): \(text)") }
        let attachment = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
