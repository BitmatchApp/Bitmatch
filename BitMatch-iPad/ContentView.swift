// ContentView.swift - Modular iPad interface using component architecture
import SwiftUI
import UIKit

// MARK: - Color Extension for Hex Support
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Main ContentView using Modular Architecture
struct ContentView: View {
    @StateObject private var coordinator: SharedAppCoordinator
    @StateObject private var compactQueueState = CompactQueuePresentationState()
    @State private var showingQueueInspector = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(coordinator: SharedAppCoordinator? = nil) {
        _coordinator = StateObject(wrappedValue: coordinator ?? SharedAppCoordinator())
    }
    
    var body: some View {
        GeometryReader { proxy in
            let usesInspector = AdaptiveQueueLayoutPolicy.usesInspector(
                availableWidth: proxy.size.width,
                isPad: UIDevice.current.userInterfaceIdiom == .pad,
                isRegularWidth: horizontalSizeClass == .regular
            )
            let inspectorWidth = AdaptiveQueueLayoutPolicy.maximumInspectorWidth
            let setupWidth = proxy.size.width
                - (usesInspector && showingQueueInspector ? inspectorWidth : 0)
            let navigation = AdaptiveNavigationPolicy.presentation(for: setupWidth)
            if !usesInspector {
                CompactQueuePresentation(coordinator: coordinator, state: compactQueueState) {
                    PhoneContentView(coordinator: coordinator)
                }
                // Screenshot helper: -BitMatchDemoOpenQueue opens the queue
                // sheet automatically after seeding. The flag is DEBUG-only
                // in practice (always false in Release), so this stays inert
                // in plain and Release launches.
                .onChange(of: coordinator.demoQueueAutoOpen) { _, autoOpen in
                    guard autoOpen else { return }
                    compactQueueState.openQueue(rows: coordinator.queuePresentation.rows)
                }
            } else {
                RegularQueuePresentation(
                    coordinator: coordinator,
                    isInspectorPresented: $showingQueueInspector
                ) {
                    ModularContentView(
                        coordinator: coordinator,
                        navigationPresentation: navigation,
                        showingQueueInspector: $showingQueueInspector
                    )
                }
                // Screenshot helper: -BitMatchDemoOpenQueue shows the
                // inspector automatically after seeding (the empty-to-nonempty
                // transition below usually beats it there; this is the
                // explicit trigger).
                .onChange(of: coordinator.demoQueueAutoOpen) { _, autoOpen in
                    if autoOpen { showingQueueInspector = true }
                }
            }
        }
        .sheet(isPresented: $compactQueueState.showingQueue) {
            NavigationStack {
                ScrollView {
                    TransferQueueSection(
                        coordinator: coordinator,
                        offersAddCard: true,
                        showsHeaderTitle: false
                    )
                        .padding()
                }
                .navigationTitle("Transfers")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: coordinator.queuePresentation.rows) { oldRows, newRows in
            compactQueueState.update(previousRows: oldRows, currentRows: newRows)
            if oldRows.isEmpty && !newRows.isEmpty { showingQueueInspector = true }
            if newRows.isEmpty { showingQueueInspector = false }
        }
        .onAppear {
#if DEBUG
            // Screenshot scenario: -BitMatchDemoQueue seeds the real queue.
            // Compiled out of Release; plain launches are unaffected.
            DemoQueueSeeder.seedIfRequested(coordinator: coordinator)
#endif
        }
    }
}
