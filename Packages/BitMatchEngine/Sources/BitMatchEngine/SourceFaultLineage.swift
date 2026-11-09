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

    /// Source faults from every reachable predecessor of `record`, oldest
    /// first. The record's own faults are not included.
    public static func priorSourceFaults(
        for record: LocalTransferRecord,
        in records: [LocalTransferRecord]
    ) -> [PriorFault] {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<UUID> = [record.id]
        var faults: [PriorFault] = []
        var current = record
        for _ in 0..<maximumLinks {
            guard let predecessorID = current.retryOf,
                  !visited.contains(predecessorID),
                  let predecessor = byID[predecessorID] else { break }
            visited.insert(predecessorID)
            let reasons = sourceFaultReasons(in: predecessor)
            if !reasons.isEmpty {
                faults.append(PriorFault(attemptID: predecessor.id, reasons: reasons))
            }
            current = predecessor
        }
        return faults.reversed()
    }

    /// Whether any reachable predecessor recorded a source fault. False
    /// means only that none was found in the reachable chain; a missing or
    /// broken link must never be presented as proof the card was healthy.
    public static func hasPriorSourceFault(
        for record: LocalTransferRecord,
        in records: [LocalTransferRecord]
    ) -> Bool {
        !priorSourceFaults(for: record, in: records).isEmpty
    }
}
