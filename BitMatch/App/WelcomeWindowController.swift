// App/WelcomeWindowController.swift - Owns the one-time welcome panel
import AppKit
import SwiftUI

/// Shows the welcome panel and marks the greeting seen when it closes.
///
/// The window is an `NSPanel` on purpose: the app delegate finds the main
/// content window by "not a panel, can become main", so a panel never steals
/// Dock or menu-bar focusing from the transfer window.
///
/// Hold it with `@StateObject` (or from an object AppKit retains): SwiftUI
/// does not promise to keep a plain stored reference on the `App` struct
/// alive, and if the controller goes, the panel vanishes with it, unseen.
@MainActor
final class WelcomeWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let greeting: WelcomeGreeting
    private let openURL: (URL) -> Void
    private(set) var panel: NSPanel?

    init(greeting: WelcomeGreeting, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.greeting = greeting
        self.openURL = openURL
    }

    /// Creates the panel on first use and brings it forward on every call.
    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openRepository() {
        openURL(WelcomeGreeting.repositoryURL)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        greeting.markShown()
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: WelcomeView.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to BitMatch"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: WelcomeView(
            starOnGitHub: { [weak self] in self?.openRepository() },
            close: { [weak self] in self?.panel?.close() }
        ))
        panel.center()
        return panel
    }
}
