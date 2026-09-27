// CaseKeepingResolution.swift - Resolve symlinks without changing letter case.
import Foundation

public extension URL {
    /// `resolvingSymlinksInPath()`, except that a result differing from the
    /// original only in letter case keeps the original spelling.
    ///
    /// On an exFAT card, `resolvingSymlinksInPath` turns Sony's "PRIVATE"
    /// folder into "private" (it special-cases macOS's own /private), while
    /// the copy on an APFS drive keeps "PRIVATE". Every comparison of the two
    /// then saw different files: every Sony card failed result coverage
    /// ("16 files have no result") and ASC MHL records would name the wrong
    /// path. A case-only difference is the same folder on these volumes, so
    /// the engine resolves through this everywhere.
    func resolvingSymlinksKeepingCase() -> URL {
        let original = standardizedFileURL
        let resolved = original.resolvingSymlinksInPath()
        return resolved.path.caseInsensitiveCompare(original.path) == .orderedSame ? original : resolved
    }
}
