// FailureReasonTests.swift
// The engine names why a file failed in a bounded token the app can word.
import Foundation
import Testing
@testable import BitMatchEngine

@Suite struct FailureReasonTests {
    private func failedResult(_ error: NSError) -> FileOperationResult {
        FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/card/a.mov"),
            destinationURL: URL(fileURLWithPath: "/Volumes/T9/a.mov"),
            success: false, error: error, fileSize: 1,
            verificationResult: nil, processingTime: 0
        )
    }

    @Test func rowCarriesOutOfSpaceReason() {
        let result = failedResult(NSError(
            domain: NSPOSIXErrorDomain, code: Int(ENOSPC),
            userInfo: [ResultFailureReason.userInfoKey: ResultFailureReason.outOfSpace.rawValue]
        ))
        let row = TransferCompletion.row(from: result, destinationRoots: [URL(fileURLWithPath: "/Volumes/T9")])
        #expect(row.failureReason == "outOfSpace")
    }

    @Test func rowWithoutReasonStaysNil() {
        let result = failedResult(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        let row = TransferCompletion.row(from: result, destinationRoots: [URL(fileURLWithPath: "/Volumes/T9")])
        #expect(row.failureReason == nil)
    }

    @Test func journalRoundTripKeepsReasonAndToleratesItsAbsence() throws {
        let row = ResultRow(path: "/card/a.mov", status: ResultOutcome.failed.statusText, size: 1,
                            checksum: nil, destination: "T9", failureReason: "companionConflict")
        let decoded = try JSONDecoder().decode(ResultRow.self, from: JSONEncoder().encode(row))
        #expect(decoded.failureReason == "companionConflict")

        let old = #"{"id":"\#(UUID().uuidString)","path":"/card/a.mov","status":"\#(ResultOutcome.failed.statusText)","size":1}"#
        let legacy = try JSONDecoder().decode(ResultRow.self, from: Data(old.utf8))
        #expect(legacy.failureReason == nil)
    }

    private func summary(_ reasons: [String?]) -> String {
        let rows = reasons.enumerated().map { index, reason in
            ResultRow(path: "/card/f\(index).mov", status: ResultOutcome.failed.statusText, size: 0,
                      checksum: nil, destination: "T9", destinationPath: "/Volumes/T9/f\(index).mov",
                      failureReason: reason)
        }
        return TransferCompletion.verdict(
            rows: rows, sourceFiles: nil, destinations: [URL(fileURLWithPath: "/Volumes/T9")],
            source: URL(fileURLWithPath: "/card"), settings: CameraLabelSettings(),
            mode: .standard, generateASCMHL: false, handoffIssues: [], reportIssue: nil,
            project: .init(didPersist: true, locallySafe: nil)
        ).message
    }

    @Test func summaryNamesOutOfSpaceWhenEveryFailureSharesIt() {
        #expect(summary(["outOfSpace", "outOfSpace", "outOfSpace"]).hasPrefix("3 files failed; a backup ran out of space"))
    }

    @Test func summaryNamesCompanionConflictWhenEveryFailureSharesIt() {
        #expect(summary(["companionConflict"]).contains("Turn on Ignore AppleDouble metadata files"))
    }

    @Test func summaryStaysPlainWhenReasonsDiffer() {
        #expect(!summary(["outOfSpace", nil]).contains("ran out of space"))
        #expect(!summary(["outOfSpace", "companionConflict"]).contains("ran out of space"))
    }
}
