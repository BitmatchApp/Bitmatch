// LocalFileAccess.swift - File access for folders the process can already read.
import Foundation

/// `FileAccess` for local folders that need no security scope: the Mac app
/// (not sandboxed) and the engine's own tests. iPad and iPhone use their own
/// service, which opens security-scoped access for picked folders.
public struct LocalFileAccess: FileAccess, Sendable {
    public init() {}

    public func validateFileAccess(url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func startAccessing(url: URL) -> Bool {
        true
    }

    public func stopAccessing(url: URL) {}

    public func getFileList(from folderURL: URL) async throws -> [URL] {
        try await BoundedBlockingExecutor.shared.performCancellable { check in
            try CardSource.enumerateRegularFiles(base: folderURL, checkCancellation: check)
        }.map(\.url)
    }

    public func getFileSize(for url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func freeSpace(at url: URL) -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            return Int64(values.volumeAvailableCapacity ?? 0)
        } catch {
            SharedLogger.error("Error checking free space: \(error)", category: .transfer)
            return 0
        }
    }
}
