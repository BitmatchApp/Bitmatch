import Foundation

/// Permission to advance a queue, never permission to erase the whole card.
/// Missing or unknown saved values do not establish this qualification.
public enum ExpectedExclusionQueueQualification: Codable, Equatable, Sendable {
    case ordinaryTransfer
    case projectTransfer(projectID: UUID, cardID: UUID)
}

public extension TransferCompletion {
    /// Called only after authoritative-plan acceptance and the final requested
    /// handoffs. Classifier provenance comes from the actual pipeline, not a
    /// result's status text or a completion summary.
    static func expectedExclusionQueueQualification(
        operation: FileOperation,
        expectedMode: VerificationMode,
        handoffIssues: [String],
        reportIssue: String?,
        project: ProjectGate
    ) -> ExpectedExclusionQueueQualification? {
        guard operation.verificationMode == expectedMode, expectedMode != .quick,
              operation.endTime != nil,
              operation.sourceFingerprint?.isEmpty == false,
              let reviewed = operation.reviewedAppleDoubleExclusionPaths,
              !reviewed.isEmpty,
              let requested = operation.settings.excludedAppleDoublePaths,
              reviewed.count == requested.count,
              Set(reviewed).count == reviewed.count,
              Set(reviewed) == Set(requested),
              let manifest = operation.sourceManifest,
              project.permitsExpectedExclusionQueueContinuation,
              handoffIssues.isEmpty, reportIssue == nil,
              operation.results.allSatisfy({ result in
                  result.error == nil && (result.excludedAppleDouble
                    || (result.success && result.verificationResult?.isValid == true))
              }) else { return nil }
        let sourcePaths = manifest.map { PathContainment.comparablePath($0.path) }
        guard Set(sourcePaths).count == sourcePaths.count,
              let expected = selectedSourcePaths(
                source: operation.sourceURL, reviewedRelativePaths: reviewed,
                fullSourcePaths: Set(sourcePaths)
              ), !expected.isEmpty else { return nil }
        let counts = Array(repeating: expected.count, count: operation.destinationURLs.count)
        guard exactExpectedExclusionRows(
            rows: rows(from: operation), source: operation.sourceURL,
            destinations: operation.destinationURLs, settings: operation.settings,
            plannedFileCounts: counts, expectedSelectedSourcePaths: expected
        ) else { return nil }
        return project.expectedExclusionQueueIdentity
    }

    /// Pure saved-evidence checks: no bookmarks, file reads or mounted-media
    /// dependency. The final persisted qualification attests the classifier
    /// and handoff gates; this rechecks its exact row/selection scope.
    internal static func exactExpectedExclusionRows(
        rows: [ResultRow], source: URL, destinations: [URL],
        settings: CameraLabelSettings, plannedFileCounts: [Int],
        expectedSelectedSourcePaths: Set<String>? = nil
    ) -> Bool {
        guard !rows.isEmpty, !destinations.isEmpty,
              plannedFileCounts.count == destinations.count,
              plannedFileCounts.allSatisfy({ $0 > 0 }),
              let reviewed = settings.excludedAppleDoublePaths,
              !reviewed.isEmpty,
              Set(reviewed).count == reviewed.count else { return false }
        let sourcePath = PathContainment.comparablePath(source.path)
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        guard let excluded = excludedSourcePaths(source: source, reviewedRelativePaths: reviewed) else { return false }
        let roots = destinations.map {
            PathContainment.comparablePath(SafetyValidator.resolvedDestinationRoot(
                source: source, destination: $0, settings: settings
            ).path)
        }
        guard Set(roots).count == roots.count else { return false }
        for first in roots.indices {
            for second in roots.indices where second > first {
                guard !PathContainment.isWithin(roots[first], root: roots[second]),
                      !PathContainment.isWithin(roots[second], root: roots[first]) else { return false }
            }
        }
        var selectedByDestination = Array(repeating: Set<String>(), count: roots.count)
        var excludedByDestination = Array(repeating: Set<String>(), count: roots.count)
        for row in rows {
            let path = PathContainment.comparablePath(row.path)
            guard path.hasPrefix(sourcePrefix),
                  let destinationPath = row.destinationPath else { return false }
            let relative = String(path.dropFirst(sourcePrefix.count))
            guard !relative.isEmpty else { return false }
            let destination = PathContainment.comparablePath(destinationPath)
            let matching = roots.indices.filter { destination == roots[$0] + "/" + relative }
            guard matching.count == 1, let index = matching.first else { return false }
            if ResultOutcome(statusText: row.status) == .excludedAppleDouble {
                guard excluded.contains(path), excludedByDestination[index].insert(path).inserted else { return false }
            } else {
                guard row.isVerifiedStatus, !excluded.contains(path),
                      selectedByDestination[index].insert(path).inserted else { return false }
            }
        }
        guard let selected = selectedByDestination.first, !selected.isEmpty,
              expectedSelectedSourcePaths == nil || selected == expectedSelectedSourcePaths else { return false }
        return roots.indices.allSatisfy {
            selectedByDestination[$0] == selected
                && selectedByDestination[$0].count == plannedFileCounts[$0]
                && excludedByDestination[$0] == excluded
        }
    }

    private static func excludedSourcePaths(source: URL, reviewedRelativePaths: [String]) -> Set<String>? {
        guard !reviewedRelativePaths.isEmpty,
              Set(reviewedRelativePaths).count == reviewedRelativePaths.count else { return nil }
        let sourcePath = PathContainment.comparablePath(source.path)
        let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        var excluded = Set<String>()
        for relative in reviewedRelativePaths {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !relative.hasPrefix("/"), !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  parts.last?.hasPrefix("._") == true else { return nil }
            let path = PathContainment.comparablePath(source.appendingPathComponent(relative).path)
            guard path.hasPrefix(prefix), excluded.insert(path).inserted else { return nil }
        }
        return excluded
    }

    private static func selectedSourcePaths(
        source: URL, reviewedRelativePaths: [String], fullSourcePaths: Set<String>
    ) -> Set<String>? {
        guard let excluded = excludedSourcePaths(source: source, reviewedRelativePaths: reviewedRelativePaths),
              excluded.isSubset(of: fullSourcePaths) else { return nil }
        return fullSourcePaths.subtracting(excluded)
    }
}
