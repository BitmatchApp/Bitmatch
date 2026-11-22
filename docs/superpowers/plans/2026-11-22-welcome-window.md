# Welcome Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a one-time, personal welcome panel on the Mac with a "Star on GitHub" button, reopenable from Help, never shown again once dismissed.

**Architecture:** A small `WelcomeGreeting` model owns the UserDefaults flag and the launch decision (pure, testable). A `WelcomeWindowController` owns an `NSPanel` that hosts the SwiftUI `WelcomeView` and marks the greeting seen when the panel closes. `BitMatchApp` wires both: it schedules the launch check after the main window appears and adds two Help menu items.

**Tech Stack:** SwiftUI + AppKit (NSPanel, NSHostingView), Swift Testing, macOS app target only.

**Spec:** `docs/superpowers/specs/2026-11-22-welcome-window-design.md`

## Global Constraints

- UserDefaults key is exactly `BitMatchWelcomeShown`, in `UserDefaults.standard`, injectable for tests.
- The flag is written only when the panel closes, never when it opens.
- Launch delay about 0.5 s after the main window appears; skip (without writing the flag) when an operation or the queue is running.
- Repository URL: `https://github.com/BitmatchApp/Bitmatch`.
- Window: `NSPanel`, titled + closable, not resizable, not floating, does not hide on deactivate, about 440x520, dark appearance.
- Copy and title are the spec's text verbatim, title `Welcome to BitMatch 👋`, sign-off `Thanks for giving it a shot! 👋 Mike`.
- No new Preferences entries, no analytics, no network beyond opening the URL.
- Mac-only by design: the Mac build is the only distributed binary; iOS is build-from-source. Do not touch `BitMatch-iPad`.

## Review Focus

1. The red traffic-light close must mark the greeting seen, same as the buttons. Test: Task 2 asserts `windowWillClose` calls `markShown()`.
2. The main window's `setupWindow` callback fires more than once per launch (view re-hosting, hidden transfer window). The panel must be shown at most once per launch. Test: Task 1 `presentAtLaunchIfNeeded` called twice presents once.
3. Help → Welcome while the panel is already open must bring the existing panel forward, not open a second. Test: Task 2 `show()` twice yields one panel.
4. A launch with a transfer already running defers to the next launch and must not write the flag. Test: Task 1.
5. Reopening from Help after the flag is set must not clear it. Test: Task 2, `show()` then close with the flag already true leaves it true.

---

### Task 1: WelcomeGreeting model

**Files:**
- Create: `BitMatch/App/WelcomeGreeting.swift`
- Test: `BitMatchTests/WelcomeGreetingTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class WelcomeGreeting: ObservableObject {
      static let shownKey = "BitMatchWelcomeShown"
      static let repositoryURL = URL(string: "https://github.com/BitmatchApp/Bitmatch")!
      static let launchDelay: Duration = .milliseconds(500)
      @Published private(set) var hasBeenShown: Bool
      init(defaults: UserDefaults = .standard)
      func markShown()
      /// Decides once per process. Calls `present` only on the first call,
      /// when the greeting is unseen and no transfer is running.
      func presentAtLaunchIfNeeded(transferIsRunning: Bool, present: () -> Void)
  }
  ```

- [ ] **Step 1: Write the failing tests**

Follow `BitMatchTests/GeneralSettingsTests.swift`: a per-test `UserDefaults(suiteName:)` removed in a `defer`.

```swift
@Test func unsetDefaultsMeansNotShown()            // hasBeenShown == false
@Test func markShownPersistsTrue()                  // defaults.bool(forKey: "BitMatchWelcomeShown") == true, hasBeenShown == true
@Test func launchPresentsWhenUnseenAndIdle()        // present called once; hasBeenShown stays false
@Test func launchPresentsAtMostOncePerProcess()     // two calls, present called once
@Test func launchSkipsWhileTransferRunsAndDoesNotMark() // present not called; hasBeenShown false; a later idle call in the same process also does not present
@Test func launchSkipsWhenAlreadyShown()            // defaults pre-set true; present not called
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project BitMatch.xcodeproj -scheme BitMatch -destination 'platform=macOS' \
  -derivedDataPath "/private/tmp/bitmatch-local-tests-$(id -u)/welcome" CODE_SIGNING_ALLOWED=NO \
  test -only-testing:BitMatchTests/WelcomeGreetingTests 2>&1 | tail -20
```
Expected: build failure, `WelcomeGreeting` not found.

- [ ] **Step 3: Implement `WelcomeGreeting` in `BitMatch/App/WelcomeGreeting.swift`**

Keep a `private var launchDecisionMade = false`; set it true on the first `presentAtLaunchIfNeeded` call regardless of outcome.

- [ ] **Step 4: Run tests to verify they pass**

Same command. Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BitMatch/App/WelcomeGreeting.swift BitMatchTests/WelcomeGreetingTests.swift
git commit -m "Add WelcomeGreeting one-time launch policy"
```

---

### Task 2: WelcomeView and WelcomeWindowController

**Files:**
- Create: `BitMatch/Views/WelcomeView.swift`
- Create: `BitMatch/App/WelcomeWindowController.swift`
- Test: `BitMatchTests/WelcomeWindowControllerTests.swift`

**Interfaces:**
- Consumes: `WelcomeGreeting` (Task 1).
- Produces:
  ```swift
  struct WelcomeView: View {
      let starOnGitHub: () -> Void
      let close: () -> Void
  }
  @MainActor final class WelcomeWindowController: NSObject, NSWindowDelegate {
      init(greeting: WelcomeGreeting, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) })
      var panel: NSPanel? { get }        // nil until first show(); nil again after close
      func show()                        // creates or fronts the panel, centers it on first show
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
@Test func showCreatesAPanelThatCannotBecomeMain()   // show(); panel is NSPanel; panel.canBecomeMain == false; styleMask contains .titled and .closable, not .resizable; isFloatingPanel == false; hidesOnDeactivate == false
@Test func showTwiceReusesThePanel()                 // show(); show(); same panel instance
@Test func closingMarksGreetingShown()               // show(); panel.close(); greeting.hasBeenShown == true; controller.panel == nil
@Test func reopeningAfterShownKeepsFlagTrue()        // defaults pre-set true; show(); close(); still true
@Test func starButtonOpensRepositoryURL()            // inject openURL spy; call the controller's star action; spy received WelcomeGreeting.repositoryURL
```
Expose the star action as `func openRepository()` on the controller so the test does not drive SwiftUI.

- [ ] **Step 2: Run tests to verify they fail**

Same command with `-only-testing:BitMatchTests/WelcomeWindowControllerTests`. Expected: build failure.

- [ ] **Step 3: Implement `WelcomeView`**

Layout, top to bottom, 28 pt padding, dark: `Image(nsImage: NSApp.applicationIconImage)` at 96 pt; title `Welcome to BitMatch 👋` in `.title2.bold()`; the spec's four paragraphs as `Text` blocks in `.body` with `.secondary` on all but the first; `Spacer`; an `HStack` with `Button("Star on GitHub")` and `Button("Close")` marked `.keyboardShortcut(.defaultAction)`. Frame 440x520.

- [ ] **Step 4: Implement `WelcomeWindowController`**

`show()` builds `NSPanel(contentRect: 440x520, styleMask: [.titled, .closable], backing: .buffered, defer: false)`, sets `title = "Welcome to BitMatch"`, `titlebarAppearsTransparent = true`, `appearance = NSAppearance(named: .darkAqua)`, `isReleasedWhenClosed = false`, `delegate = self`, `contentView = NSHostingView(rootView: WelcomeView(starOnGitHub: openRepository, close: closePanel))`, `center()`, then `makeKeyAndOrderFront(nil)` and `NSApp.activate(ignoringOtherApps: true)`. `windowWillClose` calls `greeting.markShown()` and drops the reference.

- [ ] **Step 5: Run tests to verify they pass**

Expected: 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add BitMatch/Views/WelcomeView.swift BitMatch/App/WelcomeWindowController.swift BitMatchTests/WelcomeWindowControllerTests.swift
git commit -m "Add the welcome panel and its controller"
```

---

### Task 3: Wire into BitMatchApp and the Help menu

**Files:**
- Modify: `BitMatch/App/BitMatchApp.swift` (properties near line 42, `.commands` near line 104, `setupWindow` near line 201)
- Modify: `CHANGELOG.md` (Unreleased section)

**Interfaces:**
- Consumes: `WelcomeGreeting.presentAtLaunchIfNeeded`, `WelcomeGreeting.launchDelay`, `WelcomeGreeting.repositoryURL`, `WelcomeWindowController.show()`.

- [ ] **Step 1: Add the objects to `BitMatchApp`**

`@StateObject private var welcomeGreeting = WelcomeGreeting()` and a `private let welcomeWindow: WelcomeWindowController` created in `init()` from that greeting (create the greeting as a local first, as the environment is).

- [ ] **Step 2: Schedule the launch check in `setupWindow`**

After `registerContentWindow`, start a `Task { try? await Task.sleep(for: WelcomeGreeting.launchDelay); welcomeGreeting.presentAtLaunchIfNeeded(transferIsRunning: coordinator.isOperationInProgress || coordinator.queueIsRunning) { welcomeWindow.show() } }`. The once-per-process guard lives in the greeting, so repeated `setupWindow` calls are harmless. Skip when `launchesInterfaceLab` or `MacUnitTestHost.isRunning()`.

- [ ] **Step 3: Add the Help menu items**

In `.commands`: `CommandGroup(replacing: .help) { Button("Welcome to BitMatch") { welcomeWindow.show() }; Button("BitMatch on GitHub") { NSWorkspace.shared.open(WelcomeGreeting.repositoryURL) } }`.

- [ ] **Step 4: Build and run the full Mac test job**

Run: `./test.sh mac-build && ./test.sh mac-test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Manual check**

```bash
defaults delete BitMatchApp.BitMatch BitMatchWelcomeShown
```
Launch the Debug app. Expected: main window, then the welcome panel about half a second later; red close button dismisses it; `defaults read BitMatchApp.BitMatch BitMatchWelcomeShown` prints `1`; relaunch shows no panel; Help → Welcome to BitMatch shows it again; Dock click still focuses the main window while the panel is open; Star on GitHub opens the repo in the browser.

- [ ] **Step 6: Changelog and commit**

Add under Unreleased: "A one-time welcome from the maintainer on first launch, reopenable from Help → Welcome to BitMatch."

```bash
git add BitMatch/App/BitMatchApp.swift CHANGELOG.md
git commit -m "Show the welcome panel once at launch and from Help"
```
