// BitMatch_iPadApp.swift - iPad app entry point
import SwiftUI
import UserNotifications
import BitMatchEngine
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

@main
struct BitMatch_iPadApp: App {
    private let notifDelegate = NotificationDelegate()
    
    init() {
        SharedLogger.transferEvent(.appStarted, run: nil)
        UNUserNotificationCenter.current().delegate = notifDelegate
        // Register background task handler (Info.plist contains permitted identifier)
        registerBackgroundTasks()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    private func registerBackgroundTasks() {
        #if canImport(BackgroundTasks)
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.bitmatch.app.transferprocessing", using: nil) { task in
                guard let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                // Minimal handler: schedule next and complete.
                let request = BGProcessingTaskRequest(identifier: "com.bitmatch.app.transferprocessing")
                request.requiresExternalPower = false
                request.requiresNetworkConnectivity = false
                _ = try? BGTaskScheduler.shared.submit(request)
                processing.setTaskCompleted(success: true)
            }
        }
        #endif
    }
}
