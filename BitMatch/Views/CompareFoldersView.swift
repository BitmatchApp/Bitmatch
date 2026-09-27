// Views/CompareFoldersView.swift - Mac adapter over the shared CompareScreen
import SwiftUI
import AppKit

/// Builds the shared `ComparePresentation` from `SharedAppCoordinator` and hands
/// picking, dropping and starting to the Mac. Readiness, progress and the
/// outcome are the same rules and screen as on iPad and iPhone.
struct CompareFoldersView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    /// Compare draws its progress inline; the coordinator does not republish
    /// progress ticks, so this view observes them itself.
    @ObservedObject private var liveProgress: LiveProgressFeed
    @Binding var advancedExpanded: Bool

    init(coordinator: SharedAppCoordinator, advancedExpanded: Binding<Bool>) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        _liveProgress = ObservedObject(wrappedValue: coordinator.liveProgress)
        _advancedExpanded = advancedExpanded
    }

    /// Also used by ⌘R, so the keyboard path obeys the same readiness rule.
    static func presentation(for shared: SharedAppCoordinator) -> ComparePresentation {
        ComparePresentation.make(
            left: CompareFolderSlot.make(
                url: shared.leftURL,
                infoURL: shared.leftFolderInfo?.url,
                fileCount: shared.leftFolderInfo?.fileCount,
                totalSize: shared.leftFolderInfo?.totalSize,
                isFetching: shared.isAnalysingLeft
            ),
            right: CompareFolderSlot.make(
                url: shared.rightURL,
                infoURL: shared.rightFolderInfo?.url,
                fileCount: shared.rightFolderInfo?.fileCount,
                totalSize: shared.rightFolderInfo?.totalSize,
                isFetching: shared.isAnalysingRight
            ),
            choice: shared.checkAgainst,
            savedAvailability: shared.savedChecksumAvailability,
            mode: shared.verificationMode,
            isRunning: shared.isOperationInProgress,
            progress: shared.progress.map {
                CompareProgressPresentation(
                    fraction: $0.overallProgress,
                    filesProcessed: $0.filesProcessed,
                    totalFiles: $0.totalFiles,
                    currentFile: $0.currentFile
                )
            },
            stats: shared.lastCompareStats,
            savedResult: shared.lastSavedChecksumResult,
            end: shared.lastCompareEnd
        )
    }

    /// Starts only when the shared readiness rule says so.
    static func startIfReady(_ coordinator: SharedAppCoordinator) {
        guard presentation(for: coordinator).readiness.canStart else { return }
        coordinator.switchMode(to: .compareFolders)
        Task { await coordinator.startCurrentMode() }
    }

    var body: some View {
        CompareScreen(
            presentation: Self.presentation(for: coordinator),
            checkAgainst: $coordinator.checkAgainst,
            verificationMode: $coordinator.verificationMode,
            advancedExpanded: $advancedExpanded,
            actions: CompareActions(
                pickLeft: { if let url = openFolderPanel() { coordinator.leftURL = url } },
                pickRight: { if let url = openFolderPanel() { coordinator.rightURL = url } },
                clearLeft: { coordinator.leftURL = nil },
                clearRight: { coordinator.rightURL = nil },
                dropLeft: { url in acceptDrop(url) { coordinator.leftURL = $0 } },
                dropRight: { url in acceptDrop(url) { coordinator.rightURL = $0 } },
                compare: { Self.startIfReady(coordinator) },
                cancel: { coordinator.cancelOperation() }
            )
        )
    }

    /// Folders only. Anything else is refused out loud, not silently ignored.
    private func acceptDrop(_ url: URL, assign: (URL) -> Void) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            assign(url)
        } else {
            NotificationCenter.default.post(
                name: .dropRejected,
                object: nil,
                userInfo: ["reason": "Drop a folder to compare, not a file."]
            )
        }
    }

    private func openFolderPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
