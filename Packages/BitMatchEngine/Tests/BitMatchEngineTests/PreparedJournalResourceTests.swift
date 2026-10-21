import Foundation
import XCTest
@testable import BitMatchEngine

final class PreparedJournalResourceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let journal: TransferJournal

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("prepared-journal-resource-\(UUID())", isDirectory: true)
            source = root.appendingPathComponent("reader/NO NAME", isDirectory: true)
            destination = root.appendingPathComponent("Backup", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            journal = TransferJournal(fileURL: root.appendingPathComponent("journal.json"))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func testPreparedEnqueuePersistsSuppliedBookmarksAndOriginalIdentities() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try LocalTransferResource(url: fixture.source)
        let destination = try LocalTransferResource(url: fixture.destination)

        let id = try fixture.journal.enqueue(
            source: source,
            destinations: [destination],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs()
        )

        let saved = try XCTUnwrap(fixture.journal.records.first { $0.id == id })
        XCTAssertEqual(saved.source.bookmark, source.bookmark)
        XCTAssertEqual(saved.source.volumeID, source.volumeID)
        XCTAssertEqual(saved.source.resourceID, source.resourceID)
        XCTAssertEqual(saved.source.creationDate, source.creationDate)
        XCTAssertEqual(saved.destinations.map(\.bookmark), [destination.bookmark])
        XCTAssertEqual(saved.destinations.map(\.volumeID), [destination.volumeID])
        XCTAssertEqual(saved.destinations.map(\.resourceID), [destination.resourceID])
        XCTAssertEqual(saved.destinations.map(\.creationDate), [destination.creationDate])
    }

    func testPreparedQueuedReplacementRejectsSamePathIdentityChangesWithoutChangingRecord() throws {
        for replaceSource in [true, false] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let source = try LocalTransferResource(url: fixture.source)
            let destination = try LocalTransferResource(url: fixture.destination)
            let id = try fixture.journal.enqueue(
                source: source,
                destinations: [destination],
                verificationMode: .standard,
                cameraSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs()
            )
            let before = try XCTUnwrap(fixture.journal.records.first { $0.id == id })
            let originalPath = replaceSource ? fixture.source : fixture.destination
            try FileManager.default.moveItem(
                at: originalPath,
                to: fixture.root.appendingPathComponent("original-selected-folder", isDirectory: true)
            )
            try FileManager.default.createDirectory(at: originalPath, withIntermediateDirectories: true)

            XCTAssertThrowsError(try fixture.journal.replaceQueued(
                id: id,
                source: source,
                destinations: [destination],
                verificationMode: .thorough,
                cameraSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs(),
                generateASCMHL: false
            ), replaceSource ? "A replacement source at the same path must be rejected" :
                "A replacement destination at the same path must be rejected")

            let after = try XCTUnwrap(fixture.journal.records.first { $0.id == id })
            XCTAssertEqual(try canonical(after), try canonical(before))
        }
    }

    func testPreparedReadOperationsRejectAChangedJournalResourceSnapshot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = try LocalTransferResource(url: fixture.source)
        let destination = try LocalTransferResource(url: fixture.destination)
        let id = try fixture.journal.enqueue(
            source: source,
            destinations: [destination],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs()
        )
        let replacementSource = fixture.root.appendingPathComponent("reader-b/NO NAME", isDirectory: true)
        let replacementDestination = fixture.root.appendingPathComponent("Backup Two", isDirectory: true)
        try FileManager.default.createDirectory(at: replacementSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementDestination, withIntermediateDirectories: true)
        try fixture.journal.replaceQueued(
            id: id,
            sourceURL: replacementSource,
            destinationURLs: [replacementDestination],
            verificationMode: .standard,
            cameraSettings: CameraLabelSettings(),
            reportSettings: ReportPrefs(),
            generateASCMHL: true
        )
        let expectedResources = [source, destination]

        XCTAssertThrowsError(try fixture.journal.prepareToRun(id: id, expectedResources: expectedResources)) { error in
            guard let journalError = error as? LocalTransferJournalError,
                  case .invalidState = journalError else {
                return XCTFail("Expected a changed resource snapshot to be rejected before resolution, got \(error)")
            }
        }
        XCTAssertThrowsError(try fixture.journal.prepareSourceForEjection(id: id, expectedResources: expectedResources)) { error in
            guard let journalError = error as? LocalTransferJournalError,
                  case .invalidState = journalError else {
                return XCTFail("Expected a changed resource snapshot to be rejected before resolution, got \(error)")
            }
        }
        XCTAssertThrowsError(try fixture.journal.staleResourceIndexes(id: id, expectedResources: expectedResources)) { error in
            guard let journalError = error as? LocalTransferJournalError,
                  case .invalidState = journalError else {
                return XCTFail("Expected a changed resource snapshot to be rejected before resolution, got \(error)")
            }
        }
        XCTAssertEqual(fixture.journal.records.first?.source.url, replacementSource)
        XCTAssertEqual(fixture.journal.records.first?.destinations.map(\.url), [replacementDestination])
    }

    private func canonical(_ record: LocalTransferRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(record)
    }
}
