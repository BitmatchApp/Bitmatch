import Foundation
import BitMatchEngine

/// Keep older Quick rows' original status in the journal, but present their
/// successful copy as unverified everywhere a person reads it.
enum TransferHistoryResultPresentation {
    static func statusText(for row: ResultRow, mode: VerificationMode) -> String {
        if mode == .quick && row.isSuccessStatus {
            return "Copied · contents not verified"
        }
        if row.recopyOutcome == "recovered" {
            return row.status + " · recovered after one re-copy (first copy failed verification)"
        }
        let reasonNote = row.failureReason
            .flatMap(ResultFailureReason.init(rawValue:))
            .map { " · " + $0.rowNote } ?? ""
        let recopy = row.recopyOutcome == "stillFailed" ? " · re-copy also failed" : ""
        guard let note = row.markingNote else { return row.status + recopy + reasonNote }
        return row.status + " · " + note + recopy + reasonNote
    }
}

/// What History shows for each journal record, and which records raise the
/// "review in History" banner on Mac, iPad and iPhone.
/// Pure values, so every platform shows the same state the same way.
enum TransferLibraryPresentation {

    struct SearchMatch: Identifiable, Sendable {
        let record: LocalTransferRecord
        let clipLine: String?

        var id: UUID { record.id }
    }

    /// Derived clip text and destination states. The History model builds this
    /// only for a nonempty search and reuses it within that journal snapshot.
    struct SearchIndex: Sendable {
        private enum BuildError: Error { case duplicateRecordID }

        private enum DestinationState: Int, Sendable {
            case verified
            case notVerified
            case excluded
            case failed

            init(_ row: ResultRow, mode: VerificationMode) {
                if ResultOutcome(statusText: row.status) == .excludedAppleDouble { self = .excluded }
                else if !row.isSuccessStatus { self = .failed }
                else if mode == .quick { self = .notVerified }
                else if row.isVerifiedStatus { self = .verified }
                else { self = .notVerified }
            }
        }

        private struct Clip: Sendable {
            let name: String
            let lowercaseName: String
            let lowercaseRelativePath: String
            var destinationStates: [String: DestinationState]
            var destinationOrder: [String]
        }

        private let clipsByRecordID: [UUID: [Clip]]

        init(records: [LocalTransferRecord]) {
            clipsByRecordID = Self.buildClips(records: records, checkCancellation: {}, onRowVisited: nil)
        }

        /// The History worker never publishes a partial index. The optional
        /// checkpoint lets tests suspend inside the real loop without sleeps.
        static func cancellable(
            records: [LocalTransferRecord],
            onRowVisited: (@Sendable () -> Void)? = nil
        ) throws -> SearchIndex {
            var recordIDs: Set<UUID> = []
            for record in records {
                try Task.checkCancellation()
                guard recordIDs.insert(record.id).inserted else {
                    // A malformed journal must not attach one attempt's clip
                    // text to another attempt sharing its identifier.
                    throw BuildError.duplicateRecordID
                }
            }
            let clips = try buildClips(
                records: records,
                checkCancellation: { try Task.checkCancellation() },
                onRowVisited: onRowVisited
            )
            return SearchIndex(clipsByRecordID: clips)
        }

        private init(clipsByRecordID: [UUID: [Clip]]) {
            self.clipsByRecordID = clipsByRecordID
        }

        private static func buildClips(
            records: [LocalTransferRecord],
            checkCancellation: () throws -> Void,
            onRowVisited: (@Sendable () -> Void)?
        ) rethrows -> [UUID: [Clip]] {
            try checkCancellation()
            var indexed: [UUID: [Clip]] = [:]
            for record in records {
                try checkCancellation()
                let destinationNames = DestinationIdentityPresentation.nameMap(
                    for: record.destinations.map(\.url)
                )
                var clips: [String: Clip] = [:]
                var order: [String] = []

                for row in record.results {
                    try checkCancellation()
                    onRowVisited?()
                    let relativePath = Self.relativePath(row.path, under: record.source.url)
                    let key = relativePath.lowercased()
                    let destination = DestinationIdentityPresentation.resultDriveName(
                        for: row,
                        destinationNames: destinationNames
                    ) ?? "Destination"
                    let state = DestinationState(row, mode: record.verificationMode)
                    if clips[key] == nil {
                        clips[key] = Clip(
                            name: row.fileName,
                            lowercaseName: row.fileName.lowercased(),
                            lowercaseRelativePath: key,
                            destinationStates: [:],
                            destinationOrder: []
                        )
                        order.append(key)
                    }
                    if clips[key]?.destinationStates[destination] == nil {
                        clips[key]?.destinationOrder.append(destination)
                    }
                    let existing = clips[key]?.destinationStates[destination] ?? .verified
                    clips[key]?.destinationStates[destination] = existing.rawValue >= state.rawValue ? existing : state
                }
                var ordered: [Clip] = []
                for key in order {
                    try checkCancellation()
                    if let clip = clips[key] { ordered.append(clip) }
                }
                indexed[record.id] = ordered
            }
            try checkCancellation()
            return indexed
        }

        func match(for record: LocalTransferRecord, search: String) -> SearchMatch? {
            match(for: record, search: search, checkCancellation: {}, onClipVisited: nil)
        }

        func cancellableMatch(
            for record: LocalTransferRecord,
            search: String,
            onClipVisited: (@Sendable () -> Void)? = nil
        ) throws -> SearchMatch? {
            try match(
                for: record, search: search,
                checkCancellation: { try Task.checkCancellation() },
                onClipVisited: onClipVisited
            )
        }

        private func match(
            for record: LocalTransferRecord,
            search: String,
            checkCancellation: () throws -> Void,
            onClipVisited: (@Sendable () -> Void)?
        ) rethrows -> SearchMatch? {
            try checkCancellation()
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return SearchMatch(record: record, clipLine: nil) }
            if TransferLibraryPresentation.matchesMetadata(
                lowercaseQuery: query,
                title: record.title,
                summary: record.summary,
                projectName: record.reportSettings.projectName,
                backupNames: record.destinations.map { $0.url.lastPathComponent }
            ) {
                return SearchMatch(record: record, clipLine: nil)
            }

            var first: Clip?
            var count = 0
            for clip in clipsByRecordID[record.id] ?? [] {
                try checkCancellation()
                onClipVisited?()
                if clip.lowercaseName.contains(query) || clip.lowercaseRelativePath.contains(query) {
                    if first == nil { first = clip }
                    count += 1
                }
            }
            try checkCancellation()
            guard let first else { return nil }
            let destinations = first.destinationOrder.map { destination in
                switch first.destinationStates[destination] ?? .failed {
                case .verified: destination
                case .notVerified: "\(destination) (not verified)"
                case .failed: "\(destination) (failed)"
                case .excluded: "\(destination) (intentionally excluded)"
                }
            }
            let destinationText = Self.naturalList(destinations)
            let firstLine = destinationText.isEmpty ? first.name : "\(first.name) on \(destinationText)"
            let remaining = count - 1
            let line: String
            if remaining == 1 { line = "\(firstLine) and 1 more clip" }
            else if remaining > 1 { line = "\(firstLine) and \(remaining) more clips" }
            else { line = firstLine }
            return SearchMatch(record: record, clipLine: line)
        }

        private static func relativePath(_ path: String, under source: URL) -> String {
            let standardizedPath = (path as NSString).standardizingPath
            guard standardizedPath.hasPrefix("/") else {
                return standardizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let sourcePath = source.standardizedFileURL.path
            if standardizedPath == sourcePath { return URL(fileURLWithPath: path).lastPathComponent }
            let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            guard standardizedPath.hasPrefix(prefix) else {
                return URL(fileURLWithPath: standardizedPath).lastPathComponent
            }
            return String(standardizedPath.dropFirst(prefix.count))
        }

        private static func naturalList(_ values: [String]) -> String {
            switch values.count {
            case 0: ""
            case 1: values[0]
            case 2: "\(values[0]) and \(values[1])"
            default: "\(values.dropLast().joined(separator: ", ")), and \(values.last!)"
            }
        }
    }

    struct AttentionNotice: Equatable, Sendable {
        let recordID: UUID
        let title: String
        let detail: String
        let systemImage: String
        let tint: CardSafetyTint
        /// Collapsed History rows never repeat the finish-screen erase
        /// guidance; the pill already carries words, symbol and color.
        let rowDetail: String?
    }

    /// A record's state as a word, a symbol and a tint. Color is never the
    /// only signal, and green belongs only to checksum-verified completion.
    struct StateLabel: Equatable, Sendable {
        let title: String
        let accessibilityLabel: String
        let systemImage: String
        let tint: CardSafetyTint
        /// Collapsed History rows never repeat the finish-screen erase
        /// guidance; the pill already carries words, symbol and color.
        let rowDetail: String?
    }

    static func safetyState(for record: LocalTransferRecord) -> CardSafetyState {
        switch record.state {
        case .queued: return .waiting
        case .running: return .copying(progress: nil)
        case .completed, .issues:
            guard !record.results.isEmpty else { return .needsAttention }
            if record.verificationMode == .quick {
                // Quick journals are always `.issues`: that state alone does
                // not distinguish a clean size-only copy from a failed report.
                // Older records have no explicit verdict, so keep them out of
                // the benign copied-only state rather than hide a real issue.
                guard record.quickOnlyUnverified == true else { return .needsAttention }
                if hasCompleteEvidence(record, where: {
                    ResultOutcome(statusText: $0.status) == .copiedUnverified
                }) {
                    return .copiedNotVerified
                }
                // Quick never verifies file contents, even if a malformed or
                // legacy record carries rows that claim otherwise.
                return .needsAttention
            }
            if record.state == .completed, hasCompleteEvidence(record, where: \.isVerifiedStatus) {
                return .safeToErase
            }
            return .needsAttention
        case .failed: return .failed
        case .interrupted, .cancelled: return .interrupted
        }
    }

    static func stateLabel(for record: LocalTransferRecord) -> StateLabel {
        stateLabel(for: record, hasVerifiedSelectedFiles: TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
    }

    private static func stateLabel(for record: LocalTransferRecord, hasVerifiedSelectedFiles: Bool) -> StateLabel {
        if hasVerifiedSelectedFiles {
            return StateLabel(title: "Selected files verified", accessibilityLabel: "Selected files verified",
                systemImage: "checkmark.circle", tint: .gray, rowDetail: nil)
        }
        return stateLabel(safetyState(for: record))
    }

    /// A collapsed row's label and detail line from one evidence scan set.
    /// `hasVerifiedSelectedFiles` decides both, so computing them separately
    /// scanned every result row twice per row per body pass.
    struct RowPresentation: Equatable, Sendable {
        let stateLabel: StateLabel
        let detailLine: String
    }

    static func rowPresentation(for record: LocalTransferRecord) -> RowPresentation {
        let verified = TransferOutcomePresentation.hasVerifiedSelectedFiles(record)
        return RowPresentation(
            stateLabel: stateLabel(for: record, hasVerifiedSelectedFiles: verified),
            detailLine: detailLine(
                destinationCount: record.destinations.count,
                fileCount: fileCount(for: record, hasVerifiedSelectedFiles: verified)
            )
        )
    }

    private static func stateLabel(_ safetyState: CardSafetyState) -> StateLabel {
        let accessibilityLabel = safetyState == .copiedNotVerified
            ? "Copied, not verified: size check only"
            : safetyState.title
        return StateLabel(
            title: safetyState.title,
            accessibilityLabel: accessibilityLabel,
            systemImage: safetyState.symbol,
            tint: safetyState.tint,
            rowDetail: nil
        )
    }

    private static func hasCompleteEvidence(
        _ record: LocalTransferRecord,
        where accepts: (ResultRow) -> Bool
    ) -> Bool {
        let summaries = DestinationResultSummary.make(
            rows: record.results,
            destinations: record.destinations.map(\.url)
        )
        guard summaries.count == record.destinations.count,
              summaries.allSatisfy({ summary in
                  !summary.rows.isEmpty && summary.rows.allSatisfy(accepts)
                      && Set(summary.rows.map(\.path)).count == summary.rows.count
              }),
              let expectedPaths = summaries.first.map({ Set($0.rows.map(\.path)) }),
              !expectedPaths.isEmpty else { return false }
        // Without the original selected-file plan, matching saved rows cannot
        // establish that every source file was represented. Keep older
        // completed records visible, but do not infer whole-card safety.
        guard let planned = record.plannedFileCounts,
              savedResultsCoverSelectedPlan(
                planned: planned, summaries: summaries,
                destinationCount: record.destinations.count
              ) else { return false }
        return summaries.allSatisfy { Set($0.rows.map(\.path)) == expectedPaths }
    }

    /// A saved plan counts selected source files per destination. Excluded
    /// AppleDouble rows remain in the evidence, but are outside those counts.
    /// Nil preserves the older records for which no selected-file plan exists.
    static func savedResultsCoverSelectedPlan(_ record: LocalTransferRecord) -> Bool? {
        guard let planned = record.plannedFileCounts else { return nil }
        let summaries = DestinationResultSummary.make(rows: record.results, destinations: record.destinations.map(\.url))
        return savedResultsCoverSelectedPlan(
            planned: planned, summaries: summaries, destinationCount: record.destinations.count
        )
    }

    private static func savedResultsCoverSelectedPlan(
        planned: [Int], summaries: [DestinationResultSummary], destinationCount: Int
    ) -> Bool {
        guard !summaries.isEmpty, summaries.count == destinationCount,
              planned.count == summaries.count else { return false }
        let selected = summaries.map { summary in
            summary.rows.filter { ResultOutcome(statusText: $0.status) != .excludedAppleDouble }
        }
        guard zip(selected, planned).allSatisfy({ rows, count in
            rows.count == count && Set(rows.map(\.path)).count == count
        }) else { return false }
        let firstPaths = Set(selected[0].map(\.path))
        return selected.allSatisfy { Set($0.map(\.path)) == firstPaths }
    }

    /// The buttons a record offers. Mirrors the journal's own rules
    /// (`LocalTransferState.canRetry`, project cards retried from their project).
    struct Actions: Equatable, Sendable {
        var removeFromQueue = false
        var reconnect = false
        var retry = false
        var retryWithoutASCMHL = false
        var export = false
        /// Project cards are reviewed and retried in their project, not here.
        var showsProjectReviewNote = false
    }

    static func actions(state: LocalTransferState, isProjectCard: Bool, generateASCMHL: Bool) -> Actions {
        var actions = Actions()
        let canRetry = state.canRetry && !isProjectCard
        if state == .queued {
            actions.removeFromQueue = true
            actions.reconnect = !isProjectCard
        } else if canRetry {
            actions.retry = true
            actions.reconnect = true
            actions.retryWithoutASCMHL = generateASCMHL
        }
        actions.export = state != .queued && state != .running
        actions.showsProjectReviewNote = isProjectCard && state != .completed
        return actions
    }

    static func actions(for record: LocalTransferRecord) -> Actions {
        actions(state: record.state, isProjectCard: record.projectID != nil, generateASCMHL: record.generateASCMHL)
    }

    /// Queue is active work only. Every finished attempt belongs in History.
    static func isVisible(state: LocalTransferState, showHistory: Bool) -> Bool {
        showHistory ? state != .queued && state != .running : state == .queued || state == .running
    }

    /// Case-insensitive match on the card, summary, project and backup folder names.
    static func matches(search: String, title: String, summary: String, projectName: String, backupNames: [String]) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return matchesMetadata(lowercaseQuery: query, title: title, summary: summary,
                               projectName: projectName, backupNames: backupNames)
    }

    private static func matchesMetadata(lowercaseQuery query: String, title: String, summary: String,
                                        projectName: String, backupNames: [String]) -> Bool {
        return ([title, summary, projectName] + backupNames)
            .joined(separator: " ")
            .lowercased()
            .contains(query)
    }

    static func visibleMatches(
        _ records: [LocalTransferRecord],
        showHistory: Bool,
        search: String,
        index: SearchIndex
    ) -> [SearchMatch] {
        records.compactMap { record in
            guard isVisible(state: record.state, showHistory: showHistory) else { return nil }
            return index.match(for: record, search: search)
        }
    }

    static func cancellableVisibleMatches(
        _ records: [LocalTransferRecord],
        search: String,
        index: SearchIndex
    ) throws -> [SearchMatch] {
        var matches: [SearchMatch] = []
        for record in records {
            try Task.checkCancellation()
            guard isVisible(state: record.state, showHistory: true) else { continue }
            if let match = try index.cancellableMatch(for: record, search: search) {
                matches.append(match)
            }
        }
        try Task.checkCancellation()
        return matches
    }

    static func visibleRecords(_ records: [LocalTransferRecord], showHistory: Bool, search: String) -> [LocalTransferRecord] {
        visibleMatches(records, showHistory: showHistory, search: search, index: SearchIndex(records: records))
            .map(\.record)
    }

    static func reviewTargetRecordID(requested: UUID?, visibleRecords: [LocalTransferRecord]) -> UUID? {
        guard let requested, visibleRecords.contains(where: { $0.id == requested }) else { return nil }
        return requested
    }

    static func recent(_ records: [LocalTransferRecord], limit: Int) -> [LocalTransferRecord] {
        guard limit > 0 else { return [] }
        return Array(records
            .filter { $0.state != .queued && $0.state != .running }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit))
    }

    /// The counts shown on the Queue/History segmented control.
    static func tabCounts(_ records: [LocalTransferRecord]) -> (queue: Int, history: Int) {
        let queue = records.filter { $0.state == .queued || $0.state == .running }.count
        return (queue, records.count - queue)
    }

    /// The row's secondary line, next to the date: how many backups and how
    /// many files this transfer covers. Singular/plural for both nouns.
    /// Files on the card, not result rows: each file has one row per
    /// destination, so two destinations showed "38 files" for a 19-file card.
    static func fileCount(for record: LocalTransferRecord) -> Int {
        fileCount(for: record, hasVerifiedSelectedFiles: TransferOutcomePresentation.hasVerifiedSelectedFiles(record))
    }

    private static func fileCount(for record: LocalTransferRecord, hasVerifiedSelectedFiles: Bool) -> Int {
        let rows = hasVerifiedSelectedFiles
            ? record.results.filter { ResultOutcome(statusText: $0.status) != .excludedAppleDouble }
            : record.results
        return Set(rows.map(\.path)).count
    }

    static func detailLine(destinationCount: Int, fileCount: Int) -> String {
        let backups = destinationCount == 1 ? "1 backup" : "\(destinationCount) backups"
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        return "\(backups) · \(files)"
    }

    // MARK: - Banner

    /// How many failed or interrupted transfers the banner on every platform
    /// asks the user to review. Every finished run remains in History.
    static func needsAttentionCount(states: [LocalTransferState]) -> Int {
        states.filter { $0 == .interrupted || $0 == .failed }.count
    }

    static func needsAttentionCount(_ records: [LocalTransferRecord]) -> Int {
        needsAttentionCount(states: records.map(\.state))
    }

    /// A problem already named by the Queue pause banner is not announced a
    /// second time above the screen. Other history problems still count.
    static func needsAttentionCount(_ records: [LocalTransferRecord], excluding suppressedIDs: Set<UUID>) -> Int {
        needsAttentionCount(records.filter { !suppressedIDs.contains($0.id) })
    }

    /// Banner text, or nil when there is nothing to review.
    static func bannerTitle(needsAttentionCount count: Int) -> String? {
        switch count {
        case ..<1: return nil
        case 1: return "Transfer needs attention — review in History"
        default: return "\(count) transfers need attention — review in History"
        }
    }

    /// The most recent interrupted or failed transfer shown beneath the toolbar.
    /// It takes precedence over the notification prompt until dismissed.
    static func attentionNotice(
        records: [LocalTransferRecord],
        isTransferRunning: Bool,
        dismissedIDs: Set<UUID>,
        suppressedIDs: Set<UUID> = []
    ) -> AttentionNotice? {
        guard !isTransferRunning else { return nil }
        guard let record = records
                .filter({
                    ($0.state == .interrupted || $0.state == .failed)
                        && !dismissedIDs.contains($0.id)
                        && !suppressedIDs.contains($0.id)
                })
                .max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        return AttentionNotice(
            recordID: record.id,
            title: record.state == .interrupted
                ? "A previous transfer was interrupted."
                : "A previous transfer failed.",
            detail: "Do not erase the card.",
            systemImage: "exclamationmark.triangle.fill",
            tint: record.state == .failed ? .red : .amber,
            rowDetail: nil
        )
    }
}
