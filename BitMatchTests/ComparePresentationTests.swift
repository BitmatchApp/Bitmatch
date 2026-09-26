// ComparePresentationTests.swift
// UI plan step 4.1: the Compare readiness and outcome rules shared by Mac,
// iPad and iPhone. Each test names the one-line production change ("Plant")
// that must turn it red.
import Foundation
import Testing
@testable import BitMatch
import BitMatchEngine

struct ComparePresentationTests {

    private static let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bitmatch-compare-presentation", isDirectory: true)
    private static let card = base.appendingPathComponent("card", isDirectory: true)
    private static let backup = base.appendingPathComponent("backup", isDirectory: true)

    private static func loaded(_ url: URL) -> CompareFolderSlot {
        CompareFolderSlot.make(url: url, infoURL: url, fileCount: 3, totalSize: 30, isFetching: false)
    }

    private static let emptySlot = CompareFolderSlot.make(
        url: nil, infoURL: nil, fileCount: nil, totalSize: nil, isFetching: false
    )

    private static let cleanStats = CompareStats(
        onlyInLeftCount: 0, onlyInRightCount: 0, commonCount: 3, mismatchedCount: 0
    )

    @Test func zeroByteFolderUsesEmptyWording() {
        let slot = CompareFolderSlot.make(
            url: Self.card, infoURL: Self.card, fileCount: 1, totalSize: 0, isFetching: false
        )
        #expect(slot.sizeText == "Empty")
        #expect(slot.sizeText?.contains("Zero KB") == false)
    }

    @Test func folderLabelsExplainRolesAndSafety() {
        #expect(ComparePresentation.referenceFolderLabel == "Reference folder")
        #expect(ComparePresentation.folderToCheckLabel == "Folder to check")
        #expect(ComparePresentation.nonDestructiveMessage == "Compare does not change either folder.")
    }

    // MARK: Readiness

    /// Plant: in `CompareReadiness.resolve`, delete the line
    /// `if let block = CompareBlock.check(...) { return .blocked(block) }`.
    @Test
    func sameFolderIsBlocked() {
        let readiness = CompareReadiness.resolve(left: Self.loaded(Self.card), right: Self.loaded(Self.card), isRunning: false)
        #expect(readiness == .blocked(.sameFolder))
        #expect(!readiness.canStart)
        #expect(readiness.message != nil)
    }

    /// Plant: same as `sameFolderIsBlocked`.
    @Test
    func nestedFolderIsBlocked() {
        let child = Self.card.appendingPathComponent("DCIM", isDirectory: true)

        let rightInside = CompareReadiness.resolve(left: Self.loaded(Self.card), right: Self.loaded(child), isRunning: false)
        #expect(rightInside == .blocked(.rightInsideLeft))
        #expect(!rightInside.canStart)

        let leftInside = CompareReadiness.resolve(left: Self.loaded(child), right: Self.loaded(Self.card), isRunning: false)
        #expect(leftInside == .blocked(.leftInsideRight))
        #expect(!leftInside.canStart)
    }

    /// A shared name prefix is not nesting: "card" and "card-backup" are
    /// separate folders and must stay comparable.
    /// Plant: in `SafetyValidator.folderOverlap`, replace
    /// `pathIsWithin(secondPath, root: firstPath)` with `secondPath.hasPrefix(firstPath)`.
    @Test
    func siblingWithSharedPrefixIsNotBlocked() {
        let sibling = Self.base.appendingPathComponent("card-backup", isDirectory: true)
        let readiness = CompareReadiness.resolve(left: Self.loaded(Self.card), right: Self.loaded(sibling), isRunning: false)
        #expect(readiness == .ready)
    }

    /// The same folder reached through a symlink is still the same folder.
    /// Plant: in `SafetyValidator.folderOverlap`, replace `canonicalPath(first)`
    /// with `first.standardizedFileURL.path`.
    @Test
    func sameFolderThroughSymlinkIsBlocked() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bitmatch_compare_link_\(UUID().uuidString)")
        let real = root.appendingPathComponent("card")
        let link = root.appendingPathComponent("card-link")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let readiness = CompareReadiness.resolve(left: Self.loaded(link), right: Self.loaded(real), isRunning: false)
        #expect(readiness == .blocked(.sameFolder))
    }

    /// Plant: in `CompareReadiness.resolve`, delete
    /// `if left.isLoading || right.isLoading { return .loading }`.
    @Test
    func loadingBlocksCompare() {
        let loading = CompareFolderSlot.make(url: Self.backup, infoURL: nil, fileCount: nil, totalSize: nil, isFetching: true)
        #expect(loading.isLoading)

        let readiness = CompareReadiness.resolve(left: Self.loaded(Self.card), right: loading, isRunning: false)
        #expect(readiness == .loading)
        #expect(!readiness.canStart)
    }

    /// Details from the previously chosen folder must not count as loaded.
    /// Plant: in `CompareFolderSlot.make`, replace the `infoIsCurrent`
    /// expression with `true`.
    @Test
    func staleFolderInfoCountsAsLoading() {
        let slot = CompareFolderSlot.make(url: Self.backup, infoURL: Self.card, fileCount: 3, totalSize: 30, isFetching: true)
        #expect(slot.isLoading)
        #expect(slot.fileCount == nil)
        #expect(CompareReadiness.resolve(left: Self.loaded(Self.card), right: slot, isRunning: false) == .loading)
    }

    /// Unreadable details (common for iOS picks before scope is opened) must
    /// not block forever: Compare reads the folder itself and reports failures.
    /// Plant: in `CompareFolderSlot.make`, change `isLoading: isFetching && !hasInfo`
    /// to `isLoading: !hasInfo`.
    @Test
    func unreadableDetailsDoNotBlock() {
        let slot = CompareFolderSlot.make(url: Self.backup, infoURL: nil, fileCount: nil, totalSize: nil, isFetching: false)
        #expect(!slot.isLoading)
        #expect(slot.detailsUnavailable)
        #expect(CompareReadiness.resolve(left: Self.loaded(Self.card), right: slot, isRunning: false) == .ready)
    }

    /// Plant: in `CompareReadiness.resolve`, delete `if isRunning { return .running }`.
    @Test
    func runningBlocksCompare() {
        let readiness = CompareReadiness.resolve(left: Self.loaded(Self.card), right: Self.loaded(Self.backup), isRunning: true)
        #expect(readiness == .running)
        #expect(!readiness.canStart)

        let presentation = ComparePresentation.make(
            left: Self.loaded(Self.card), right: Self.loaded(Self.backup), mode: .standard,
            isRunning: true, progress: nil, stats: nil, end: nil
        )
        #expect(!presentation.allowsEditing)
        #expect(presentation.isRunning)
    }

    /// Plant: in `CompareReadiness.resolve`, change `return .needsRight` to `return .ready`.
    @Test
    func missingFolderBlocksCompare() {
        #expect(CompareReadiness.resolve(left: Self.emptySlot, right: Self.emptySlot, isRunning: false) == .needsLeft)
        let needsRight = CompareReadiness.resolve(left: Self.loaded(Self.card), right: Self.emptySlot, isRunning: false)
        #expect(needsRight == .needsRight)
        #expect(!needsRight.canStart)
        #expect(CompareReadiness.resolve(left: Self.loaded(Self.card), right: Self.loaded(Self.backup), isRunning: false).canStart)
    }

    // MARK: Outcome

    /// A cancelled compare with stale clean stats is not a match.
    /// Plant: at the top of `CompareOutcome.resolve`, add
    /// `if let stats, stats.isClean { return .match }`.
    @Test
    func cancelledOutcomeIsNotMatch() {
        let presentation = ComparePresentation.make(
            left: Self.loaded(Self.card), right: Self.loaded(Self.backup), mode: .standard,
            isRunning: false, progress: nil, stats: Self.cleanStats, end: .cancelled
        )
        #expect(presentation.phase == .finished(.cancelled))
        #expect(presentation.verdict?.tone == .cancelled)
        #expect(presentation.verdict?.title == "Compare cancelled")
    }

    /// Plant: same as `cancelledOutcomeIsNotMatch`.
    @Test
    func failedOutcomeIsNotMatch() {
        let outcome = CompareOutcome.resolve(stats: Self.cleanStats, end: .failed("Disk ejected"), mode: .standard)
        #expect(outcome == .failed("Disk ejected"))
        let verdict = CompareVerdictPresentation.make(outcome!, leftName: "card", rightName: "backup", mode: .standard, stats: Self.cleanStats)
        #expect(verdict.tone == .failed)
        #expect(verdict.detail == "Disk ejected")
    }

    /// THESIS decision: a clean Quick compare says "Sizes match, not
    /// verified" in amber, never a green "Folders match".
    /// Plant: in `CompareOutcome.resolve`, replace
    /// `CompareCheckPlan.make(for: mode).verifiesContents ? .match : .sizesMatchNotVerified` with `.match`.
    @Test
    func quickCleanCompareIsSizesMatchNotVerified() throws {
        let presentation = ComparePresentation.make(
            left: Self.loaded(Self.card), right: Self.loaded(Self.backup), mode: .quick,
            isRunning: false, progress: nil, stats: Self.cleanStats, end: .completed
        )
        #expect(presentation.phase == .finished(.sizesMatchNotVerified))
        let verdict = try #require(presentation.verdict)
        #expect(verdict.title == "Sizes match, not verified")
        #expect(verdict.tone == .notVerified)
    }

    /// Green only when contents were read.
    /// Plant: in `CompareCheckPlan.verifiesContents`, return `byteByByte` only.
    @Test
    func contentModesReportVerifiedMatch() {
        for mode in [VerificationMode.standard, .thorough, .paranoid] {
            let outcome = CompareOutcome.resolve(stats: Self.cleanStats, end: .completed, mode: mode)
            #expect(outcome == .match, "\(mode.rawValue) reads contents, so a clean compare is a verified match")
            let verdict = CompareVerdictPresentation.make(.match, leftName: "card", rightName: "backup", mode: mode, stats: Self.cleanStats)
            #expect(verdict.tone == .verified)
        }
    }

    /// Plant: in `CompareOutcome.resolve`, change `if !stats.isClean { return .differ }`
    /// to `if stats.mismatchedCount > 0 { return .differ }`.
    @Test
    func missingFilesAreADifference() {
        let stats = CompareStats(onlyInLeftCount: 1, onlyInRightCount: 0, commonCount: 2, mismatchedCount: 0,
                                 onlyInLeftPaths: ["DCIM/A002.MOV"])
        let outcome = CompareOutcome.resolve(stats: stats, end: .completed, mode: .paranoid)
        #expect(outcome == .differ)
        let verdict = CompareVerdictPresentation.make(.differ, leftName: "card", rightName: "backup", mode: .paranoid, stats: stats)
        #expect(verdict.tone == .differ)
        #expect(verdict.detail.contains("1 only in card"))
    }

    /// With no finished compare for this selection, the screen is in setup.
    /// Plant: in `ComparePresentation.make`, replace `phase = .setup` with
    /// `phase = .finished(.match)`.
    @Test
    func noCompareYetIsSetup() {
        let presentation = ComparePresentation.make(
            left: Self.loaded(Self.card), right: Self.loaded(Self.backup), mode: .standard,
            isRunning: false, progress: nil, stats: nil, end: nil
        )
        #expect(presentation.phase == .setup)
        #expect(presentation.verdict == nil)
    }

    // MARK: Paranoid

    /// THESIS decision: Paranoid Compare is byte-by-byte plus SHA-256,
    /// whatever `VerificationMode.paranoid.checksumTypes` lists.
    /// Plant: in `CompareCheckPlan.make`, change the `.paranoid` case to
    /// `Self(byteByByte: true, checksums: [])`.
    @Test
    func paranoidPlanIsByteByBytePlusSHA256() {
        let plan = CompareCheckPlan.make(for: .paranoid)
        #expect(plan.byteByByte)
        #expect(plan.checksums == [.sha256])
        #expect(plan.summary == "Byte-by-byte and SHA-256")
    }

    /// Plant: in `CompareCheckPlan.make`, change `.quick` to
    /// `Self(byteByByte: false, checksums: [.sha256])`.
    @Test
    func quickPlanReadsNoContents() {
        let plan = CompareCheckPlan.make(for: .quick)
        #expect(!plan.verifiesContents)
        #expect(plan.summary.contains("not verified"))
    }

    // MARK: Next step (Copy screen pattern)

    private static func screen(
        left: CompareFolderSlot,
        right: CompareFolderSlot,
        stats: CompareStats? = nil,
        end: CompareRunEnd? = nil
    ) -> ComparePresentation {
        ComparePresentation.make(
            left: left, right: right, mode: .standard,
            isRunning: false, progress: nil, stats: stats, end: end
        )
    }

    /// Nothing chosen: the Left box is highlighted and the button says so.
    /// Plant: in `ComparePresentation.nextStep`, change
    /// `case .needsLeft: .chooseLeft` to `case .needsLeft: .chooseRight`.
    @Test
    func emptyScreenHighlightsLeftFirst() {
        let presentation = Self.screen(left: Self.emptySlot, right: Self.emptySlot)
        #expect(presentation.nextStep == .chooseLeft)
        #expect(presentation.actionTitle == "Choose the reference folder")
        #expect(!presentation.readiness.canStart)
    }

    /// Left comes first even when only the right folder is chosen.
    /// Plant: in `CompareReadiness.resolve`, change the left guard's
    /// `return .needsLeft` to `return right.url == nil ? .needsLeft : .needsRight`.
    @Test
    func rightChosenFirstStillHighlightsLeft() {
        let presentation = Self.screen(left: Self.emptySlot, right: Self.loaded(Self.backup))
        #expect(presentation.nextStep == .chooseLeft)
        #expect(presentation.actionTitle == "Choose the reference folder")
    }

    /// Left chosen: the highlight moves to Right.
    /// Plant: in `ComparePresentation.nextStep`, change
    /// `case .needsRight: .chooseRight` to `case .needsRight: nil`.
    @Test
    func leftChosenHighlightsRight() {
        let presentation = Self.screen(left: Self.loaded(Self.card), right: Self.emptySlot)
        #expect(presentation.nextStep == .chooseRight)
        #expect(presentation.actionTitle == "Choose the folder to check")
        #expect(!presentation.readiness.canStart)
    }

    /// Both chosen: nothing is highlighted, and the button names the compare,
    /// or "Compare again" once one has finished.
    /// Plant: in `ComparePresentation.actionTitle`, change the `.ready` case
    /// to `case .ready: "Compare folders"`.
    @Test
    func readyHasNoNextStepAndNamesTheCompare() {
        let ready = Self.screen(left: Self.loaded(Self.card), right: Self.loaded(Self.backup))
        #expect(ready.nextStep == nil)
        #expect(ready.actionTitle == "Compare folders")

        let finished = Self.screen(
            left: Self.loaded(Self.card), right: Self.loaded(Self.backup),
            stats: Self.cleanStats, end: .completed
        )
        #expect(finished.nextStep == nil)
        #expect(finished.actionTitle == "Compare again")
    }

    /// Same or nested folders are a real problem: no box highlight, and the
    /// reason keeps its own line.
    /// Plant: in `ComparePresentation.blockMessage`, change
    /// `return block.message` to `return nil`.
    @Test
    func blockedCompareKeepsItsReasonLine() {
        let presentation = Self.screen(left: Self.loaded(Self.card), right: Self.loaded(Self.card))
        #expect(presentation.nextStep == nil)
        #expect(presentation.blockMessage == CompareBlock.sameFolder.message)
        #expect(presentation.actionTitle == "Choose two separate folders")
    }

    /// A missing folder or a folder still loading is not a problem, so no
    /// line appears under the button (the old hint line is gone).
    /// Plant: replace the body of `ComparePresentation.blockMessage` with
    /// `readiness.message`.
    @Test
    func stepsNotTakenShowNoReasonLine() {
        let loading = CompareFolderSlot.make(
            url: Self.backup, infoURL: nil, fileCount: nil, totalSize: nil, isFetching: true
        )
        #expect(Self.screen(left: Self.emptySlot, right: Self.emptySlot).blockMessage == nil)
        #expect(Self.screen(left: Self.loaded(Self.card), right: Self.emptySlot).blockMessage == nil)
        #expect(Self.screen(left: Self.loaded(Self.card), right: loading).blockMessage == nil)
        #expect(Self.screen(left: Self.loaded(Self.card), right: Self.loaded(Self.backup)).blockMessage == nil)
    }

    // MARK: Mode switching

    /// Decision C-2. Plant: in `ModeSwitchPolicy.isLocked`, return
    /// `isOperationInProgress` only.
    @Test
    func modeSwitchLockedWhileAnythingRuns() {
        #expect(ModeSwitchPolicy.isLocked(isOperationInProgress: true, queueIsRunning: false))
        #expect(ModeSwitchPolicy.isLocked(isOperationInProgress: false, queueIsRunning: true))
        #expect(!ModeSwitchPolicy.isLocked(isOperationInProgress: false, queueIsRunning: false))
    }
}
