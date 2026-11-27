import Foundation

/// Names produced by report publication and withdrawal. Historical report
/// discovery remains deliberately broader than this working-file grammar.
enum ReportName {
    private static let prefix = "BitMatch_Report_"
    private static let withdrawnPrefix = ".unsettled-"

    static func fileName(finished: Date, pathExtension: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        let timestamp = formatter.string(from: finished).replacingOccurrences(of: ":", with: "-")
        return "\(prefix)\(timestamp).\(pathExtension)"
    }

    static func stem(base: String, collision: Int) -> String {
        base + (collision <= 1 ? "" : "-\(collision)")
    }

    static func withdrawnName(report: String, recordID: UUID, collision: Int = 0) -> String {
        withdrawnPrefix + recordID.uuidString + "-" + report + (collision > 0 ? "-\(collision)" : "")
    }

    static func validSuffix<S: StringProtocol>(_ digits: S, minimum: Int) -> Bool {
        guard !digits.isEmpty, digits.first != "0",
              digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        if minimum == 2 && String(digits) == "1" { return false }
        return true
    }

    /// Returns the report filename without a withdrawal collision suffix.
    static func withdrawnReport(_ name: String) -> String? {
        guard name.hasPrefix(withdrawnPrefix) else { return nil }
        let remainder = String(name.dropFirst(withdrawnPrefix.count))
        guard remainder.count > 37 else { return nil }
        let end = remainder.index(remainder.startIndex, offsetBy: 36)
        let uuidText = String(remainder[..<end])
        guard let id = UUID(uuidString: uuidText), id.uuidString == uuidText,
              remainder[end] == "-" else { return nil }
        let report = String(remainder[remainder.index(after: end)...])
        guard report.hasPrefix(prefix) else { return nil }
        let tail = String(report.dropFirst(prefix.count))
        guard tail.utf8.count >= 20 else { return nil }
        let timestamp = String(tail.prefix(20))
        let bytes = Array(timestamp.utf8)
        guard bytes.count == 20 else { return nil }
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 45, 16: 45, 19: 90]
        for (index, byte) in bytes.enumerated() {
            if let expected = separators[index] {
                guard byte == expected else { return nil }
            } else if !(48...57).contains(byte) { return nil }
        }
        let iso = timestamp.replacingOccurrences(of: "-", with: ":", range: timestamp.index(timestamp.startIndex, offsetBy: 13)..<timestamp.index(timestamp.startIndex, offsetBy: 19))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = .withInternetDateTime
        guard let date = formatter.date(from: iso), formatter.string(from: date) == iso else { return nil }
        var rest = String(tail.dropFirst(20))
        if rest.hasPrefix("-") {
            rest.removeFirst()
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard validSuffix(digits, minimum: 2) else { return nil }
            rest.removeFirst(digits.count)
        }
        let extensions = ["json", "pdf", "csv"] + ChecksumAlgorithm.allCases.map { $0.rawValue.lowercased() + ".txt" }
        for ext in extensions {
            let expected = "." + ext
            guard rest.hasPrefix(expected) else { continue }
            let suffix = rest.dropFirst(expected.count)
            guard suffix.isEmpty || (suffix.first == "-" && validSuffix(suffix.dropFirst(), minimum: 1)) else { continue }
            return String(report.dropLast(suffix.count))
        }
        return nil
    }
}
