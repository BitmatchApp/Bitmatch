// BitMatchApp.swift - Main app with dark theme configuration
import AppKit
import BitMatchEngine
import SwiftUI
import UserNotifications

// Visual effect for window background
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Custom window styling
struct CustomWindowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(VisualEffect(material: .hudWindow, blendingMode: .behindWindow))
    }
}

extension View {
    func customWindowStyle() -> some View {
        self.modifier(CustomWindowStyle())
    }
}

@main
struct BitMatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var environment: MacAppEnvironment
    @StateObject private var updater: UpdaterController
    #if DEBUG
    @ObservedObject private var devModeManager = DevModeManager.shared
    #endif
    private let notifDelegate = NotificationDelegate()
    // InterfaceLab is a development tool: the launch path is DEBUG-only so a
    // stray --interface-lab argument can never swap the Release UI.
    private let launchesInterfaceLab: Bool = {
#if DEBUG
        InterfaceLabLaunchConfiguration.isRequested(
            arguments: ProcessInfo.processInfo.arguments
        )
#else
        false
#endif
    }()

    init() {
        let environment = MacAppEnvironment.make()
        _environment = StateObject(wrappedValue: environment)
        _updater = StateObject(wrappedValue: UpdaterController(coordinator: environment.coordinator))
        appDelegate.coordinator = environment.coordinator
        UNUserNotificationCenter.current().delegate = notifDelegate
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if launchesInterfaceLab { InterfaceLabView() }
                else { ContentView(environment: environment).preferredColorScheme(.dark) }
#else
                ContentView(environment: environment).preferredColorScheme(.dark)
#endif
            }
            .onAppear {
                appDelegate.coordinator = environment.coordinator
                setupWindow()
            }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            OperationCommands()
            
            // Into the system View menu: a CommandMenu("View") adds a second one.
            CommandGroup(before: .toolbar) {
                Button(AppMode.copyAndVerify.shortTitle) {
                    NotificationCenter.default.post(name: .switchToCopyMode, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)
                
                Button(AppMode.compareFolders.shortTitle) {
                    NotificationCenter.default.post(name: .switchToCompareMode, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)
                
                Button(AppMode.masterReport.shortTitle) {
                    NotificationCenter.default.post(name: .switchToMasterReportMode, object: nil)
                }
                .keyboardShortcut("3", modifiers: .command)
                Divider()
            }
            
            #if DEBUG
            CommandMenu("Developer") {
                Button("Open Interface Lab") {
                    InterfaceLabLauncher.open()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])

                Divider()

                Button(devModeManager.isDevModeEnabled ? "Disable Dev Mode" : "Enable Dev Mode") {
                    devModeManager.isDevModeEnabled.toggle()
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                
                Divider()
                
                Button("Fill Test Data") {
                    NotificationCenter.default.post(name: .fillTestData, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!devModeManager.isDevModeEnabled)
                

                Divider()
                // Real files in temp folders, no fake data: available
                // whenever this menu is, with dev mode on or off.
                Button("Stress Test (Small)") { devModeManager.runStressTest(preset: .small) }
                    .disabled(devModeManager.isStressTestRunning)
                Button("Stress Test (Medium)") { devModeManager.runStressTest(preset: .medium) }
                    .disabled(devModeManager.isStressTestRunning)
                Button("Stress Test (Large)") { devModeManager.runStressTest(preset: .large) }
                    .disabled(devModeManager.isStressTestRunning)

                Divider()
                Toggle("Verbose Dev Logs", isOn: $devModeManager.verboseLogs)
                    .disabled(!devModeManager.isDevModeEnabled)
                
                Divider()
                
                Button("Clear All Data") {
                    NotificationCenter.default.post(name: .clearTestData, object: nil)
                }
                .disabled(!devModeManager.isDevModeEnabled)
            }
            #endif
        }

        Settings {
            PreferencesWindow(
                coordinator: environment.coordinator,
                cameraAutoSource: environment.cameraAutoSource,
                remoteBackups: environment.remoteBackups,
                updater: updater
            )
            .macCompanions(environment)
        }
    }
    
    private func setupWindow() {
        DispatchQueue.main.async {
            if let window = AppDelegate.contentWindowCandidate() {
                // Configure window appearance
                window.title = "BitMatch"
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                if WindowPresentationPolicy.allowsManualResizing {
                    window.styleMask.insert(.resizable)
                }
                window.isMovableByWindowBackground = true
                window.backgroundColor = .windowBackgroundColor
                
                // Start compact, then let the workbench grow into a proper review surface.
                window.setContentSize(NSSize(width: WindowPresentationPolicy.initialWidth, height: WindowPresentationPolicy.initialHeight))
                window.minSize = NSSize(width: WindowPresentationPolicy.minimumWidth, height: WindowPresentationPolicy.minimumHeight)
                window.maxSize = NSSize(width: WindowPresentationPolicy.maximumWidth, height: WindowPresentationPolicy.maximumHeight)
                
                // Make window fully opaque
                window.isOpaque = true
                window.alphaValue = 1.0
                window.hasShadow = true
                
                // Set window level
                window.level = .normal
                window.delegate = appDelegate
                appDelegate.registerContentWindow(window)
                
                let savedFrame = UserDefaults.standard.dictionary(forKey: "BitMatch.windowFrame")
                let hasSavedPlacement = savedFrame?["x"] as? CGFloat != nil
                    && savedFrame?["y"] as? CGFloat != nil
                if WindowPresentationPolicy.shouldCenterWindow(
                    hasSavedPlacement: hasSavedPlacement,
                    isInterfaceLab: launchesInterfaceLab
                ) {
                    window.center()
                }
            }
        }
    }
}

/// File menu transfer commands. The composer is always present, so there is
/// no New Transfer command; Eject exists only for a safe, removable card.
struct OperationCommands: Commands {
    @FocusedValue(\.canCancelOperation) private var canCancelOperation
    @FocusedValue(\.ejectCardTitle) private var ejectCardTitle

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
        }

        // Into the system File menu, so it keeps its place; a
        // CommandMenu("File") adds a second File menu after View.
        CommandGroup(after: .newItem) {
            Button("Start") {
                NotificationCenter.default.post(name: .startVerification, object: nil)
            }
            .keyboardShortcut(.return, modifiers: .command)

            Divider()

            Button(ejectCardTitle ?? TransferMenuPresentation.unavailableEjectTitle) {
                NotificationCenter.default.post(name: .ejectCard, object: nil)
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(ejectCardTitle == nil)

            Divider()

            Button("Cancel Operation…") {
                NotificationCenter.default.post(name: .cancelOperation, object: nil)
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(canCancelOperation != true)
        }
    }
}

/// Published by the main window so the File menu knows whether anything runs.
struct CanCancelOperationKey: FocusedValueKey {
    typealias Value = Bool
}

struct EjectCardTitleKey: FocusedValueKey {
    typealias Value = String
}

extension FocusedValues {
    var canCancelOperation: Bool? {
        get { self[CanCancelOperationKey.self] }
        set { self[CanCancelOperationKey.self] = newValue }
    }

    var ejectCardTitle: String? {
        get { self[EjectCardTitleKey.self] }
        set { self[EjectCardTitleKey.self] = newValue }
    }
}

// App Delegate for early setup
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var coordinator: SharedAppCoordinator?
    private weak var contentWindow: NSWindow?
    private weak var windowAllowedToClose: NSWindow?
    private var exitGuard = TransferExitGuardStateMachine()
    private var exitGuardAlert: NSAlert?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Disable window restoration to avoid className=(null) warnings
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch exitGuard.request(needsGuard: shouldAskToStopTransfer) {
        case .allowNow:
            return .terminateNow
        case .presentPrompt:
            presentExitGuard(for: .quit(sender))
            return .terminateLater
        case .keepWaiting:
            NSSound.beep()
            exitGuardAlert?.window.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if windowAllowedToClose === sender {
            windowAllowedToClose = nil
            return true
        }
        switch exitGuard.request(needsGuard: shouldAskToStopTransfer) {
        case .allowNow:
            return true
        case .presentPrompt:
            presentExitGuard(for: .close(sender))
            return false
        case .keepWaiting:
            NSSound.beep()
            exitGuardAlert?.window.makeKeyAndOrderFront(nil)
            return false
        }
    }

    private var shouldAskToStopTransfer: Bool {
        guard let coordinator else {
            assertionFailure("The app delegate must receive the shared coordinator before a window can close or the app can quit.")
            return true
        }
        return TransferExitGuardPolicy.shouldAsk(
            isOperationInProgress: coordinator.isOperationInProgress,
            queueIsRunning: coordinator.queueIsRunning,
            isCopyAndVerifyMode: coordinator.currentMode == .copyAndVerify,
            lastOperationWasCompare: coordinator.lastOperationWasCompare
        )
    }

    private enum ExitAction {
        case close(NSWindow)
        case quit(NSApplication)
    }

    private func presentExitGuard(for action: ExitAction) {
        let alert = NSAlert()
        alert.messageText = TransferExitGuardPolicy.title
        alert.informativeText = TransferExitGuardPolicy.message
        alert.addButton(withTitle: TransferExitGuardPolicy.keepCopyingTitle)
        let stopButton = alert.addButton(withTitle: TransferExitGuardPolicy.stopTransferTitle)
        stopButton.hasDestructiveAction = true
        exitGuardAlert = alert

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.exitGuardAlert = nil
            let choice: TransferExitGuardStateMachine.Choice = response == .alertSecondButtonReturn
                ? .stopTransfer : .keepCopying
            let actionKind: TransferExitGuardStateMachine.Action
            switch action {
            case .quit: actionKind = .quit
            case .close: actionKind = .closeWindow
            }
            switch self.exitGuard.resolve(choice, for: actionKind) {
            case .denyExit:
                if case .quit(let application) = action {
                    application.reply(toApplicationShouldTerminate: false)
                }
            case .allowExit:
                self.finish(action: action, allowExit: true)
            case .requestCancellation:
                self.cancelAndSettle(action: action)
            }
        }

        let window = contentWindow ?? Self.contentWindowCandidate()
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    private func cancelAndSettle(action: ExitAction) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let coordinator else {
                    throw SharedAppCoordinator.CancellationSettlementError.journalRecordMissing
                }
                let origin: TransferCancelOrigin
                switch action { case .quit: origin = .appQuit; case .close: origin = .windowClose }
                try await coordinator.cancelOperationAndWaitForSettlement(origin: origin)
                _ = exitGuard.settlementFinished(success: true)
                finish(action: action, allowExit: true)
            } catch {
                _ = exitGuard.settlementFinished(success: false)
                finish(action: action, allowExit: false)
                presentSettlementError(error.localizedDescription)
            }
        }
    }

    private func finish(action: ExitAction, allowExit: Bool) {
        switch action {
        case .quit(let application):
            application.reply(toApplicationShouldTerminate: allowExit)
        case .close(let window):
            guard allowExit else { return }
            close(window)
        }
    }

    private func close(_ window: NSWindow) {
        windowAllowedToClose = window
        window.performClose(nil)
        // `performClose` normally re-enters `windowShouldClose` synchronously.
        // Clear defensively if AppKit declines before asking the delegate.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.windowAllowedToClose === window else { return }
            self.windowAllowedToClose = nil
        }
    }

    private func presentSettlementError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Save the Interrupted Transfer"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = contentWindow ?? Self.contentWindowCandidate() {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    func registerContentWindow(_ window: NSWindow) {
        contentWindow = window
    }

    static func contentWindowCandidate() -> NSWindow? {
        if let key = NSApplication.shared.keyWindow, isContentWindow(key) { return key }
        if let main = NSApplication.shared.mainWindow, isContentWindow(main) { return main }
        return NSApplication.shared.windows.first(where: isContentWindow)
    }

    private static func isContentWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain && window.contentViewController != nil
    }
}

// NOTE: Notification.Name extensions are defined in ContentView.swift
// - startVerification
// - cancelOperation
// - switchToCopyMode
// - switchToCompareMode
// - switchToMasterReportMode
