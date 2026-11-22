// App/WelcomeGreeting.swift - One-time welcome: the "seen" flag and the launch decision
import Combine
import Foundation

/// Decides whether the welcome panel appears, and remembers once it has.
///
/// The flag lives in UserDefaults so it survives Sparkle updates: a person
/// sees the greeting once per Mac user account, whether they installed fresh
/// or arrived by update. It is written only when the panel closes.
@MainActor
final class WelcomeGreeting: ObservableObject {
    static let shownKey = "BitMatchWelcomeShown"
    static let repositoryURL = URL(string: "https://github.com/BitmatchApp/Bitmatch")!
    /// Pause after the main window appears, so the greeting follows it rather
    /// than competing with it.
    static let launchDelay: Duration = .milliseconds(500)

    @Published private(set) var hasBeenShown: Bool

    private let defaults: UserDefaults
    private var launchDecisionMade = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasBeenShown = defaults.bool(forKey: Self.shownKey)
    }

    func markShown() {
        hasBeenShown = true
        defaults.set(true, forKey: Self.shownKey)
    }

    /// Decides once per process. Calls `present` only on the first call, when
    /// the greeting is unseen and no transfer is running. A launch that is
    /// already copying (a card inserted at login, say) skips the greeting
    /// without marking it, so it appears on the next idle launch instead.
    func presentAtLaunchIfNeeded(transferIsRunning: Bool, present: () -> Void) {
        guard !launchDecisionMade else { return }
        launchDecisionMade = true
        guard !hasBeenShown, !transferIsRunning else { return }
        present()
    }
}
