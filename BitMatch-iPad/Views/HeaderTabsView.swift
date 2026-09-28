// HeaderTabsView.swift - Top navigation tabs component for iPad
import SwiftUI
import UIKit

struct HeaderTabsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var coordinator: SharedAppCoordinator
    
    private var usesWideTabs: Bool {
        horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        topTabsSection
    }
    
    @ViewBuilder
    private var topTabsSection: some View {
        // EXACT copy of Mac ModeSelectorView
        HStack(spacing: 0) {
            ForEach([AppMode.copyAndVerify, AppMode.compareFolders, AppMode.masterReport], id: \.self) { appMode in
                Button {
                    coordinator.switchMode(to: appMode)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: appMode.systemImage)
                            .font(.system(size: usesWideTabs ? 15 : 11))
                        Text(appMode.shortTitle)
                            .font(.system(size: usesWideTabs ? 15 : 12, weight: .medium))
                    }
                    .foregroundStyle(coordinator.currentMode == appMode ? .primary : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: usesWideTabs ? .infinity : nil, minHeight: usesWideTabs ? 48 : 44)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(coordinator.currentMode == appMode ? Color.primary.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle()) // Make entire button area clickable
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(coordinator.currentMode == appMode ? .isSelected : [])
            }
        }
        .controlSize(usesWideTabs ? .large : .regular)
        .frame(maxWidth: usesWideTabs ? 640 : nil)
        // Decision C-2: no mode switch while anything runs.
        .disabled(coordinator.isModeSwitchLocked)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

struct AdaptiveModeNavigation: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    let presentation: AdaptiveNavigationPresentation

    var body: some View {
        switch presentation {
        case .compact:
            HStack(spacing: 8) {
                Text("MODE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(AppMode.allCases, id: \.self) { mode in
                        Button {
                            coordinator.switchMode(to: mode)
                        } label: {
                            Label(mode.shortTitle, systemImage: mode.systemImage)
                        }
                    }
                } label: {
                    Label(coordinator.currentMode.shortTitle, systemImage: coordinator.currentMode.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.09)))
                }
                // Decision C-2: no mode switch while anything runs.
                .disabled(coordinator.isModeSwitchLocked)
                .accessibilityLabel("Mode")
                .accessibilityValue(coordinator.currentMode.shortTitle)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

        case .toolbar:
            HeaderTabsView(coordinator: coordinator)

        case .sidebar:
            VStack(alignment: .leading, spacing: 6) {
                Text("BITMATCH")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                ForEach(AppMode.allCases, id: \.self) { mode in
                    Button {
                        coordinator.switchMode(to: mode)
                    } label: {
                        Label(mode.shortTitle, systemImage: mode.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(coordinator.currentMode == mode ? .primary : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 9).fill(coordinator.currentMode == mode ? Color.primary.opacity(0.12) : .clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(coordinator.currentMode == mode ? .isSelected : [])
                }
                .disabled(coordinator.isModeSwitchLocked)
                Spacer()
            }
            .frame(width: 208, alignment: .leading)
            .padding(16)
        }
    }
}
