import Foundation
import BitMatchEngine

/// What the Advanced options section says, on every platform.
///
/// Verification mode, ASC MHL and reports are opt-in power features (THESIS
/// promise 4), so they live under one collapsed "Advanced" disclosure. The
/// disclosure label stays plain unless something is set away from its default,
/// and then it names only that setting. The one-line summary above Advanced
/// keeps saying whether the copy is verified (promise 2); this does not repeat it.
struct TransferOptionsPresentation: Equatable, Sendable {
    /// The default the note compares against. It mirrors
    /// `SharedAppCoordinator.verificationMode`'s initial value; it does not set it.
    /// ASC MHL and reports default to on (the `BitMatchGenerateASCMHL` fallback
    /// and `ReportPrefs.makeReport`), so only "off" is worth a note.
    static let defaultVerificationMode: VerificationMode = .standard

    /// Trailing text on the Advanced label. Empty when every option is at its default.
    let advancedNote: String
    let verificationDetail: String
    let ascMHLEnabled: Bool
    let ascMHLFootnote: String
    let reportToggleTitle: String

    /// Pass `nil` for an option the screen does not show (Compare shows only
    /// the verification mode).
    static func make(
        verificationMode: VerificationMode,
        generateASCMHL: Bool?,
        makeReport: Bool?,
        cameraLabel: String?,
        includesVerificationNote: Bool = true,
        writesPDF: Bool = TransferOptionsPresentation.platformWritesPDF
    ) -> TransferOptionsPresentation {
        var notes: [String] = []
        if includesVerificationNote && verificationMode != defaultVerificationMode {
            notes.append("\(verificationMode.rawValue) mode")
        }
        if generateASCMHL == false, ascMHLEnabled(for: verificationMode) {
            notes.append("ASC MHL off")
        }
        if makeReport == false {
            notes.append("Reports off")
        }
        if let label = cameraLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            notes.append("Label: \(label)")
        }

        let enabled = ascMHLEnabled(for: verificationMode)
        return TransferOptionsPresentation(
            advancedNote: notes.joined(separator: " · "),
            verificationDetail: verificationMode.description,
            ascMHLEnabled: enabled,
            ascMHLFootnote: ascMHLFootnote(for: verificationMode),
            reportToggleTitle: reportToggleTitle(writesPDF: writesPDF)
        )
    }

    /// ASC MHL records checksums, and Quick mode computes none.
    static func ascMHLEnabled(for mode: VerificationMode) -> Bool {
        mode != .quick
    }

    static func ascMHLFootnote(for mode: VerificationMode) -> String {
        ascMHLEnabled(for: mode)
            ? "Creates an interoperable checksum record for verified copies."
            : "Quick mode records sizes only, so there is no checksum to hand off."
    }

    // MARK: - Report formats

    /// Every platform renders the PDF report through `ReportPDFRenderer`, plus
    /// the CSV and JSON (THESIS decision, 2026-09-25: "iPad and iPhone get a
    /// PDF report too").
    static var platformWritesPDF: Bool { true }

    /// The formats a report run writes, named the same way in Setup, iOS
    /// Settings and Mac Preferences.
    static func reportFormatsDescription(writesPDF: Bool = TransferOptionsPresentation.platformWritesPDF) -> String {
        writesPDF ? "PDF, CSV and JSON" : "CSV and JSON"
    }

    static func reportToggleTitle(writesPDF: Bool = TransferOptionsPresentation.platformWritesPDF) -> String {
        "Create \(reportFormatsDescription(writesPDF: writesPDF)) reports"
    }
}
