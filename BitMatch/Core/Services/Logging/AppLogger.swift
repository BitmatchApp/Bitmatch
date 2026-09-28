// Core/Services/Logging/AppLogger.swift
import Foundation
import BitMatchEngine
// Forward AppLogger calls to shared logger to consolidate logging


/// Centralized logging system for the app
enum AppLogger {
    
    enum Category: String, CaseIterable {
        case general = "General"
        case fileOps = "FileOperations"
        case transfer = "Transfer"
        case ui = "UI"
        case devMode = "DevMode"
        case error = "Error"
    }
    
    enum Level {
        case debug, info, warning, error
        
        var prefix: String {
            switch self {
            case .debug: return "🔍"
            case .info: return "ℹ️"
            case .warning: return "⚠️"
            case .error: return "🚨"
            }
        }
    }
    
    // Map AppLogger.Category to SharedLogger.Category where relevant
    private static func sharedCategory(_ category: Category) -> SharedLogger.Category {
        switch category {
        case .general: return .general
        case .fileOps: return .transfer
        case .transfer: return .transfer
        case .ui: return .ui
        case .devMode: return .general
        case .error: return .error
        }
    }
    
    // MARK: - Public Logging Methods
    
    static func debug(_ message: String, category: Category = .general, file: String = #file, line: Int = #line) {
        log(level: .debug, message: message, category: category, file: file, line: line)
    }
    
    static func info(_ message: String, category: Category = .general) {
        log(level: .info, message: message, category: category)
    }
    
    static func warning(_ message: String, category: Category = .general) {
        log(level: .warning, message: message, category: category)
    }
    
    static func error(_ message: String, category: Category = .error, error: Error? = nil) {
        let fullMessage = error != nil ? "\(message) - \(error!.localizedDescription)" : message
        log(level: .error, message: fullMessage, category: category)
    }
    
    // MARK: - Dev mode logging
    
    static func devMode(_ message: String) {
        info("🎭 Dev Mode: \(message)", category: .devMode)
    }
    
    // MARK: - Private implementation
    
    private static func log(level: Level, message: String, category: Category, file: String = #file, line: Int = #line) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        
        let logMessage = level == .debug ? 
            "\(level.prefix) [\(fileName):\(line)] \(message)" : 
            "\(level.prefix) \(message)"
        
        let cat = sharedCategory(category)
        switch level {
        case .debug:
            SharedLogger.debug(logMessage, category: cat)
        case .info:
            SharedLogger.info(logMessage, category: cat)
        case .warning:
            SharedLogger.warning(logMessage, category: cat)
        case .error:
            SharedLogger.error(logMessage, category: .error)
        }
    }
}
