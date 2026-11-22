import AppKit
import Foundation
import Testing
@testable import BitMatch

@MainActor
struct WelcomeWindowControllerTests {
    private final class DefaultsBox {
        let name = "BitMatchTests.WelcomeWindow.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
        }

        deinit {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private func makeController(defaults: UserDefaults, openURL: @escaping (URL) -> Void = { _ in }) -> (WelcomeGreeting, WelcomeWindowController) {
        let greeting = WelcomeGreeting(defaults: defaults)
        return (greeting, WelcomeWindowController(greeting: greeting, openURL: openURL))
    }

    @Test func showCreatesAPanelThatCannotBecomeMain() throws {
        let box = try DefaultsBox()
        let (_, controller) = makeController(defaults: box.defaults)
        controller.show()
        let panel = try #require(controller.panel)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.closable))
        #expect(panel.styleMask.contains(.resizable) == false)
        #expect(panel.isFloatingPanel == false)
        #expect(panel.hidesOnDeactivate == false)
        panel.close()
    }

    @Test func showTwiceReusesThePanel() throws {
        let box = try DefaultsBox()
        let (_, controller) = makeController(defaults: box.defaults)
        controller.show()
        let first = try #require(controller.panel)
        controller.show()
        #expect(controller.panel === first)
        first.close()
    }

    @Test func closingMarksGreetingShown() throws {
        let box = try DefaultsBox()
        let (greeting, controller) = makeController(defaults: box.defaults)
        controller.show()
        #expect(greeting.hasBeenShown == false)
        try #require(controller.panel).close()
        #expect(greeting.hasBeenShown)
        #expect(controller.panel == nil)
    }

    @Test func reopeningAfterShownKeepsFlagTrue() throws {
        let box = try DefaultsBox()
        box.defaults.set(true, forKey: WelcomeGreeting.shownKey)
        let (greeting, controller) = makeController(defaults: box.defaults)
        controller.show()
        try #require(controller.panel).close()
        #expect(greeting.hasBeenShown)
        #expect(box.defaults.bool(forKey: WelcomeGreeting.shownKey))
    }

    @Test func quittingWithThePanelOpenMarksGreetingShown() throws {
        let box = try DefaultsBox()
        let (greeting, controller) = makeController(defaults: box.defaults)
        controller.show()
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        #expect(greeting.hasBeenShown)
        #expect(box.defaults.bool(forKey: WelcomeGreeting.shownKey))
        controller.panel?.close()
    }

    @Test func quittingWithoutThePanelLeavesGreetingUnseen() throws {
        let box = try DefaultsBox()
        let (greeting, _) = makeController(defaults: box.defaults)
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
        #expect(greeting.hasBeenShown == false)
    }

    @Test func starButtonOpensRepositoryURL() throws {
        let box = try DefaultsBox()
        var opened: [URL] = []
        let (_, controller) = makeController(defaults: box.defaults) { opened.append($0) }
        controller.openRepository()
        #expect(opened == [WelcomeGreeting.repositoryURL])
    }
}
