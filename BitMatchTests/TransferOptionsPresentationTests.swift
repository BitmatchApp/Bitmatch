import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// Step 4.6 (P4): the shared Advanced options section.
struct TransferOptionsPresentationTests {
    // Plant: in `TransferOptionsPresentation.make`, replace
    // `if verificationMode != defaultVerificationMode {` with `if true {`.
    @Test
    func advancedLabelHidesDefaults() {
        let options = TransferOptionsPresentation.make(
            verificationMode: .standard,
            generateASCMHL: true,
            makeReport: true,
            cameraLabel: ""
        )
        #expect(options.advancedNote.isEmpty)
    }

    // Plant: in `make`, delete `notes.append("Reports off")`.
    @Test
    func advancedLabelNamesOnlyChangedSettings() {
        let options = TransferOptionsPresentation.make(
            verificationMode: .quick,
            generateASCMHL: true,
            makeReport: false,
            cameraLabel: "  A-Cam "
        )
        #expect(options.advancedNote == "Quick mode · Reports off · Label: A-Cam")

        let standardWithoutMHL = TransferOptionsPresentation.make(
            verificationMode: .standard,
            generateASCMHL: false,
            makeReport: true,
            cameraLabel: nil
        )
        #expect(standardWithoutMHL.advancedNote == "ASC MHL off")
    }

    // Plant: in `make`, drop `, ascMHLEnabled(for: verificationMode)` from the ASC MHL note condition.
    @Test
    func quickModeDoesNotAlsoReportASCMHLOff() {
        let options = TransferOptionsPresentation.make(
            verificationMode: .quick,
            generateASCMHL: false,
            makeReport: true,
            cameraLabel: nil
        )
        #expect(options.advancedNote == "Quick mode")
    }

    // Plant: in `ascMHLEnabled(for:)`, return `true`.
    @Test
    func ascMHLUnavailableInQuick() {
        #expect(!TransferOptionsPresentation.ascMHLEnabled(for: .quick))
        let quick = TransferOptionsPresentation.make(
            verificationMode: .quick, generateASCMHL: true, makeReport: true, cameraLabel: nil
        )
        #expect(!quick.ascMHLEnabled)
        #expect(quick.ascMHLFootnote.contains("no checksum"))

        for mode in VerificationMode.allCases where mode != .quick {
            #expect(TransferOptionsPresentation.ascMHLEnabled(for: mode))
        }
    }

    // Compare hides ASC MHL and reports, so their state must not leak into its note.
    // Plant: in `make`, change `if makeReport == false {` to `if makeReport != true {`.
    @Test
    func compareSubsetNotesOnlyTheMode() {
        let standard = TransferOptionsPresentation.make(
            verificationMode: .standard, generateASCMHL: nil, makeReport: nil, cameraLabel: nil,
            isCompare: true
        )
        #expect(standard.advancedNote.isEmpty)
        #expect(standard.verificationDetail == CompareCheckPlan.make(for: .standard).summary)
        let paranoid = TransferOptionsPresentation.make(
            verificationMode: .paranoid, generateASCMHL: nil, makeReport: nil, cameraLabel: nil,
            isCompare: true
        )
        #expect(paranoid.advancedNote == "Paranoid mode")
        #expect(paranoid.verificationDetail == CompareCheckPlan.make(for: .paranoid).summary)
    }

    // Every platform now writes a PDF (`ReportPDFRenderer`), so the label names it everywhere.
    // Plant: in `platformWritesPDF`, return `false`.
    @Test
    func macReportLabelNamesEveryFormatWritten() {
        #expect(TransferOptionsPresentation.reportToggleTitle() == "Create PDF, CSV and JSON reports")
        #expect(TransferOptionsPresentation.reportFormatsDescription(writesPDF: false) == "CSV and JSON")
    }

    // The note only ever says "Reports off"; that is right only while reports default to on.
    // Plant: in `Shared/Core/Models/TransferModels.swift`, `var makeReport: Bool = false`
    // (a plant only; that file is otherwise hands-off for this step).
    @Test
    func reportsDefaultToOn() {
        #expect(ReportPrefs().makeReport)
        #expect(TransferOptionsPresentation.defaultVerificationMode == .standard)
    }
}
