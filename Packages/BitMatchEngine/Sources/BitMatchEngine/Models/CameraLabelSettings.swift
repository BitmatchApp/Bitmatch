// CameraLabelSettings.swift - Decides each backup's destination folder (a safety input).
import Foundation

// MARK: - Camera Label Settings
public struct CameraLabelSettings: Codable, Sendable {
    public var label: String = ""
    public var position: LabelPosition = .prefix
    public var separator: Separator = .underscore
    public var autoNumber: Bool = true
    public var groupByCamera: Bool = false
    public var generateUniqueName: Bool = true
    public var destinationPathComponents: [String]? = nil
    /// Reviewed selection carried by this legacy transfer-settings container.
    /// nil preserves all files and decodes older queued transfers safely.
    public var excludedAppleDoublePaths: [String]? = nil

    /// Sanitizes a string for safe use as a folder/file name component.
    /// Prevents path traversal attacks and removes dangerous characters.
    /// Security considerations addressed:
    /// - URL-encoded traversal attempts (including double-encoding)
    /// - Path separators (/, \)
    /// - Traversal components (., ..)
    /// - Control characters (ASCII 0-31 and DEL 0x7F)
    /// - Length limits for filesystem compatibility
    public static func sanitizePathComponent(_ input: String) -> String {
        // Step 1: Loop-decode URL-encoded input to catch double-encoding attacks
        // e.g., %252e%252e → %2e%2e → ..
        var decoded = input
        var iterations = 0
        let maxIterations = 5  // Prevent infinite loops on malformed input
        while let newDecoded = decoded.removingPercentEncoding,
              newDecoded != decoded,
              iterations < maxIterations {
            decoded = newDecoded
            iterations += 1
        }

        // Step 2: Remove control characters (ASCII 0-31 and DEL 0x7F)
        let controlCharsRemoved = String(decoded.unicodeScalars.filter {
            $0.value >= 32 && $0.value != 0x7F
        })

        // Step 3: Replace path separators with underscores
        let separatorsReplaced = controlCharsRemoved
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        // Step 4: Split into components, filter out traversal attempts, rejoin
        let validComponents = separatorsReplaced
            .components(separatedBy: "_")
            .filter { component in
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                // Reject empty, ".", and ".." components
                return !trimmed.isEmpty && trimmed != "." && trimmed != ".."
            }

        var result = validComponents.joined(separator: "_")

        // Step 5: Enforce maximum length (200 bytes UTF-8)
        let maxBytes = 200
        if result.utf8.count > maxBytes {
            var endIndex = result.endIndex
            while result[..<endIndex].utf8.count > maxBytes && endIndex > result.startIndex {
                endIndex = result.index(before: endIndex)
            }
            result = String(result[..<endIndex])
        }

        // Step 6: Return fallback if result is empty to prevent parent directory access
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "untitled"
        }

        return result
    }

    public func formattedFolderName(for baseName: String) -> String {
        let rawBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = rawBase.isEmpty ? "" : Self.sanitizePathComponent(rawBase)
        let trimmedLabel = rawLabel.isEmpty ? "" : Self.sanitizePathComponent(rawLabel)
        
        switch (trimmedLabel.isEmpty, trimmedBase.isEmpty) {
        case (true, _):
            return trimmedBase
        case (false, true):
            return trimmedLabel
        case (false, false):
            let sep = separator.rawValue
            switch position {
            case .prefix:
                return sep.isEmpty ? trimmedLabel + trimmedBase : "\(trimmedLabel)\(sep)\(trimmedBase)"
            case .suffix:
                return sep.isEmpty ? trimmedBase + trimmedLabel : "\(trimmedBase)\(sep)\(trimmedLabel)"
            }
        }
    }
    
    public enum LabelPosition: String, CaseIterable, Codable, Sendable {
        case prefix = "Prefix"
        case suffix = "Suffix"
    }
    
    public enum Separator: String, CaseIterable, Codable, Sendable {
        case underscore = "_"
        case dash = "-"
        case dot = "."
        case space = " "
        
        public var displayName: String {
            switch self {
            case .underscore: return "Underscore (_)"
            case .dash: return "Dash (-)"
            case .dot: return "Dot (.)"
            case .space: return "Space ( )"
            }
        }
    }

    public init(label: String = "", position: LabelPosition = .prefix, separator: Separator = .underscore, autoNumber: Bool = true, groupByCamera: Bool = false, generateUniqueName: Bool = true, destinationPathComponents: [String]? = nil) {
        self.label = label
        self.position = position
        self.separator = separator
        self.autoNumber = autoNumber
        self.groupByCamera = groupByCamera
        self.generateUniqueName = generateUniqueName
        self.destinationPathComponents = destinationPathComponents
    }
}
