import Foundation
import SwiftUI
import XCTest
@testable import BitMatch
import BitMatchEngine

/// Guards the shared status presentation used by the Mac results table,
/// the Mac report view, and the photographer card rows on Mac and iOS.
/// Green (`.verified`) must only ever appear for a verified result.
final class ResultStatusPresentationTests: XCTestCase {

    // MARK: - Engine statuses (FileOperationResult.statusDescription)

    func testVerifiedEngineStatusIsGreen() {
        let status = engineStatus(success: true, matches: true)
        XCTAssertEqual(status, "✅ Verified")
        XCTAssertEqual(ResultStatusPresentation.make(status: status).tone, .verified)
        XCTAssertEqual(ResultStatusPresentation.make(status: status).symbol, "checkmark.circle")
    }

    func testCopiedEngineStatusIsNotGreen() {
        // "✅ Copied" passes isSuccessStatus but carries no checksum
        // evidence, so it must not look verified.
        let status = engineStatus(success: true, matches: nil)
        XCTAssertEqual(status, "✅ Copied")
        XCTAssertTrue(ResultRow.isSuccessStatus(status))
        XCTAssertEqual(ResultStatusPresentation.make(status: status).tone, .unverified)
        XCTAssertEqual(ResultStatusPresentation.make(status: status).symbol, "doc.on.doc")
    }

    /// Audit H2: a checksum mismatch is corrupted data, not a minor warning.
    /// It must not share the orange triangle used for "missing" or a
    /// generic warning, and must be at least as severe as a plain failure.
    func testChecksumMismatchEngineStatusIsFailure() {
        let status = engineStatus(success: true, matches: false)
        XCTAssertEqual(status, "⚠️ Checksum Mismatch")
        XCTAssertEqual(ResultStatusPresentation.make(status: status).tone, .failure)
        XCTAssertEqual(ResultStatusPresentation.make(status: status).symbol, "xmark.octagon.fill")
    }

    func testFailedEngineStatusIsFailure() {
        let status = engineStatus(success: false, matches: nil)
        XCTAssertEqual(status, "❌ Failed")
        XCTAssertEqual(ResultStatusPresentation.make(status: status).tone, .failure)
    }

    func testVerificationResultDescriptions() {
        for algorithm in ChecksumAlgorithm.allCases {
            let match = verification(matches: true, algorithm: algorithm).description
            let differ = verification(matches: false, algorithm: algorithm).description
            XCTAssertEqual(ResultStatusPresentation.make(status: match).tone, .verified, match)
            XCTAssertEqual(ResultStatusPresentation.make(status: differ).tone, .failure, differ)
        }
    }

    // MARK: - Other statuses that reach the UI (legacy rows, dev mode)

    func testLegacyAndDevModeStatuses() {
        let expected: [(String, ResultStatusTone)] = [
            ("✅ Match", .verified),
            ("✅ Verified Match", .verified),
            ("✅ Copied - not verified", .unverified),
            ("✅ Unverified", .unverified),
            ("✅", .unverified),
            ("Match", .neutral),              // bare text (the old fake verify): no ✅, so not a success
            ("Content Mismatch", .warning),   // bare text (the old fake verify)
            ("Size Mismatch", .warning),
            ("Missing in Destination", .warning),
            ("❌ Checksum Mismatch", .failure),
            ("❌ Copy Failed: The operation couldn't be completed.", .failure),
            ("Error: something went wrong", .failure),
            ("🔄 Copying", .inProgress),
            ("Extra in Destination", .neutral),
            ("Copied", .neutral),
            ("Unknown", .neutral),
            ("", .neutral),
        ]
        for (status, tone) in expected {
            XCTAssertEqual(ResultStatusPresentation.make(status: status).tone, tone, "status: \(status)")
        }
    }

    // MARK: - Invariant: green implies verified

    func testGreenOnlyForSuccessStatusesThatSayVerified() {
        let statuses = [
            "✅ Verified", "✅ Copied", "⚠️ Checksum Mismatch", "❌ Failed",
            "✅ Match", "✅ Verified Match", "✅ ⚠️ Verified", "✅ Verified (error)",
            "✅ Verified - missing sidecar", "✅ Match failed", "✅ Checksum Mismatch",
            "Verified", "Match", "✅ Copied - not verified", "✅ Done", "",
        ]
        for status in statuses {
            let presentation = ResultStatusPresentation.make(status: status)
            if presentation.tone == .verified {
                XCTAssertTrue(ResultRow.isSuccessStatus(status), "green for non-success status: \(status)")
                XCTAssertFalse(status.contains("Copied"), "green for copy-only status: \(status)")
            }
            XCTAssertEqual(presentation.tone == .verified, presentation.color == .green, "status: \(status)")
        }
    }

    func testConnectionAndDocumentDeliverySuccessStayNeutral() {
        XCTAssertEqual(NonVerificationSuccessPresentation.tone, .neutral)
        XCTAssertNotEqual(NonVerificationSuccessPresentation.tone, .verified)
        XCTAssertNotEqual(NonVerificationSuccessPresentation.tone.color, .green)
    }

    // MARK: - Photographer card states

    func testOnlyLocallySafeCardIsGreen() {
        let states: [PhotographerLocalState] = [.notStarted, .copying, .verifying, .locallySafe, .issues, .cancelled]
        for state in states {
            let presentation = ResultStatusPresentation.make(localState: state)
            XCTAssertEqual(presentation.tone == .verified, state == .locallySafe, "state: \(state)")
        }
        XCTAssertEqual(ResultStatusPresentation.make(localState: .issues).tone, .failure)
        XCTAssertEqual(ResultStatusPresentation.make(localState: .copying).tone, .inProgress)
        XCTAssertEqual(ResultStatusPresentation.make(localState: .verifying).tone, .inProgress)
    }

    // MARK: - Helpers

    /// `matches == nil` means no verification ran for this file.
    private func engineStatus(success: Bool, matches: Bool?) -> String {
        FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/source/clip.mov"),
            destinationURL: URL(fileURLWithPath: "/destination/clip.mov"),
            success: success,
            error: success ? nil : NSError(domain: "test", code: 1),
            fileSize: 10,
            verificationResult: matches.map { verification(matches: $0, algorithm: .sha256) },
            processingTime: 0
        ).statusDescription
    }

    private func verification(matches: Bool, algorithm: ChecksumAlgorithm) -> VerificationResult {
        VerificationResult(
            sourceChecksum: "source",
            destinationChecksum: matches ? "source" : "different",
            matches: matches,
            checksumType: algorithm,
            processingTime: 0,
            fileSize: 10
        )
    }
}
