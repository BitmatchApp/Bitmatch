// RunLedgerTests.swift
import Foundation
import Testing
@testable import BitMatchEngine

struct RunLedgerTests {
    private func row(
        _ name: String,
        verified: Bool = false,
        success: Bool = true,
        wasReused: Bool = false
    ) -> FileOperationResult {
        FileOperationResult(
            sourceURL: URL(fileURLWithPath: "/src/\(name)"),
            destinationURL: URL(fileURLWithPath: "/dst/\(name)"),
            success: success, error: nil, fileSize: 10,
            verificationResult: verified
                ? VerificationResult(sourceChecksum: "a", destinationChecksum: "a", matches: true,
                                     checksumType: .sha256, processingTime: 0, fileSize: 10)
                : nil,
            processingTime: 0,
            wasReused: wasReused
        )
    }

    /// The first and last copy always report; the ones between wait for
    /// the throttle. The last verify always reports.
    /// Plant: in `RunLedger.recordCopy`, pass `force: false`.
    @Test func firstAndLastAlwaysReport() async {
        let ledger = RunLedger(destinationCount: 1, filesPerDestination: 3, throttle: 60)
        let now = Date()
        #expect(await ledger.recordCopy(row("a"), relativePath: "a", destination: 0, now: now).emit)
        #expect(await !ledger.recordCopy(row("b"), relativePath: "b", destination: 0, now: now).emit)
        #expect(await ledger.recordCopy(row("c"), relativePath: "c", destination: 0, now: now).emit)
        #expect(await !ledger.recordVerify(row("a", verified: true), relativePath: "a", destination: 0, now: now).emit)
        #expect(await !ledger.recordVerify(row("b", verified: true), relativePath: "b", destination: 0, now: now).emit)
        #expect(await ledger.recordVerify(row("c", verified: true), relativePath: "c", destination: 0, now: now).emit)
    }

    /// A verify row replaces the copy row for the same file and backup, and
    /// every count and per-backup total adds up.
    @Test func countsAndRowsAddUp() async {
        let ledger = RunLedger(destinationCount: 2, filesPerDestination: 1, throttle: 0)
        _ = await ledger.recordCopy(row("a"), relativePath: "a", destination: 0, now: Date())
        await ledger.recordCopyFailure(row("b"), relativePath: "b", destination: 1)
        _ = await ledger.recordVerify(row("a", verified: true), relativePath: "a", destination: 0, now: Date())
        let snapshot = await ledger.snapshot()
        #expect(snapshot.filesCopied == 2)
        #expect(snapshot.bytesCopied == 10)
        #expect(snapshot.filesVerified == 1)
        #expect(snapshot.perDestinationCompleted == [1, 1])
        let rows = await ledger.results()
        #expect(rows.count == 2)
        #expect(rows.first?.verificationResult != nil)
    }

    @Test func verifiedResultPreservesEarlierReuseClassification() async {
        let ledger = RunLedger(destinationCount: 1, filesPerDestination: 1, throttle: 0)
        _ = await ledger.recordCopy(
            row("a", wasReused: true),
            relativePath: "a",
            destination: 0,
            now: Date()
        )

        await ledger.record(row("a", verified: true), relativePath: "a", destination: 0)

        let rows = await ledger.results()
        #expect(rows.count == 1)
        #expect(rows[0].outcome == .verified)
        #expect(rows[0].wasReused)
    }

    @Test func laterFailureClearsEarlierReuseClassification() async {
        let ledger = RunLedger(destinationCount: 1, filesPerDestination: 1, throttle: 0)
        _ = await ledger.recordCopy(
            row("a", wasReused: true),
            relativePath: "a",
            destination: 0,
            now: Date()
        )

        await ledger.record(
            row("a", success: false),
            relativePath: "a",
            destination: 0
        )

        let rows = await ledger.results()
        #expect(rows.count == 1)
        #expect(!rows[0].success)
        #expect(!rows[0].wasReused)
    }
}
