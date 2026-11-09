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
        let reasons = Set(record.results.compactMap { row -> String? in
            guard !row.isSuccessStatus, let reason = row.failureReason,
                  reason == ResultFailureReason.sourceUnstable.rawValue
                    || reason == ResultFailureReason.sourceReadFailed.rawValue
            else { return nil }
            return reason
        })
        return reasons.sorted()
    }

    /// What the reachable lineage establishes about earlier source faults.
    /// Callers deciding safe-to-erase wording must use this, not a Boolean:
    /// `lineageIncomplete` means the chain could not be fully walked
    /// (missing predecessor, cycle, or link limit), so absence of a found
    /// fault is not evidence the card read reliably before.
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
            }
            current = predecessor
        }
        let ordered = faults.reversed()
        guard chainCompleted else { return .lineageIncomplete(ordered) }
        return ordered.isEmpty ? .noFaultObserved : .priorFaultFound(ordered)
    }

    /// Source faults from every reachable predecessor of `record`, oldest
    /// first. The record's own faults are not included. A broken chain
    /// yields only the faults found before the break; use `assess` where
    /// the distinction matters.
    public static func priorSourceFaults(
        for record: LocalTransferRecord,
        in records: [LocalTransferRecord]
    ) -> [PriorFault] {
        assess(for: record, in: records).faults
    }

    /// Whether a source fault was actually found in the reachable chain.
    /// False is not proof of a healthy card when the chain is broken;
    /// use `assess` for any safe-to-erase decision.
    public static func hasPriorSourceFault(
        for record: LocalTransferRecord,
        in records: [LocalTransferRecord]
    ) -> Bool {
        !priorSourceFaults(for: record, in: records).isEmpty
    }
}
