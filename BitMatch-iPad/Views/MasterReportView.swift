// MasterReportView.swift - iPad/iPhone adapter over the shared MasterReportScreen
import SwiftUI
import UIKit

/// The iPad and iPhone part of the Master Report: the Files picker to choose
/// a drive or folder (the only way iOS lets an app read removable media), and
/// the share sheet for the finished PDF and JSON. Everything else is the
/// screen the Mac uses.
struct MasterReportView: View {
    @ObservedObject var coordinator: SharedAppCoordinator

    var body: some View {
        MasterReportScreen(reportSettings: $coordinator.reportSettings, platform: Self.platform)
    }

    static var platform: MasterReportPlatform {
        MasterReportPlatform(
            chooseLocationTitle: MasterReportPresentation.locationTitle,
            locationHint: "Pick the destination drive, card reader, or folder in Files. BitMatch can read only the location you pick.",
            scanningHint: "Keep BitMatch open until the scan finishes. iOS pauses it in the background.",
            deliverVerb: "Share",
            chooseLocation: { await IOSDriverScanner.chooseFolder() },
            deliver: { result, suggestedName in
                try await MasterReportView.share(result, suggestedName: suggestedName)
            },
            reveal: nil
        )
    }

    /// Writes the PDF and JSON to a temporary folder and opens the share
    /// sheet. Returns `.shared` only when the person finished an activity
    /// (saved to Files, AirDropped, …), nil when they dismissed the sheet,
    /// and throws when the files could not be written or the sheet not shown.
    @MainActor
    private static func share(_ result: MasterReportResult, suggestedName: String) async throws -> MasterReportDelivery? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MasterReport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdfURL = folder.appendingPathComponent(suggestedName).appendingPathExtension("pdf")
        let jsonURL = folder.appendingPathComponent(suggestedName).appendingPathExtension("json")
        try result.pdfData.write(to: pdfURL, options: .atomic)
        try result.jsonData.write(to: jsonURL, options: .atomic)

        guard let presenter = IOSDriverScanner.topViewController() else {
            throw MasterReportShareError.noPresenter
        }
        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let sheet = UIActivityViewController(activityItems: [pdfURL, jsonURL], applicationActivities: nil)
            var resumed = false
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: completed)
            }
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            presenter.present(sheet, animated: true)
        }
        return completed ? .shared : nil
    }
}

private enum MasterReportShareError: LocalizedError {
    case noPresenter

    var errorDescription: String? {
        switch self {
        case .noPresenter: return "The share sheet could not be opened. Try again."
        }
    }
}
