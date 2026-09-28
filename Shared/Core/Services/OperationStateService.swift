// OperationStateService.swift - Manages in-process pause/resume state
import Foundation
import Combine
import BitMatchEngine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
class OperationStateService: ObservableObject {
    
    // MARK: - Published State
    /// The one stored state of the current operation. `SharedAppCoordinator.operationState`
    /// reads and writes this; there is no second copy.
    @Published private(set) var currentState: OperationState = .notStarted
    @Published var pauseResumeCapabilities = PauseResumeCapabilities()
    
    // MARK: - Private State
    private var currentOperationId: UUID?

    /// Single source of truth for state-transition legality. `currentState`
    /// stays the published facade; every mutation goes through `applyTransition`.
    private let stateMachine = OperationStateMachine()
    
    // MARK: - Initialization
    
    init() {
        setupSystemNotifications()
    }

    // MARK: - Transition Validation

    @discardableResult
    private func applyTransition(_ newState: OperationState) -> Bool {
        guard stateMachine.transition(to: newState) else {
            SharedLogger.warning("StateService: rejected invalid transition to \(newState)", category: .transfer)
            return false
        }
        currentState = newState
        return true
    }
    
    /// Wired by the coordinator to its real pause, so an automatic pause
    /// stops the engine instead of only relabelling the screen.
    var automaticPauseHandler: ((PauseInfo.PauseReason) -> Void)?

    /// Ask for a pause the user did not request (low battery). Without a
    /// handler nothing can pause the engine, so nothing is claimed.
    func requestAutomaticPause(reason: PauseInfo.PauseReason) {
        guard currentState.canPause else { return }
        guard let automaticPauseHandler else {
            SharedLogger.info("StateService: automatic pause (\(reason)) skipped; nothing can pause the engine", category: .transfer)
            return
        }
        automaticPauseHandler(reason)
    }

    /// Record a state reported by the coordinator or the engine.
    func adopt(_ newState: OperationState) {
        guard currentState != newState else { return }
        stateMachine.adopt(newState)
        currentState = newState
    }

    // MARK: - Operation Lifecycle
    
    func startOperation(id: UUID, sourceURL: URL, destinationURLs: [URL], totalFiles: Int, totalBytes: Int64, verificationMode: String? = nil, mode: String? = nil) {
        currentOperationId = id
        stateMachine.reset()
        applyTransition(.inProgress)

        SharedLogger.info("StateService: started operation id=\(id)", category: .transfer)
    }
    
    func pauseOperation(reason: PauseInfo.PauseReason, currentProgress: OperationProgress?) {
        guard currentOperationId != nil, currentState.canPause else { return }
        
        let pauseInfo = PauseInfo(
            pausedAt: Date(),
            currentFile: currentProgress?.currentFile,
            filesProcessed: currentProgress?.filesProcessed ?? 0,
            totalFiles: currentProgress?.totalFiles ?? 0,
            bytesProcessed: currentProgress?.bytesProcessed ?? 0,
            reason: reason
        )
        
        applyTransition(.paused(pauseInfo))
        
        SharedLogger.info("StateService: paused (reason=\(reason))", category: .transfer)
    }
    
    func resumeOperation() -> Bool {
        guard currentState.canResume, currentOperationId != nil else { return false }
        
        applyTransition(.resuming)
        
        // Transition to active state after brief resuming state
        let expectedOpId = currentOperationId
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.currentOperationId == expectedOpId else { return }
            if self.currentState == .resuming {
                self.applyTransition(.inProgress)
            }
        }
        
        SharedLogger.info("StateService: resumed", category: .transfer)
        return true
    }
    
    /// The current operation's ID if `operationId` names it (or is nil,
    /// meaning "whatever is running"). A stale operation winding down after
    /// a newer one started gets nil, so it cannot end the newer one.
    private func currentOperation(matching operationId: UUID?) -> UUID? {
        guard let current = currentOperationId else { return nil }
        if let operationId, operationId != current {
            SharedLogger.warning("StateService: ignored lifecycle call from stale operation \(operationId)", category: .transfer)
            return nil
        }
        return current
    }

    func completeOperation(operationId requested: UUID? = nil, info: OperationCompletionInfo) {
        guard currentOperation(matching: requested) != nil else { return }

        // Terminal transitions are authoritative: the coordinator's completed
        // callback must agree with the state service, not just clear the ID.
        applyTransition(.completed(info))
        currentOperationId = nil
        SharedLogger.info("StateService: completed and cleaned up", category: .transfer)
    }

    /// Error-path terminal state. Distinct from cancellation so a failed
    /// operation is never reported as cancelled (or vice versa).
    func failOperation(operationId requested: UUID? = nil) {
        guard currentOperation(matching: requested) != nil else { return }

        applyTransition(.failed)

        currentOperationId = nil
        SharedLogger.warning("StateService: failed and cleaned up", category: .transfer)
    }

    func cancelOperation(operationId requested: UUID? = nil) {
        guard currentOperation(matching: requested) != nil else { return }
        
        applyTransition(.cancelled)
        
        currentOperationId = nil
        SharedLogger.warning("StateService: cancelled and cleaned up", category: .transfer)
    }
    
    // MARK: - System Integration
    
    private func setupSystemNotifications() {
        #if canImport(UIKit)
        // iOS background/foreground notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Battery level monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryLevelChanged),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )
        #endif

    }
    
    // MARK: - System Event Handlers
    
    #if canImport(UIKit)
    @objc private func appDidEnterBackground() {
        // Copying continues on background time (IOSBackgroundTaskService);
        // an interrupted run is recovered on relaunch. Claiming a pause here
        // would show "paused" while the engine keeps copying.
        if currentState.canPause {
            SharedLogger.info("StateService: app backgrounded during an operation", category: .transfer)
        }
    }
    
    @objc private func appWillEnterForeground() {
        // Could automatically resume or prompt user
        if currentState.isPaused {
            SharedLogger.info("StateService: app foreground with paused operation", category: .transfer)
        }
    }
    
    @objc private func batteryLevelChanged() {
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel < 0.15 && batteryLevel > 0 && currentState.canPause {
            SharedLogger.warning("StateService: requesting pause (battery=\(Int(batteryLevel * 100))%)", category: .transfer)
            requestAutomaticPause(reason: .lowBattery)
        }
    }
    #endif

    
    // MARK: - Utilities
    
    func updateCapabilities(canPause: Bool, canResume: Bool, estimatedPauseTime: TimeInterval? = nil) {
        pauseResumeCapabilities = PauseResumeCapabilities(
            canPause: canPause,
            canResume: canResume,
            estimatedPauseTime: estimatedPauseTime
        )
    }
    
    func getResumeRecommendation() -> ResumeRecommendation? {
        guard currentState.isPaused else { return nil }
        
        #if os(iOS)
        let batteryLevel = UIDevice.current.batteryLevel
        let isCharging = UIDevice.current.batteryState == .charging
        
        if batteryLevel < 0.20 && !isCharging {
            return ResumeRecommendation(
                shouldResume: false,
                reason: "Low battery (\(Int(batteryLevel * 100))%) - Consider charging before resuming",
                priority: .high
            )
        }
        #endif
        
        return ResumeRecommendation(
            shouldResume: true,
            reason: "Ready to resume",
            priority: .normal
        )
    }

}

// MARK: - Supporting Types

struct PauseResumeCapabilities {
    let canPause: Bool
    let canResume: Bool
    let estimatedPauseTime: TimeInterval?
    
    init(canPause: Bool = false, canResume: Bool = false, estimatedPauseTime: TimeInterval? = nil) {
        self.canPause = canPause
        self.canResume = canResume
        self.estimatedPauseTime = estimatedPauseTime
    }
}

struct ResumeRecommendation {
    let shouldResume: Bool
    let reason: String
    let priority: Priority
    
    enum Priority {
        case low, normal, high
    }
}

// MARK: - Codable conformance for PauseInfo is declared in OperationModels.swift
