import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct TransferSelectionPreparationTests {
    @Test func preparationRetainsUnchangedIdentitiesAndDestinationOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitMatchSelectionPreparation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        let firstDestination = root.appendingPathComponent("first", isDirectory: true)
        let secondDestination = root.appendingPathComponent("second", isDirectory: true)
        for url in [source, firstDestination, secondDestination] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let originalSource = try LocalTransferResource(url: source)
        let originalFirstDestination = try LocalTransferResource(url: firstDestination)
        let prepared = try TransferSelectionPreparation.prepare(
            source: source,
            destinations: [firstDestination, secondDestination],
            sourceIdentity: originalSource,
            destinationIdentities: [firstDestination: originalFirstDestination]
        )

        #expect(prepared.sourceIdentity?.bookmark == originalSource.bookmark)
        #expect(prepared.destinationIdentities[firstDestination]?.bookmark == originalFirstDestination.bookmark)
        #expect(prepared.orderedDestinationIdentities.map(\.url) == [firstDestination, secondDestination])
        #expect(prepared.destinationNames.count == 2)
    }

    @Test func admissionValidationRejectsSamePathSourceReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BitMatchSelectionIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        let original = root.appendingPathComponent("original-source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        for url in [source, destination] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let sourceIdentity = try LocalTransferResource(url: source)
        let destinationIdentity = try LocalTransferResource(url: destination)

        try FileManager.default.moveItem(at: source, to: original)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try TransferSelectionPreparation.validate(
                sourceIdentity: sourceIdentity,
                destinationIdentities: [destinationIdentity],
                settings: CameraLabelSettings(),
                requireNonempty: false
            )
        }
    }
}
