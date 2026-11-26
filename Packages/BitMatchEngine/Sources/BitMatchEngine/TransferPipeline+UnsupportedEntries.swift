import Foundation

extension TransferPipeline {
    /// "2 symbolic links, 1 named pipe", in a stable order for messages and tests.
    static func describe(_ entries: [CardSource.UnsupportedEntry]) -> String {
        let counts = Dictionary(grouping: entries, by: \.kind).mapValues(\.count)
        return CardSource.UnsupportedEntryKind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind] else { return nil }
            return "\(count) \(count == 1 ? kind.noun : kind.plural)"
        }.joined(separator: ", ")
    }

    /// The row's error carries the canonical reason token; the text names
    /// the kind so History and reports can say what was on the card.
    static func unsupportedEntryError(_ kind: CardSource.UnsupportedEntryKind) -> NSError {
        NSError(domain: "BitMatch.CardSource", code: NSFileReadUnsupportedSchemeError, userInfo: [
            NSLocalizedDescriptionKey: "This \(kind.noun) was not copied. BitMatch copies regular files only; keep the source.",
            ResultFailureReason.userInfoKey: ResultFailureReason.unsupportedSourceEntry.rawValue,
        ])
    }
}
