import Combine
import Foundation
import BitMatchEngine

/// The host's remote bookkeeping: the current resource revisions, the cards
/// (with their media and registration times) and backups offered to remote
/// clients under opaque IDs, and a registration generation. A client never
/// sends a path; the host resolves each ID here. No I/O.
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
    private var cardRegisteredAt: [String: Date] = [:]
    private var backupURLs: [String: URL] = [:]
    /// Moves on every register or remove, including one that changes only
    /// the folder behind an ID, which no snapshot field shows.
    private(set) var registrationGeneration = 0

    init(id: HostID = HostID(),
         revisions: ResourceRevisions = ResourceRevisions(selection: 0, queue: 0, operation: 0, settings: 0, state: 0)) {
        self.id = id
        self.revisions = revisions
    }

    /// `registeredAt` is when this mount of the card appeared. Registering
    /// the same media again (same volume identity and mount generation)
    /// keeps the first time; another mount, or another card under the ID,
    /// takes the new one. Only records created at or after it may speak for
    /// the card, so a re-inserted card never inherits yesterday's verdict.
    func registerCard(_ card: RemoteCardSummary, url: URL, registeredAt: Date) {
        registrationsWillChange()
        if cards[card.id]?.media != card.media || cardRegisteredAt[card.id] == nil {
            cardRegisteredAt[card.id] = registeredAt
        }
        cards[card.id] = card
        cardURLs[card.id] = url
    }

    func removeCard(id: String) {
        registrationsWillChange()
        cards[id] = nil
        cardURLs[id] = nil
        cardRegisteredAt[id] = nil
    }

    func registerBackup(_ backup: RemoteBackupSummary, url: URL) {
        registrationsWillChange()
        backups[backup.id] = backup
        backupURLs[backup.id] = url
    }

    func removeBackup(id: String) {
        registrationsWillChange()
        backups[id] = nil
        backupURLs[id] = nil
    }

    private func registrationsWillChange() {
        objectWillChange.send()
        registrationGeneration += 1
    }

    func url(forCard id: String) -> URL? { cardURLs[id] }
    func url(forBackup id: String) -> URL? { backupURLs[id] }
    func media(forCard id: String) -> MediaIncarnation? { cards[id]?.media }
    func registeredAt(card id: String) -> Date? { cardRegisteredAt[id] }
}
