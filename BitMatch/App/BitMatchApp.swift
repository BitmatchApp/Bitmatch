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
    @State private var menuBarExtraIsInserted = true
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
        SharedLogger.transferEvent(.appStarted, run: nil)
        #if DEBUG
        let isUnitTestHost = MacUnitTestHost.isRunning()
        if isUnitTestHost { MacUnitTestHost.clearState() }
        let environment = isUnitTestHost ? MacAppEnvironment.makeForUnitTestHost() : MacAppEnvironment.make()
        #else
        let environment = MacAppEnvironment.make()
        #endif
        #if DEBUG
        if !MacUnitTestHost.isRunning() {
            MetricKitCrashEvidenceCollector.shared.configure(
                enabled: UserDefaults.standard.bool(forKey: LocalCrashEvidenceStore.consentKey))
        }
        #else
        MetricKitCrashEvidenceCollector.shared.configure(
            enabled: UserDefaults.standard.bool(forKey: LocalCrashEvidenceStore.consentKey))
        #endif
        _environment = StateObject(wrappedValue: environment)
        _updater = StateObject(wrappedValue: UpdaterController(coordinator: environment.coordinator))
        appDelegate.coordinator = environment.coordinator
        UNUserNotificationCenter.current().delegate = notifDelegate
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
#if DEBUG
                if launchesInterfaceLab { InterfaceLabView() }
                else { ContentView(environment: environment).preferredColorScheme(.dark) }
#else
                ContentView(environment: environment).preferredColorScheme(.dark)
#endif
            }
            .background(MainWindowAccessor { window in
                setupWindow(window)
            })
            .onAppear {
                appDelegate.coordinator = environment.coordinator
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

        MenuBarExtra(isInserted: $menuBarExtraIsInserted) {
            MacMenuBarCompanion(
                coordinator: environment.coordinator,
                appDelegate: appDelegate
            )
        } label: {
            MacMenuBarStatusLabel(coordinator: environment.coordinator)
        }
        .menuBarExtraStyle(.window)

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
    
    private func setupWindow(_ mainWindow: NSWindow) {
        DispatchQueue.main.async {
            let window = mainWindow
            if window.delegate === appDelegate {
                appDelegate.registerContentWindow(window)
                return
            }
            // The view belongs to this WindowGroup scene. A Settings window
            // can become key before this deferred setup runs, so configure
            // the captured scene window rather than searching all app windows.
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

            window.isOpaque = true
            window.alphaValue = 1.0
            window.hasShadow = true
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

/// Reports the NSWindow that actually hosts the main SwiftUI scene. Looking
/// up the key window here can select Settings or another ordinary window.
struct MainWindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowObserverView, context: Context) {
        view.onWindow = onWindow
    }

    final class WindowObserverView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
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
    /// Keep the actual SwiftUI window mounted while a transfer runs out of sight.
    private var hiddenTransferWindow: NSWindow?
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

    func applicationWillTerminate(_ notification: Notification) {
        SharedLogger.transferEvent(.appEnded, run: nil)
        #if DEBUG
        if MacUnitTestHost.isRunning() { MacUnitTestHost.clearState() }
        #endif
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
        switch MacMainWindowClosePolicy.action(transferRequiresSettlement: shouldAskToStopTransfer) {
        case .close:
            return true
        case .hideAndContinue:
            hiddenTransferWindow = sender
            sender.orderOut(nil)
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if contentWindow === window { contentWindow = nil }
        if hiddenTransferWindow === window { hiddenTransferWindow = nil }
    }

    /// Used by the menu bar and Dock. Focus the mounted view (whether visible
    /// or hidden) instead of asking WindowGroup to create another one.
    @discardableResult
    func focusExistingContentWindow() -> Bool {
        guard let window = hiddenTransferWindow ?? contentWindow else { return false }
        hiddenTransferWindow = nil
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // We handled an existing window ourselves. Otherwise let AppKit and
        // WindowGroup create the main window after an ordinary idle close.
        return !focusExistingContentWindow()
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
            switch self.exitGuard.resolve(choice, for: .quit) {
            case .denyExit:
                if case .quit(let application) = action { application.reply(toApplicationShouldTerminate: false) }
            case .allowExit:
                self.finish(action: action, allowExit: true)
            case .requestCancellation:
                self.cancelAndSettle(action: action)
            }
        }

        // Quit can come from the menu bar while the transfer window is hidden.
        // Bring it back before attaching the settlement sheet.
        _ = focusExistingContentWindow()
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
                try await coordinator.cancelOperationAndWaitForSettlement(origin: .appQuit)
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
        }
    }

    private func presentSettlementError(_ message: String) {
        _ = focusExistingContentWindow()
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
