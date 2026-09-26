import Foundation

// The Master Report's rules, shared by Mac, iPad and iPhone (UI plan step
// 4.10). Grouping, totals and what the primary button says are pure functions
// here, so the one `MasterReportScreen` only draws them.

/// One camera's transfers on the chosen day, with its own totals.
struct MasterReportCameraGroup: Identifiable {
    let name: String
    /// Oldest first, so a day reads in the order the cards were offloaded.
    let cards: [TransferCard]

    var id: String { name }
    var totalFiles: Int { cards.reduce(0) { $0 + $1.fileCount } }
    var totalSize: Int64 { cards.reduce(0) { $0 + $1.totalSize } }
    var verifiedCount: Int { cards.filter(\.verified).count }
}

/// The figures for the transfers going into the report.
struct MasterReportTotals: Equatable {
    let transfers: Int
    let files: Int
    let bytes: Int64
    let cameras: Int
    let verified: Int

    /// Only a report whose every transfer verified reads as all verified;
    /// an empty selection is not "all verified" (promise 2).
    var allVerified: Bool { transfers > 0 && verified == transfers }

    var verifiedText: String { "\(verified) of \(transfers)" }
    var sizeText: String { ByteCountPresentation.fileSize(bytes) }
}

/// The step the person has not taken yet. The screen highlights it instead
/// of showing a banner, as Copy and Compare do.
enum MasterReportNextStep: Equatable {
    case chooseLocation
    case selectTransfers
}

/// What the primary button says and whether it can be pressed. The title
/// names the next step while one is missing, like Copy's Start button.
struct MasterReportPresentation: Equatable {
    static let locationTitle = "Choose drive or folder…"
    static let locationDetail = "The backup drive, or a folder on it, with the day's BitMatch reports"

    let actionTitle: String
    let canGenerate: Bool
    let nextStep: MasterReportNextStep?

    static func make(
        hasLocation: Bool,
        isScanning: Bool,
        foundCount: Int,
        selectedCount: Int,
        isGenerating: Bool,
        deliverVerb _: String
    ) -> MasterReportPresentation {
        if !hasLocation {
            return .init(actionTitle: "Choose a drive to scan", canGenerate: false, nextStep: .chooseLocation)
        }
        if isScanning {
            return .init(actionTitle: "Scanning…", canGenerate: false, nextStep: nil)
        }
        if foundCount == 0 {
            return .init(actionTitle: "No reports to include", canGenerate: false, nextStep: nil)
        }
        if selectedCount == 0 {
            return .init(actionTitle: "Select transfers to include", canGenerate: false, nextStep: .selectTransfers)
        }
        if isGenerating {
            return .init(actionTitle: "Creating report…", canGenerate: false, nextStep: nil)
        }
        return .init(
            actionTitle: "Create Master Report",
            canGenerate: true,
            nextStep: nil
        )
    }

    /// Cards grouped by camera, cameras in name order, each group oldest first.
    static func groups(_ cards: [TransferCard]) -> [MasterReportCameraGroup] {
        Dictionary(grouping: cards, by: \.cameraName)
            .map { name, cards in
                MasterReportCameraGroup(name: name, cards: cards.sorted { $0.timestamp < $1.timestamp })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func totals(_ cards: [TransferCard]) -> MasterReportTotals {
        MasterReportTotals(
            transfers: cards.count,
            files: cards.reduce(0) { $0 + $1.fileCount },
            bytes: cards.reduce(0) { $0 + $1.totalSize },
            cameras: Set(cards.map(\.cameraName)).count,
            verified: cards.filter(\.verified).count
        )
    }

    /// The status the scanner recorded for one transfer: "Verified",
    /// "3 issues" or "Not verified".
    static func statusText(for card: TransferCard) -> String {
        if case .completed(let info) = card.state, !info.message.isEmpty {
            return card.verified ? info.message : "\(info.message) — do not erase the card"
        }
        return card.verified ? "Verified" : "Not verified — do not erase the card"
    }

    /// e.g. "MasterReport_2026-09-25", for the report's day, not the day it was made.
    static func fileName(for day: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "MasterReport_%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
