import Foundation

struct TransferMenuPresentation: Equatable {
    static let unavailableEjectTitle = "Eject Card"
    static let ejectErrorTitle = "Could Not Eject Card"

    let ejectTitle: String?

    static func make(
        isTransferRunning: Bool,
        outcome: TransferOutcomePresentation?,
        sourceName: String,
        sourceIsEjectable: Bool
    ) -> Self {
        let canEject = !isTransferRunning
            && sourceIsEjectable
            && outcome?.canEject == true
        let card = sourceName.isEmpty ? "Card" : sourceName
        return Self(ejectTitle: canEject ? "Eject \(card)" : nil)
    }
}
