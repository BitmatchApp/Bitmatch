import Foundation
import BitMatchEngine

enum CardSafetyTint: Equatable, Sendable {
    case gray
    case blue
    case green
    case amber
    case red
}

enum LiveResultDestinationPolicy {
    /// One backup is already named in the progress header. Rows need a
    /// destination label only when results can belong to different backups.
    static func showsDestinationInEachRow(backupCount: Int) -> Bool {
        backupCount > 1
    }
}

/// One presentation state for a card everywhere BitMatch names its safety.
/// Only `.safeToErase` can be green, claim verified safety, or permit Eject.
enum CardSafetyState: Equatable, Sendable {
    case waiting
    case preparing
    case copying(progress: Int?)
    case verifying(progress: Int?)
    case safeToErase
    case copiedNotVerified
    case needsAttention
    case failed
    case interrupted

    static let invariantSamples: [Self] = [
        .waiting, .preparing, .copying(progress: 42), .verifying(progress: 31),
        .safeToErase, .copiedNotVerified, .needsAttention, .failed, .interrupted,
    ]

    var title: String {
        switch self {
        case .waiting: "Waiting"
        case .preparing: "Preparing"
        case .copying(let progress): Self.progressTitle("Copying", progress: progress)
        case .verifying(let progress): Self.progressTitle("Verifying", progress: progress)
        case .safeToErase: "Safe to erase"
        case .copiedNotVerified: "Copied, not verified"
        case .needsAttention: "Needs attention"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    var symbol: String {
        switch self {
        case .waiting: "clock"
        case .preparing: "hourglass"
        case .copying: "doc.on.doc"
        case .verifying: "checkmark.shield"
        case .safeToErase: "checkmark.circle.fill"
        case .copiedNotVerified: "doc.on.doc"
        case .needsAttention: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .interrupted: "pause.circle.fill"
        }
    }

    var tint: CardSafetyTint {
        switch self {
        case .waiting: .gray
        case .preparing, .copying, .verifying: .blue
        case .safeToErase: .green
        // Amber, like a Quick compare (THESIS decision, 2026-09-25); its
        // symbol and words keep it apart from Needs attention.
        case .copiedNotVerified, .needsAttention, .interrupted: .amber
        case .failed: .red
        }
    }

    var isSafe: Bool { self == .safeToErase }
    var canEject: Bool { isSafe }
    var claimsVerified: Bool { isSafe }
    var isSuccessNotification: Bool { isSafe }

    /// Visible on every finished state that does not prove the source safe.
    /// Active and waiting states use progress wording instead.
    var eraseWarning: String? {
        switch self {
        case .copiedNotVerified, .needsAttention, .failed, .interrupted:
            return "Do not erase the card."
        case .waiting, .preparing, .copying, .verifying, .safeToErase:
            return nil
        }
    }

    func headline(cardName: String) -> String {
        let cardStart = cardName.isEmpty ? "The card" : cardName
        let card = cardName.isEmpty ? "the card" : cardName
        switch self {
        case .waiting: return "\(cardStart) is waiting"
        case .preparing: return "Preparing \(card)"
        case .copying: return "Copying \(card)"
        case .verifying: return "Verifying \(card)"
        case .safeToErase: return "\(cardStart) is safe to erase"
        case .copiedNotVerified: return "\(cardStart) copied, not verified"
        case .needsAttention: return "\(cardStart) needs attention"
        case .failed: return "Transfer failed"
        case .interrupted: return "Transfer interrupted — \(card) is not safe to erase"
        }
    }

    static func make(state: OperationState, verdict: CompletionVerdict, progress: Double? = nil) -> Self {
        let percent = progress.map { Int((min(max($0, 0), 1) * 100).rounded(.down)) }
        switch state {
        case .idle, .notStarted: return .waiting
        case .inProgress, .resuming: return .preparing
        case .copying, .paused: return .copying(progress: percent)
        case .verifying: return .verifying(progress: percent)
        case .cancelled: return .interrupted
        case .failed: return .failed
        case .completed:
            switch verdict {
            case .success: return .safeToErase
            case .copiedNotVerified: return .copiedNotVerified
            case .issues: return .needsAttention
            case .failed: return .failed
            }
        }
    }

    private static func progressTitle(_ title: String, progress: Int?) -> String {
        progress.map { "\(title) \($0)%" } ?? title
    }
}

struct ResultIntegritySummary {
    let successfulRows: [ResultRow]
    let issueRows: [ResultRow]

    init(rows: [ResultRow]) {
        successfulRows = rows.filter(\.isSuccessStatus)
        issueRows = rows.filter { !$0.isSuccessStatus }
    }

    var isSuccessful: Bool {
        issueRows.isEmpty
    }
}

struct ResultIssueGroup: Identifiable {
    let status: String
    let rows: [ResultRow]

    var id: String { status }
}

struct ReportResultStatistics {
    let totalFiles: Int
    let totalBytes: Int64
    let averageFileSizeBytes: Int64?
    let largestFile: ResultRow?
    let smallestFile: ResultRow?
    let extensionCounts: [String: Int]

    init(rows: [ResultRow]) {
        totalFiles = rows.count
        totalBytes = rows.reduce(into: Int64(0)) { total, row in
            let (sum, overflow) = total.addingReportingOverflow(max(0, row.size))
            total = overflow ? .max : sum
        }
        averageFileSizeBytes = rows.isEmpty ? nil : totalBytes / Int64(rows.count)
        largestFile = rows.max { $0.size < $1.size }
        smallestFile = rows.min { $0.size < $1.size }
        extensionCounts = Dictionary(grouping: rows) { row in
            let fileExtension = URL(fileURLWithPath: row.path).pathExtension.uppercased()
            return fileExtension.isEmpty ? "—" : fileExtension
        }.mapValues(\.count)
    }

    func filesPerSecond(duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return Double(totalFiles) / duration
    }

    func extensionBreakdown(limit: Int) -> [(ext: String, count: Int)] {
        guard limit > 0 else { return [] }
        let counts: [(ext: String, count: Int)] = extensionCounts.map {
            (ext: $0.key, count: $0.value)
        }
        let ranked = counts.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.ext < rhs.ext : lhs.count > rhs.count
        }
        return Array(ranked.prefix(limit))
    }
}

enum CompletionVerdict: Equatable {
    case success
    /// Every row copied and none failed, but nothing was checksum-verified
    /// (Quick mode). Never green, never "safe to erase" — but also not an
    /// "issue" to review, since nothing actually went wrong.
    case copiedNotVerified
    case issues
    case failed

    static func resolve(
        state: OperationState,
        rows: [ResultRow],
        hasErrors: Bool,
        hasCriticalErrors: Bool
    ) -> CompletionVerdict {
        if hasCriticalErrors || state == .failed {
            return .failed
        }

        let summary = ResultIntegritySummary(rows: rows)
        guard case .completed(let info) = state else {
            return .issues
        }

        // Quick mode that copied everything cleanly: the engine never calls
        // it a success, but it is not an issue either.
        if info.copiedNotVerified, !info.success, summary.isSuccessful, !hasErrors {
            return .copiedNotVerified
        }

        if !info.success || !summary.isSuccessful || hasErrors {
            return .issues
        }

        // Green means verified (Promise 2): a row that was copied but never
        // checksum- or byte-verified keeps the run out of success, whatever
        // the run itself reported.
        let successRows = summary.successfulRows
        let copiedNotVerifiedRows = successRows.filter {
            ResultOutcome(statusText: $0.status) == .copiedUnverified
        }
        guard !copiedNotVerifiedRows.isEmpty else {
            return .success
        }
        // A run where every row is copied-not-verified is Quick mode; a run
        // where only some rows are is an inconsistent result worth review.
        return copiedNotVerifiedRows.count == successRows.count ? .copiedNotVerified : .issues
    }
}

enum ResultPresentation {
    static let incompleteClipExplanation = "the camera may have stopped recording early. The copies match the card."

    static func incompleteClipAdvisory(_ rows: [ResultRow]) -> String? {
        let clipPaths = Set(rows.compactMap { row in
            let name = URL(fileURLWithPath: row.path).lastPathComponent
            return row.clipIntegrity == .incomplete && !name.hasPrefix("._") ? row.path : nil
        })
        guard !clipPaths.isEmpty else { return nil }
        let subject = clipPaths.count == 1 ? "1 clip looks incomplete" : "\(clipPaths.count) clips look incomplete"
        return "\(subject) — \(incompleteClipExplanation)"
    }

    /// Human wording only. These groups never change verification or retry
    /// behavior; they give a failed media file the sidecar context a person
    /// needs when reviewing the finish screen or report.
    static func clipFailureDescriptions(_ rows: [ResultRow]) -> [String] {
        var seenPaths = Set<String>()
        var candidates: [URL] = []
        candidates.reserveCapacity(rows.count)
        for row in rows where seenPaths.insert(row.path).inserted {
            candidates.append(URL(fileURLWithPath: row.path))
        }
        var failedPaths = Set<String>()
        for row in rows where !row.isSuccessStatus {
            failedPaths.insert(row.path)
        }

        var descriptions: [String] = []
        descriptions.reserveCapacity(failedPaths.count)
        for path in failedPaths.sorted() {
            guard let group = ClipGrouping.group(
                containing: URL(fileURLWithPath: path), among: candidates
            ) else { continue }
            let count = group.files.count
            let names = group.files.map { $0.lastPathComponent }.joined(separator: ", ")
            descriptions.append("Clip \(group.name) failed (\(count) \(count == 1 ? "file" : "files")): \(names)")
        }
        return Array(Set(descriptions)).sorted()
    }

    static func automaticReportNotes(_ rows: [ResultRow]) -> [String] {
        [incompleteClipAdvisory(rows)].compactMap { $0 } + clipFailureDescriptions(rows)
    }

    /// The backup drive shown in a file row. A path under `/Volumes` names
    /// the volume; other locations use the label recorded by the engine.
    static func destinationDriveName(
        for row: ResultRow,
        destinationRoots: [URL] = [],
        destinationNames: [String] = []
    ) -> String? {
        if let path = row.destinationPath {
            let url = URL(fileURLWithPath: path)
            if let mountedVolume = DestinationVolumeLabel.mountedVolumeName(for: url) {
                return mountedVolume
            }
            let comparablePath = ResultPathMatch.comparablePath(path)
            let indexedRoots = destinationRoots.enumerated()
                .map { (index: $0.offset, path: ResultPathMatch.comparablePath($0.element.path)) }
                .sorted { $0.path.count > $1.path.count }
            if let match = indexedRoots.first(where: {
                comparablePath == $0.path || comparablePath.hasPrefix($0.path + "/")
            }) {
                if destinationNames.indices.contains(match.index), !destinationNames[match.index].isEmpty {
                    return destinationNames[match.index]
                }
                return DestinationVolumeLabel.name(for: destinationRoots[match.index])
            }
        }
        return row.destination.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func mediaRows(
        _ rows: [ResultRow],
        allowedExtensions: Set<String>
    ) -> [ResultRow] {
        let normalizedExtensions = Set(allowedExtensions.map { $0.uppercased() })
        return rows.filter { row in
            let fileExtension = URL(fileURLWithPath: row.path).pathExtension.uppercased()
            return !fileExtension.isEmpty && normalizedExtensions.contains(fileExtension)
        }
    }

    static func issueGroups(_ rows: [ResultRow]) -> [ResultIssueGroup] {
        let issues = ResultIntegritySummary(rows: rows).issueRows
        return Dictionary(grouping: issues, by: \.status)
            .map { ResultIssueGroup(status: $0.key, rows: $0.value) }
            .sorted { $0.status < $1.status }
    }

    static func visibleRows(
        _ rows: [ResultRow],
        issuesOnly: Bool,
        limit: Int
    ) -> [ResultRow] {
        let safeLimit = max(0, limit)
        guard safeLimit > 0 else { return [] }

        let summary = ResultIntegritySummary(rows: rows)
        let visibleIssues = Array(summary.issueRows.prefix(safeLimit))
        guard !issuesOnly, visibleIssues.count < safeLimit else {
            return visibleIssues
        }

        let remainingCapacity = safeLimit - visibleIssues.count
        let newestSuccesses = summary.successfulRows.suffix(remainingCapacity)
        return visibleIssues + newestSuccesses
    }
}

/// A backup's stable display name. Filesystem metadata is resolved when the
/// selection changes, then the resulting string is reused while progress
/// ticks rebuild their rows.
enum DestinationVolumeLabel {
    static func resolve(for destination: URL) -> String {
        let volumeName = try? destination.resourceValues(forKeys: [.volumeNameKey]).volumeName
        return name(for: destination, volumeName: volumeName)
    }

    /// Pure counterpart used by presentation and tests. `volumeName` is a
    /// previously resolved label for internal, network or security-scoped
    /// locations; inaccessible locations safely fall back to the folder.
    static func name(for destination: URL, volumeName: String? = nil) -> String {
        if let mountedVolume = mountedVolumeName(for: destination) {
            return mountedVolume
        }
        if let volumeName, !volumeName.isEmpty {
            return volumeName
        }
        return destination.lastPathComponent.isEmpty ? destination.path : destination.lastPathComponent
    }

    /// Only `/Volumes/<name>` is a mounted-volume path. A folder such as
    /// `/Users/mike/Volumes/Project` is an ordinary folder hierarchy.
    static func mountedVolumeName(for url: URL) -> String? {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes" else { return nil }
        return components[2]
    }
}

/// Summaries describe retained result evidence, never infer completion from an empty list.
struct DestinationResultSummary: Identifiable {
    let id: String
    let title: String
    let rows: [ResultRow]

    var issueCount: Int { rows.filter { !$0.isSuccessStatus && ResultOutcome(statusText: $0.status) != .excludedAppleDouble }.count }
    var excludedCount: Int { rows.filter { ResultOutcome(statusText: $0.status) == .excludedAppleDouble }.count }
    var unverifiedCount: Int { rows.filter { $0.isSuccessStatus && ($0.checksum?.isEmpty != false || $0.status.contains("Copied")) }.count }
    var needsAttention: Bool { rows.isEmpty || issueCount > 0 || unverifiedCount > 0 || excludedCount > 0 }
    var detail: String {
        guard !rows.isEmpty else { return "No files recorded" }
        if issueCount > 0 { return issueCount == 1 ? "1 file failed" : "\(issueCount) files failed" }
        if excludedCount > 0 {
            let verified = rows.filter(\.isVerifiedStatus).count
            return "\(verified) verified, \(unverifiedCount) unverified, \(excludedCount) intentionally excluded"
        }
        if unverifiedCount > 0 {
            return unverifiedCount == rows.count
                ? "Sizes matched for \(rows.count) \(rows.count == 1 ? "file" : "files"), not verified"
                : "\(unverifiedCount) of \(rows.count) files not verified"
        }
        return "Checksums matched for \(rows.count) of \(rows.count) files"
    }

    static func make(rows: [ResultRow], destinations: [URL]) -> [Self] {
        // Compare resolved paths: `/var/...` and `/private/var/...` are the
        // same folder, and a mismatch would list the backup's rows elsewhere.
        let resolved = ResultPathMatch.comparablePath
        let roots = destinations
            .map { (original: $0.path, resolved: resolved($0.path)) }
            .sorted { $0.resolved.count > $1.resolved.count }
        var assigned: [String: [ResultRow]] = [:]
        var remaining: [ResultRow] = []
        for row in rows {
            if let path = row.destinationPath.map(resolved),
               let root = roots.first(where: { path == $0.resolved || path.hasPrefix($0.resolved + "/") }) {
                assigned[root.original, default: []].append(row)
            } else {
                remaining.append(row)
            }
        }
        var summaries = destinations.map { root in
            Self(id: root.path, title: root.lastPathComponent, rows: assigned[root.path] ?? [])
        }
        let groups = Dictionary(grouping: remaining) { $0.destination ?? "Other results" }
        summaries += groups.keys.sorted().map { name in
            Self(id: "reported:" + name, title: name, rows: groups[name] ?? [])
        }
        return summaries
    }
}
