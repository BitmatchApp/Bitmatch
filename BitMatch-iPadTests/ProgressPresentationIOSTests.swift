import Foundation
import Testing
@testable import BitMatch_iPad
import BitMatchEngine

/// Step 4.9, iOS side: iPad and iPhone build progress through the same
/// `TransferProgressPresentation.make` as the Mac, and state the real iOS
/// limits instead of promising unattended work (AGENTS.md).
struct ProgressPresentationIOSTests {
    private func make(device: ProgressDevice) -> TransferProgressPresentation {
        TransferProgressPresentation.make(
            state: .inProgress,
            isRunning: true,
            progress: OperationProgress(
                overallProgress: 0.5, currentFile: "A001.MOV", filesProcessed: 4, totalFiles: 8,
                currentStage: .verifying, speed: nil),
            sourceName: "A001",
            destinations: [URL(fileURLWithPath: "/private/var/mobile/Backup", isDirectory: true)],
            speed: nil,
            timeRemaining: nil,
            elapsed: nil,
            issueCount: 0,
            device: device
        )
    }

    // Plant: in `TransferProgressPresentation.notes(for:)`, delete the
    // `notes.append` of the "Keep BitMatch open…" note.
    @Test
    func iOSStatesTheBackgroundLimit() {
        let foreground = make(device: .iOS(keepsScreenAwake: true, backgroundSecondsLeft: nil))
        #expect(foreground.deviceNotes.contains {
            $0.text == TransferProgressPresentation.iOSBackgroundLimit
        })
        #expect(foreground.deviceNotes.contains { $0.text.contains("screen stays on") })
        #expect(!foreground.deviceNotes.contains { $0.isWarning })

        let background = make(device: .iOS(keepsScreenAwake: false, backgroundSecondsLeft: 150))
        #expect(background.deviceNotes.first?.isWarning == true)
        #expect(background.deviceNotes.first?.text.hasPrefix("About 3 min") == true)
    }

    @Test
    func queueSectionShowsBackgroundLimitOnce() {
        let foreground = make(device: .iOS(keepsScreenAwake: true, backgroundSecondsLeft: nil))
        let foregroundNote = QueueRunningNoticePolicy.sectionNote(
            isRunning: true, isMobile: true, progress: foreground
        )
        #expect(foregroundNote?.text == TransferProgressPresentation.iOSBackgroundLimit)

        let background = make(device: .iOS(keepsScreenAwake: false, backgroundSecondsLeft: 150))
        let backgroundNote = QueueRunningNoticePolicy.sectionNote(
            isRunning: true, isMobile: true, progress: background
        )
        #expect(backgroundNote?.text == TransferProgressPresentation.iOSBackgroundLimit)
        #expect(QueueRunningNoticePolicy.sectionNote(
            isRunning: false, isMobile: true, progress: background
        ) == nil)
        #expect(QueueRunningNoticePolicy.sectionNote(
            isRunning: true, isMobile: false, progress: background
        ) == nil)
    }

    // Plant: in `TransferProgressPresentation.phase`, return `.preparing`
    // for every stage while the state is `.inProgress`.
    @Test
    func verifyingIsNamedFromTheStage() {
        let presentation = make(device: .iOS(keepsScreenAwake: false, backgroundSecondsLeft: nil))
        #expect(presentation.title == "Verifying")
        #expect(presentation.tone != .paused)
    }
}
