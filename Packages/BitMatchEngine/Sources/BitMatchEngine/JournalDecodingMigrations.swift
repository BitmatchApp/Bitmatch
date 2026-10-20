import Foundation
import Synchronization

/// Scoped to one journal decode. Only nondeterministic migrations require an
/// immediate write; default values that decode identically can wait for the
/// next real mutation. Ordinary ResultRow decoding needs no journal context.
final class JournalDecodingMigrations: Sendable {
    static let userInfoKey = CodingUserInfoKey(rawValue: "BitMatch.TransferJournal.Migrations")!
    private let generatedResultID = Mutex(false)

    var requiresPersistence: Bool { generatedResultID.withLock { $0 } }

    func recordGeneratedResultID() {
        generatedResultID.withLock { $0 = true }
    }
}
