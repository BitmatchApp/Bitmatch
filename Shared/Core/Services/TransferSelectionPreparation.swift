import Foundation
import BitMatchEngine

/// A selection-derived snapshot. URLs remain in the composer on MainActor;
/// these values are prepared off-main and accepted only by a matching caller.
/// Filesystem work associated with a user's current folder selection. Call
/// this through DriveAccessWorker so a stalled mount cannot block the UI or
/// create an unbounded number of concurrent filesystem jobs.
enum TransferSelectionPreparation {
    struct Prepared: Sendable {
        let sourceIdentity: LocalTransferResource?
        let destinationIdentities: [URL: LocalTransferResource]
        let orderedDestinationIdentities: [LocalTransferResource]
        let destinationNames: [String]
        var destinationCapacities: [URL: SetupLocationsPresentation.Capacity] = [:]
    }

    static func prepare(
        source: URL?,
        destinations: [URL],
        sourceIdentity: LocalTransferResource?,
        destinationIdentities: [URL: LocalTransferResource]
    ) throws -> Prepared {
        try Task.checkCancellation()
        let selectedURLs = ([source].compactMap { $0 }) + destinations
        let scopedURLs = selectedURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

        let preparedSource: LocalTransferResource?
        if let source {
            if sourceIdentity?.url == source {
                try sourceIdentity?.validateIdentity(at: source)
                preparedSource = sourceIdentity
            } else {
                preparedSource = try LocalTransferResource(url: source)
            }
        } else {
            preparedSource = nil
        }

        var preparedDestinations: [URL: LocalTransferResource] = [:]
        var orderedIdentities: [LocalTransferResource] = []
        var names: [String] = []
        var capacities: [URL: SetupLocationsPresentation.Capacity] = [:]
        for destination in destinations {
            try Task.checkCancellation()
            let identity: LocalTransferResource
            if let existing = destinationIdentities[destination], existing.url == destination {
                try existing.validateIdentity(at: destination)
                identity = existing
            } else {
                identity = try LocalTransferResource(url: destination)
            }
            preparedDestinations[destination] = identity
            orderedIdentities.append(identity)
            names.append(DestinationVolumeLabel.resolve(for: destination))
            capacities[destination] = SetupLocationsPresentation.capacity(for: destination)
        }

        return Prepared(
            sourceIdentity: preparedSource,
            destinationIdentities: preparedDestinations,
            orderedDestinationIdentities: orderedIdentities,
            destinationNames: names, destinationCapacities: capacities
        )
    }

    /// Revalidates the prepared identities and performs admission checks while
    /// their security scopes remain active. The caller must pass these same
    /// resources to the journal commit after this succeeds.
    static func validate(
        sourceIdentity: LocalTransferResource,
        destinationIdentities: [LocalTransferResource],
        settings: CameraLabelSettings,
        requireNonempty: Bool
    ) throws {
        let source = sourceIdentity.url
        let destinations = destinationIdentities.map(\.url)
        let selectedURLs = [source] + destinations
        let scopedURLs = selectedURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

        try Task.checkCancellation()
        try sourceIdentity.validateIdentity(at: source)
        for (identity, destination) in zip(destinationIdentities, destinations) {
            try Task.checkCancellation()
            try identity.validateIdentity(at: destination)
        }
        if let refusal = destinations.lazy.compactMap({
            BackupTargetPolicy.refusal(for: $0, origin: .userChoice, source: source)
        }).first {
            throw FileOperationError.unsafeOperation(refusal)
        }
        try SafetyValidator.validateResolvedDestinationRoots(
            source: source,
            destinations: destinations,
            settings: settings
        )
        if requireNonempty {
            guard try CardSource.containsRegularFile(base: source) else {
                throw FileOperationError.unsafeOperation("Source folder is empty. Choose a source that contains files.")
            }
        }
    }
}
