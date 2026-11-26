import Foundation
import BitMatchEngine

/// The host's remote bookkeeping: the current resource revisions and the
/// cards and backups offered to remote clients under opaque IDs. A client
/// never sends a path; the host resolves each ID here. No I/O.
@MainActor
final class RemoteHostState {
    let id: HostID
    /// Bumped by the snapshot builder whenever a resource changes.
    var revisions: ResourceRevisions
    private(set) var cards: [String: RemoteCardSummary] = [:]
    private(set) var backups: [String: RemoteBackupSummary] = [:]
    private var cardURLs: [String: URL] = [:]
    private var backupURLs: [String: URL] = [:]

    init(id: HostID = HostID(),
         revisions: ResourceRevisions = ResourceRevisions(selection: 0, queue: 0, operation: 0, settings: 0, state: 0)) {
        self.id = id
        self.revisions = revisions
    }

    func registerCard(_ card: RemoteCardSummary, url: URL) {
        cards[card.id] = card
        cardURLs[card.id] = url
    }

    func removeCard(id: String) {
        cards[id] = nil
        cardURLs[id] = nil
    }

    func registerBackup(_ backup: RemoteBackupSummary, url: URL) {
        backups[backup.id] = backup
        backupURLs[backup.id] = url
    }

    func removeBackup(id: String) {
        backups[id] = nil
        backupURLs[id] = nil
    }

    func url(forCard id: String) -> URL? { cardURLs[id] }
    func url(forBackup id: String) -> URL? { backupURLs[id] }
    func media(forCard id: String) -> MediaIncarnation? { cards[id]?.media }
}
