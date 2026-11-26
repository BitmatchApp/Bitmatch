import Combine
import Foundation
import BitMatchEngine

/// The host's remote bookkeeping: the current resource revisions and the
/// cards and backups offered to remote clients under opaque IDs. A client
/// never sends a path; the host resolves each ID here. No I/O.
///
/// A registered card's `media.volumeIdentity` must be the card volume's
/// identity as the transfer journal records it (`LocalTransferResource
/// .volumeID`, from `volumeIdentity(_:)`): the snapshot binds a saved
/// record to a card only when the two are equal, never by path.
///
/// Registering or removing a card or backup sends `objectWillChange`, so the
/// host core moves the revisions even while no client is attached.
/// `revisions` does not: the snapshot builder sets it.
@MainActor
final class RemoteHostState: ObservableObject {
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
        objectWillChange.send()
        cards[card.id] = card
        cardURLs[card.id] = url
    }

    func removeCard(id: String) {
        objectWillChange.send()
        cards[id] = nil
        cardURLs[id] = nil
    }

    func registerBackup(_ backup: RemoteBackupSummary, url: URL) {
        objectWillChange.send()
        backups[backup.id] = backup
        backupURLs[backup.id] = url
    }

    func removeBackup(id: String) {
        objectWillChange.send()
        backups[id] = nil
        backupURLs[id] = nil
    }

    func url(forCard id: String) -> URL? { cardURLs[id] }
    func url(forBackup id: String) -> URL? { backupURLs[id] }
    func media(forCard id: String) -> MediaIncarnation? { cards[id]?.media }
}
