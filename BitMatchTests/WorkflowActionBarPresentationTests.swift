import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

/// The one action bar for Copy, Compare and Master Report.
@MainActor
struct WorkflowActionBarPresentationTests {
    private static let emptySlot = CompareFolderSlot.make(
        url: nil, infoURL: nil, fileCount: nil, totalSize: nil, isFetching: false
    )

    private static func loaded(_ path: String) -> CompareFolderSlot {
        let url = URL(fileURLWithPath: path)
        return CompareFolderSlot.make(url: url, infoURL: url, fileCount: 3, totalSize: 30, isFetching: false)
    }

    private static func compare(
        left: CompareFolderSlot, right: CompareFolderSlot, running: Bool = false
    ) -> ComparePresentation {
        ComparePresentation.make(
            left: left, right: right, mode: .standard,
            isRunning: running, progress: nil, stats: nil, end: nil
        )
    }

    private static func start(
        title: String, canStart: Bool, blocker: String?, readyLine: String?,
        nextStep: StartButtonPresentation.NextStep? = nil
    ) -> StartButtonPresentation {
        StartButtonPresentation(
            title: title, symbol: "play.fill", canStart: canStart, action: .start,
            startsProject: false, nextStep: nextStep, blocker: blocker, readyLine: readyLine,
            accessibilityHint: ""
        )
    }

    private static func master(
        hasLocation: Bool = true, scanning: Bool = false, found: Int = 2,
        selected: Int = 2, generating: Bool = false
    ) -> MasterReportPresentation {
        MasterReportPresentation.make(
            hasLocation: hasLocation, isScanning: scanning, foundCount: found,
            selectedCount: selected, isGenerating: generating, deliverVerb: "Save"
        )
    }

    @Test func startMapsBlockerThenReadyLine() {
        let blocked = Self.start(title: "Start", canStart: false, blocker: "Pick a backup.", readyLine: "Ready.")
        let bar = WorkflowActionBarPresentation.make(start: blocked)
        #expect(bar.sentence == "Pick a backup.")
        #expect(bar.buttonTitle == "Start" && bar.symbol == "play.fill" && !bar.isEnabled)

        let ready = Self.start(title: "Start 3 transfers", canStart: true, blocker: nil, readyLine: "Ready to copy.")
        let readyBar = WorkflowActionBarPresentation.make(start: ready)
        #expect(readyBar.sentence == "Ready to copy.")
        #expect(readyBar.buttonTitle == "Start 3 transfers" && readyBar.isEnabled)

        let silent = Self.start(title: "Choose a source to start", canStart: false, blocker: nil, readyLine: nil)
        let silentBar = WorkflowActionBarPresentation.make(start: silent)
        #expect(silentBar.sentence == "Choose a source to start.")
        #expect(silentBar.buttonTitle == "Start" && !silentBar.isEnabled)
    }

    @Test func startNextStepBecomesTheSentence() {
        let source = Self.start(title: "Start", canStart: false, blocker: nil, readyLine: nil, nextStep: .chooseSource)
        #expect(WorkflowActionBarPresentation.make(start: source).sentence == "Choose a source to start.")
        let backup = Self.start(title: "Start", canStart: false, blocker: nil, readyLine: nil, nextStep: .addBackup)
        #expect(WorkflowActionBarPresentation.make(start: backup).sentence == "Add a destination to start.")
        let bare = Self.start(title: "Start", canStart: false, blocker: nil, readyLine: nil)
        #expect(WorkflowActionBarPresentation.make(start: bare).sentence == nil)
    }

    @Test func compareBlockedUsesActionTitleAsSentenceAndCheckAsButton() {
        let bar = WorkflowActionBarPresentation.make(compare: Self.compare(left: Self.emptySlot, right: Self.emptySlot))
        #expect(bar.sentence == "Choose a folder or drive.")
        #expect(bar.buttonTitle == "Check" && !bar.isEnabled && bar.symbol == "arrow.up")

        let needsRight = WorkflowActionBarPresentation.make(compare: Self.compare(left: Self.loaded("/tmp/a"), right: Self.emptySlot))
        #expect(needsRight.sentence == "Choose another folder.")
        #expect(needsRight.symbol == "arrow.up")
    }

    @Test func compareProblemKeepsItsOwnMessageAndRunningKeepsTheEllipsis() {
        let same = Self.compare(left: Self.loaded("/tmp/a"), right: Self.loaded("/tmp/a"))
        let sameBar = WorkflowActionBarPresentation.make(compare: same)
        #expect(sameBar.sentence == same.blockMessage && same.blockMessage != nil)
        #expect(sameBar.buttonTitle == "Check" && !sameBar.isEnabled)
        #expect(sameBar.symbol == "arrow.left.arrow.right")

        let running = WorkflowActionBarPresentation.make(
            compare: Self.compare(left: Self.loaded("/tmp/a"), right: Self.loaded("/tmp/b"), running: true))
        #expect(running.sentence == "Comparing…" && !running.isEnabled)
    }

    @Test func compareReadyKeepsItsActionTitle() {
        let ready = Self.compare(left: Self.loaded("/tmp/a"), right: Self.loaded("/tmp/b"))
        let bar = WorkflowActionBarPresentation.make(compare: ready)
        #expect(bar.sentence == nil)
        #expect(bar.buttonTitle == "Compare folders" && bar.isEnabled)
        #expect(bar.symbol == "arrow.left.arrow.right")
    }

    @Test func masterBlockedAndReady() {
        let blocked = WorkflowActionBarPresentation.make(master: Self.master(hasLocation: false))
        #expect(blocked.sentence == "Choose a drive to scan.")
        #expect(blocked.buttonTitle == "Scan" && !blocked.isEnabled && blocked.symbol == "arrow.up")

        let scanning = WorkflowActionBarPresentation.make(master: Self.master(scanning: true))
        #expect(scanning.sentence == "Scanning…")

        let none = WorkflowActionBarPresentation.make(master: Self.master(found: 0, selected: 0))
        #expect(none.sentence == "No reports to include." && none.symbol == "doc.richtext")

        let unselected = WorkflowActionBarPresentation.make(master: Self.master(selected: 0))
        #expect(unselected.sentence == "Select transfers to include." && unselected.symbol == "doc.richtext")

        let creating = WorkflowActionBarPresentation.make(master: Self.master(generating: true))
        #expect(creating.sentence == "Creating report…")

        let ready = WorkflowActionBarPresentation.make(master: Self.master())
        #expect(ready.sentence == nil && ready.isEnabled)
        #expect(ready.buttonTitle == "Create Master Report" && ready.symbol == "doc.richtext")
    }

    @Test func noSentenceEndsInTwoStopsOrAddsOneAfterAnEllipsis() {
        let sentences = [
            WorkflowActionBarPresentation.make(compare: Self.compare(left: Self.emptySlot, right: Self.emptySlot)).sentence,
            WorkflowActionBarPresentation.make(master: Self.master(scanning: true)).sentence,
            WorkflowActionBarPresentation.make(master: Self.master(hasLocation: false)).sentence,
        ].compactMap { $0 }
        for text in sentences {
            #expect(!text.hasSuffix(".."))
            #expect(!text.hasSuffix("….") )
        }
    }
}
