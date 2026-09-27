import Foundation

public extension URL {
    func relativePath(to base: URL) -> String {
        let base = base.standardizedFileURL.resolvingSymlinksKeepingCase()
        let me = self.standardizedFileURL.resolvingSymlinksKeepingCase()
        let a = base.pathComponents
        let b = me.pathComponents
        guard b.starts(with: a) else { return self.lastPathComponent }
        return b.dropFirst(a.count).joined(separator: "/")
    }

    func isAncestor(of other: URL) -> Bool {
        let a = standardizedFileURL.resolvingSymlinksKeepingCase().pathComponents
        let b = other.standardizedFileURL.resolvingSymlinksKeepingCase().pathComponents
        return b.starts(with: a)
    }

    func nonConflictingSibling(maxAttempts: Int = 9_999) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return self }

        let directory = deletingLastPathComponent()
        let baseName = deletingPathExtension().lastPathComponent
        let ext = pathExtension

        for index in 2...maxAttempts {
            var candidate = directory.appendingPathComponent("\(baseName)-\(index)")
            if !ext.isEmpty {
                candidate = candidate.appendingPathExtension(ext)
            }
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        var fallback = directory.appendingPathComponent("\(baseName)-\(UUID().uuidString)")
        if !ext.isEmpty {
            fallback = fallback.appendingPathExtension(ext)
        }
        return fallback
    }
}
