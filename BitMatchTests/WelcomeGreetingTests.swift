import Foundation
import Testing
@testable import BitMatch

@MainActor
struct WelcomeGreetingTests {
    private final class DefaultsBox {
        let name = "BitMatchTests.WelcomeGreeting.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    @Test func unsetDefaultsMeansNotShown() throws {
        let box = try DefaultsBox()
        let greeting = WelcomeGreeting(defaults: box.defaults)
        #expect(greeting.hasBeenShown == false)
    }

    @Test func markShownPersistsTrue() throws {
        let box = try DefaultsBox()
        let greeting = WelcomeGreeting(defaults: box.defaults)
        greeting.markShown()
        #expect(greeting.hasBeenShown)
        #expect(box.defaults.bool(forKey: "BitMatchWelcomeShown"))
        #expect(WelcomeGreeting.shownKey == "BitMatchWelcomeShown")
    }

    @Test func launchPresentsWhenUnseenAndIdle() throws {
        let box = try DefaultsBox()
        let greeting = WelcomeGreeting(defaults: box.defaults)
        var presented = 0
        greeting.presentAtLaunchIfNeeded(transferIsRunning: false) { presented += 1 }
        #expect(presented == 1)
        #expect(greeting.hasBeenShown == false)
    }

    @Test func launchPresentsAtMostOncePerProcess() throws {
        let box = try DefaultsBox()
        let greeting = WelcomeGreeting(defaults: box.defaults)
        var presented = 0
        greeting.presentAtLaunchIfNeeded(transferIsRunning: false) { presented += 1 }
        greeting.presentAtLaunchIfNeeded(transferIsRunning: false) { presented += 1 }
        #expect(presented == 1)
    }

    @Test func launchSkipsWhileTransferRunsAndDoesNotMark() throws {
        let box = try DefaultsBox()
        let greeting = WelcomeGreeting(defaults: box.defaults)
        var presented = 0
        greeting.presentAtLaunchIfNeeded(transferIsRunning: true) { presented += 1 }
        greeting.presentAtLaunchIfNeeded(transferIsRunning: false) { presented += 1 }
        #expect(presented == 0)
        #expect(greeting.hasBeenShown == false)
        #expect(box.defaults.object(forKey: "BitMatchWelcomeShown") == nil)
    }

    @Test func launchSkipsWhenAlreadyShown() throws {
        let box = try DefaultsBox()
        box.defaults.set(true, forKey: "BitMatchWelcomeShown")
        let greeting = WelcomeGreeting(defaults: box.defaults)
        var presented = 0
        greeting.presentAtLaunchIfNeeded(transferIsRunning: false) { presented += 1 }
        #expect(presented == 0)
        #expect(greeting.hasBeenShown)
    }

    @Test func repositoryURLPointsAtTheProject() {
        #expect(WelcomeGreeting.repositoryURL.absoluteString == "https://github.com/BitmatchApp/Bitmatch")
    }
}
