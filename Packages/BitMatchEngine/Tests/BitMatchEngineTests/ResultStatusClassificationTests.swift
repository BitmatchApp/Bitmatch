import XCTest
@testable import BitMatchEngine

/// Regression tests for report status classification.
/// The exported PDF/CSV/JSON reports previously classified any status whose
/// lowercased text contained "match" as a success — including
/// "⚠️ Checksum Mismatch" and "Size Mismatch" — so corrupted files were
/// reported as verified.
final class ResultStatusClassificationTests: XCTestCase {

    func testSuccessStatusesAreClassifiedAsSuccess() {
        let successStatuses = [
            "✅ Verified",
            "✅ Copied",
            "✅ Match",
            "✅ Verified Match",
        ]
        for status in successStatuses {
            XCTAssertTrue(ResultRow.isSuccessStatus(status), "Expected success for status: \(status)")
        }
    }

    func testMismatchStatusesAreClassifiedAsFailures() {
        let failureStatuses = [
            "⚠️ Checksum Mismatch",
            "❌ Checksum Mismatch",
            "Size Mismatch",
        ]
        for status in failureStatuses {
            XCTAssertFalse(ResultRow.isSuccessStatus(status), "Expected failure for status: \(status)")
        }
    }

    func testErrorStatusesAreClassifiedAsFailures() {
        let failureStatuses = [
            "❌ Failed",
            "❌ Copy Failed: The operation couldn't be completed.",
            "❌ Checksum Error: read failure",
            "Error: something went wrong",
            "Missing in Destination",
            "Extra in Destination",
        ]
        for status in failureStatuses {
            XCTAssertFalse(ResultRow.isSuccessStatus(status), "Expected failure for status: \(status)")
        }
    }

    func testUnknownOrEmptyStatusIsNotSuccess() {
        // Fail safe: a status we cannot positively identify as verified
        // must never be reported as a success in a verification document.
        XCTAssertFalse(ResultRow.isSuccessStatus(""))
        XCTAssertFalse(ResultRow.isSuccessStatus("Unknown"))
        XCTAssertFalse(ResultRow.isSuccessStatus("Copied"))
    }

    func testZeroByteResultUsesEmptyWording() {
        let row = ResultRow(path: "empty.mov", status: "✅ Verified", size: 0, checksum: "abc", destination: "Backup")
        XCTAssertEqual(row.formattedSize, "Empty")
        XCTAssertFalse(row.formattedSize.contains("Zero KB"))
    }
}
