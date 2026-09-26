import Foundation

/// File-size wording used by presentation models. Empty content is named,
/// rather than rendered as a zero-byte unit that varies by locale.
enum ByteCountPresentation {
    static func fileSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func capacity(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "No space" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
