import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

@MainActor
struct TransferRunResultsTests {
    private func row(_ path: String = "/Card/clip.bin", destination: String? = "/Backup/Card/clip.bin", status: String = "copied") -> ResultRow {
        ResultRow(path: path, status: status, size: 1, checksum: nil, destination: "Backup", destinationPath: destination)
    }

    @Test func copyThenVerifyReplacesTheSameResultInArrivalOrder() {
        let store = TransferRunResults()
        store.upsert(row())
        store.upsert(row("/Card/second.bin"))
        store.upsert(row(status: "verified"))
        #expect(store.rows.map(\.path) == ["/Card/clip.bin", "/Card/second.bin"])
        #expect(store.rows.map(\.status) == ["verified", "copied"])
    }

    @Test func destinationsAreExactKeysIncludingNilEmptyAndCase() {
        let store = TransferRunResults()
        for destination in [nil, "", "/Backup/clip.bin", "/backup/clip.bin", "/Second/clip.bin"] as [String?] {
            store.upsert(row(destination: destination))
        }
        store.upsert(row(destination: nil, status: "verified"))
        #expect(store.rows.count == 5)
        #expect(store.rows.map(\.destinationPath) == [nil, "", "/Backup/clip.bin", "/backup/clip.bin", "/Second/clip.bin"])
        #expect(store.rows.map(\.status) == ["verified", "copied", "copied", "copied", "copied"])
    }

    @Test func replacementRebuildsTheIndexAndKeepsFirstDuplicateSemantics() {
        let store = TransferRunResults()
        store.upsert(row("/old"))
        store.replace(with: [row("/second"), row(status: "first duplicate"), row(status: "second duplicate")])
        store.upsert(row(status: "verified"))
        #expect(store.rows.map(\.path) == ["/second", "/Card/clip.bin", "/Card/clip.bin"])
        #expect(store.rows.map(\.status) == ["copied", "verified", "second duplicate"])
        store.upsert(row("/old", status: "appended"))
        #expect(store.rows.count == 4)
        #expect(store.rows.last?.status == "appended")
    }

    @Test func clearingReplacementDropsEveryStaleIndex() {
        let store = TransferRunResults()
        store.upsert(row())
        store.replace(with: [])
        store.upsert(row(status: "new attempt"))
        #expect(store.rows.count == 1)
        #expect(store.rows[0].status == "new attempt")
    }
}
