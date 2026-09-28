// LiveResultsFeed.swift - the run's per-file results, observed on their own
import Foundation
import Combine
import BitMatchEngine

/// Holds the per-file result rows of the current run. During a transfer a
/// row arrives for every file on every backup (and again when it verifies),
/// so it lives outside `SharedAppCoordinator`'s `objectWillChange`, as
/// `LiveProgressFeed` does for progress: the Mac, iPad and iPhone shells
/// observe the coordinator, and a per-file row must not redraw them. Only
/// consumers that need live rows observe this object directly.
///
/// These rows are the same storage `SharedAppCoordinator.results` reads and
/// writes, so finished-row presentation, the journal and exports see
/// exactly what the engine reported. A whole-list write through
/// `coordinator.results` (clear, or the engine's authoritative list at the
/// end of a run) still announces itself on the coordinator.
@MainActor
final class LiveResultsFeed: ObservableObject {
    @Published private(set) var rows: [ResultRow] = []

    /// Rows are keyed by source path and backup name, as the coordinator's
    /// per-file update always was. The index holds each key's first row, so
    /// an update replaces the same row `firstIndex(where:)` would.
    private struct Key: Hashable {
        let path: String
        let destination: String?
    }
    private var indexByKey: [Key: Int] = [:]

    init(rows: [ResultRow] = []) {
        replace(with: rows)
    }

    /// Replaces every row (a new run, a reset, or the authoritative list).
    func replace(with newRows: [ResultRow]) {
        var index: [Key: Int] = [:]
        index.reserveCapacity(newRows.count)
        for (offset, row) in newRows.enumerated() {
            let key = Key(path: row.path, destination: row.destination)
            if index[key] == nil { index[key] = offset }
        }
        indexByKey = index
        rows = newRows
    }

    /// One live row from the engine: replaces the row for the same file and
    /// backup, or appends it. One change notification per call.
    func upsert(_ row: ResultRow) {
        let key = Key(path: row.path, destination: row.destination)
        if let existing = indexByKey[key] {
            rows[existing] = row
        } else {
            indexByKey[key] = rows.count
            rows.append(row)
        }
    }
}
