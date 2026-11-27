import Foundation

/// Cross-attempt source-health facts derived from explicit retry lineage.
///
/// A successful retry proves its own backup, not that the card is healthy.
/// If any earlier attempt linked by `retryOf` recorded a source fault, that
/// warning survives the retry's success. Only explicit `retryOf` links are
/// traversed: a missing predecessor, a cycle, or a chain longer than the
/// bound stops the walk, and what was found up to that point is all that is
/// claimed — a broken chain is unknown territory, never proof that no
/// earlier fault exists.
public enum SourceFaultLineage {
    /// One earlier attempt's recorded source faults.
    public struct PriorFault: Equatable, Sendable {
        public let attemptID: UUID
        /// Canonical `ResultFailureReason` tokens (`sourceUnstable`,
        /// `sourceReadFailed`), sorted for stable presentation.
        public let reasons: [String]

        public init(attemptID: UUID, reasons: [String]) {
            self.attemptID = attemptID
            self.reasons = reasons
        }
    }

    /// Maximum lineage links followed for one record.
    public static let maximumLinks = 64

    /// Source faults recorded by the record itself.
    public static func sourceFaultReasons(in record: LocalTransferRecord) -> [String] {
        var reasons = Set(record.results.compactMap { row -> String? in
            guard !row.isSuccessStatus, let reason = row.failureReason,
                  ResultFailureReason(rawValue: reason)?.isSourceFault == true
            else { return nil }
            return reason
        })
        if let reason = record.failureReason, ResultFailureReason(rawValue: reason)?.isSourceFault == true {
            reasons.insert(reason)
        }
        return reasons.sorted()
    }

    /// Whether an earlier attempt says anything reliable about the card.
    /// An attempt that did not finish cleanly and carries no classified
    /// source reason (a failure from before reasons were recorded, or one
    /// that stopped before producing rows) is unknown territory: it is not
    /// evidence the card read fine. A cancellation is the person's choice,
    /// and a classified non-source failure says the card read fine.
    static func predecessorIsUnclassified(_ record: LocalTransferRecord) -> Bool {
        // AppleDouble exclusions are deliberate; Finder skips are only
        // explained when the saved record proves them.
        let skipsProven = TransferJournal.finderMetadataSkipsProven(record)
        let unsuccessful = record.results.filter {
            !$0.isSuccessStatus
                && ResultOutcome(statusText: $0.status) != .excludedAppleDouble
                && !($0.isSkippedFinderMetadata && skipsProven)
        }
        // Every unsuccessful row must say why, whatever the record's state:
        // one explained row never explains another.
        // A reason that leaves the card unproven (an existing backup file
        // whose contents differ) explains nothing about the card.
        let anyUnexplainedRow = unsuccessful.contains { row in
            if row.isSkippedFinderMetadata { return true }
            guard let reason = row.failureReason.flatMap(ResultFailureReason.init(rawValue:)) else { return true }
            return reason.leavesCardUnproven
        }
        switch record.state {
        case .queued, .running: return false
        case .cancelled, .completed:
            // A cancellation is the person's choice, but a row that failed
            // for no recorded reason before they cancelled is still unexplained.
            return anyUnexplainedRow
        case .issues:
            // Quick-mode records are .issues with successful rows, and those
            // read the card fine. An .issues record with no rows at all
            // stopped before it could say why.
            return record.results.isEmpty || anyUnexplainedRow
        case .failed, .interrupted:
            // The attempt did not finish. Its rows may all read as verified
            // (the card failed during the final check, after every file was
            // published), so something must explain the stop: a classified
            // reason on the record, or at least one classified unsuccessful
            // row with no unexplained one beside it.
            if anyUnexplainedRow { return true }
            let recordExplained = record.failureReason.flatMap(ResultFailureReason.init(rawValue:))
                .map { !$0.leavesCardUnproven } ?? false
            let rowExplained = unsuccessful.contains { row in
                row.failureReason.flatMap(ResultFailureReason.init(rawValue:)).map { !$0.leavesCardUnproven } ?? false
            }
            return !(recordExplained || rowExplained)
        }
    }

    /// What the reachable lineage establishes about earlier source faults.
    /// Callers deciding safe-to-erase wording must use this, not a Boolean:
    /// `lineageIncomplete` means the chain could not be fully walked
    /// (missing predecessor, cycle, link limit, or a predecessor whose
    /// failure is unclassified), so absence of a found fault is not
    /// evidence the card read reliably before.
    public enum Assessment: Equatable, Sendable {
        /// The whole chain was walked and no predecessor faulted.
        case noFaultObserved
        /// The whole chain was walked and these predecessors faulted.
        case priorFaultFound([PriorFault])
        /// The chain broke before its end. Faults found before the break
        /// are included; more may exist beyond it.
        case lineageIncomplete([PriorFault])

        public var faults: [PriorFault] {
            switch self {
            case .noFaultObserved: []
            case .priorFaultFound(let faults), .lineageIncomplete(let faults): faults
            }
        }

        /// True unless the lineage was fully walked with no fault found.
        /// Only `noFaultObserved` may support a safe-to-erase claim.
        public var preventsSafeToEraseClaim: Bool { self != .noFaultObserved }
    }

    public static func assess(
        for record: LocalTransferRecord,
        in records: [LocalTransferRecord]
    ) -> Assessment {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<UUID> = [record.id]
        var faults: [PriorFault] = []
        var current = record
        var chainCompleted = false
        var unclassifiedPredecessorFound = false
        for _ in 0...maximumLinks {
            guard let predecessorID = current.retryOf else {
                chainCompleted = true
                break
            }
            guard !visited.contains(predecessorID),
                  let predecessor = byID[predecessorID] else { break }
            visited.insert(predecessorID)
            let reasons = sourceFaultReasons(in: predecessor)
            if !reasons.isEmpty {
                faults.append(PriorFault(attemptID: predecessor.id, reasons: reasons))
            } else if predecessorIsUnclassified(predecessor) {
                unclassifiedPredecessorFound = true
            }
            current = predecessor
        }
        let ordered = Array(faults.reversed())
        guard chainCompleted, !unclassifiedPredecessorFound else { return .lineageIncomplete(ordered) }
        return ordered.isEmpty ? .noFaultObserved : .priorFaultFound(ordered)
    }
}
