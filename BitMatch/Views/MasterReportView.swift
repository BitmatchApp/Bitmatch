// Views/MasterReportView.swift - Mac adapter over the shared MasterReportScreen
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Mac's part of the Master Report: an open panel to choose the drive,
/// a save panel for the PDF (with its JSON beside it), and Show in Finder.
/// Everything else is the screen iPad and iPhone use.
struct MasterReportView: View {
    @ObservedObject var coordinator: SharedAppCoordinator

    var body: some View {
        MasterReportScreen(reportSettings: $coordinator.reportSettings, platform: Self.platform)
    }

    static var platform: MasterReportPlatform {
        MasterReportPlatform(
            chooseLocationTitle: MasterReportPresentation.locationTitle,
            locationHint: "Choose the destination drive, or a folder on it, that holds the day's BitMatch reports.",
            scanningHint: nil,
            deliverVerb: "Save",
            chooseLocation: { MasterReportView.chooseFolder() },
            deliver: { result, suggestedName in
                try MasterReportView.save(result, suggestedName: suggestedName)
            },
            reveal: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        )
    }

    @MainActor
    private static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose the destination drive or folder that holds the day's BitMatch reports"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Writes the PDF and its sibling JSON. Throws on any failure, so the
    /// screen shows success only after both files are written.
    @MainActor
    private static func save(_ result: MasterReportResult, suggestedName: String) throws -> MasterReportDelivery? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.pdf]
        panel.message = "A JSON copy of the report is saved beside the PDF."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try result.pdfData.write(to: url, options: .atomic)
        try result.jsonData.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        return .saved(url)
    }
}
