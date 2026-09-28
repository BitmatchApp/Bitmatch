// PhoneContentView.swift - Compact iPhone layout reusing shared components
import SwiftUI

struct PhoneContentView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @State private var showSettings = false
    @State private var showingTransfers = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ZStack {
                Group {
                    if showingTransfers {
                        TransferLibraryView(
                            coordinator: coordinator,
                            journal: coordinator.transferJournal,
                            onBack: { showingTransfers = false }
                        )
                    } else {
                        ScrollView {
                            VStack(spacing: 16) {
                                let attentionCount = TransferLibraryPresentation.needsAttentionCount(
                                    coordinator.transferJournal.records,
                                    excluding: Set([coordinator.queuePausedRecordID].compactMap { $0 })
                                )
                                if !coordinator.isOperationInProgress && !coordinator.queueIsRunning
                                    && !coordinator.showsOutcomeSummary && attentionCount > 0 {
                                    TransferAttentionBanner(needsAttentionCount: attentionCount) { showingTransfers = true }
                                        .padding(.horizontal)
                                } else if !coordinator.isOperationInProgress && !coordinator.queueIsRunning
                                    && !coordinator.showsOutcomeSummary {
                                    NotificationPermissionBanner(coordinator: coordinator)
                                }
                                AdaptiveModeNavigation(coordinator: coordinator, presentation: .compact)

                                switch coordinator.currentMode {
                                case .copyAndVerify:
                                    copyAndVerifyStack
                                case .compareFolders:
                                    CompareFoldersView(coordinator: coordinator)
                                        .padding(.horizontal, 16)
                                case .masterReport:
                                    MasterReportView(coordinator: coordinator)
                                        .padding(.horizontal, 16)
                                }
                            }
                            .padding(.bottom, 20)
                        }
                    }
                }
                .id(contentTransitionID)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: contentTransitionID)
            }
            .navigationTitle("BitMatch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !showingTransfers {
                        Button { showingTransfers = true } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheetView(coordinator: coordinator)
            }
        }
    }

    private var contentTransitionID: String {
        if showingTransfers { return "history" }
        if coordinator.currentMode == .compareFolders {
            if coordinator.isOperationInProgress { return "compare-running" }
            if coordinator.lastCompareEnd != nil { return "compare-finished" }
            return "compare-setup"
        }
        if coordinator.currentMode == .masterReport { return "master-report" }
        return "copy-setup"
    }

    private var copyAndVerifyStack: some View {
        CopyAndVerifyView(coordinator: coordinator)
    }
}
