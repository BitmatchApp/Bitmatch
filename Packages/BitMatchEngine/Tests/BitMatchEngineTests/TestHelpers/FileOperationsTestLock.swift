import Foundation
@testable import BitMatchEngine

actor FileOperationsTestLock {
    static let shared = FileOperationsTestLock()

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        // Ordinary synthetic transfers must not write into the user's real
        // diagnostic ring. Preserve any explicitly supplied outer test store.
        if TransferDiagnostics.recordingStoreOverride != nil { return try await operation() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-engine-diagnostics-\(UUID())")
        let store = TransferDiagnosticStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
            try await operation()
        }
    }
}
