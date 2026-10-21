// PathContainment.swift - The one rule for "is this path inside that folder".
import Foundation

/// Every containment and same-folder check in the engine uses this rule:
/// compare path components (never raw prefixes, so "/Volumes/T7" does not
/// contain "/Volumes/T70"), with "/private/var", "/private/etc" and
/// "/private/tmp" treated as the "/var", "/etc" and "/tmp" macOS aliases
/// them to. This normalizes path text only and never checks whether any
/// component exists. Callers resolve symlinks first when they need to.
public enum PathContainment: Sendable {
    /// Returns absolute, lexically normalized components. Relative paths are
    /// anchored to the process working directory; no URL standardization or
    /// filesystem lookup occurs here. `..` is reduced lexically, so callers
    /// must resolve symlinks before calling when filesystem identity matters.
    public static func comparableComponents(_ path: String) -> [String] {
        var components: [String] = []

        if !path.hasPrefix("/") {
            appendLexicalComponents(FileManager.default.currentDirectoryPath, to: &components)
        }
        appendLexicalComponents(path, to: &components)

        // These are fixed macOS aliases. Apply after resolving dot segments,
        // and regardless of whether the path currently exists.
        if components.count >= 2,
           components[0] == "private",
           ["var", "etc", "tmp"].contains(components[1]) {
            components.removeFirst()
        }

        return ["/"] + components
    }

    private static func appendLexicalComponents(_ path: String, to components: inout [String]) {
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(String(component))
        }
    }

    /// The path as the rule compares it.
    public static func comparablePath(_ path: String) -> String {
        let components = comparableComponents(path)
        guard components.first == "/" else { return components.joined(separator: "/") }
        return "/" + components.dropFirst().joined(separator: "/")
    }

    public static func isSamePath(_ first: String, _ second: String) -> Bool {
        comparableComponents(first) == comparableComponents(second)
    }

    /// `candidate` is `root` or inside it.
    public static func isWithin(_ candidate: String, root: String) -> Bool {
        let candidateComponents = comparableComponents(candidate)
        let rootComponents = comparableComponents(root)
        guard candidateComponents.count >= rootComponents.count else { return false }
        return zip(rootComponents, candidateComponents).allSatisfy(==)
    }

    /// `candidate` is inside `root` and is not `root` itself.
    public static func isStrictlyWithin(_ candidate: String, root: String) -> Bool {
        comparableComponents(candidate).count > comparableComponents(root).count
            && isWithin(candidate, root: root)
    }
}
