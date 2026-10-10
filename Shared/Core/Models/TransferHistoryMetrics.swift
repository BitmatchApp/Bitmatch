import Foundation
import BitMatchEngine

struct TransferHistoryMetric: Equatable, Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

/// Recorded rows describe retained evidence, not an inferred complete source inventory.
enum TransferHistoryMetrics {
    static func make(_ record: LocalTransferRecord) -> [TransferHistoryMetric] {
        func date(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .shortened) ?? "—" }
        func duration(_ seconds: TimeInterval?) -> String {
            guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
            let formatter = DateComponentsFormatter()
            formatter.allowedUnits = [.hour, .minute, .second]
            formatter.unitsStyle = .abbreviated
            return formatter.string(from: seconds) ?? "—"
        }
        let files = Dictionary(grouping: record.results, by: \.path).values.compactMap(\.first)
        var bytes: Int64 = 0
        var validSize = true
        for row in files {
            let sum = bytes.addingReportingOverflow(max(0, row.size))
            if sum.overflow { validSize = false; break }
            bytes = sum.partialValue
        }
        let speed: String
        if let copyBytes = record.performanceTelemetry?.copyBytes, copyBytes >= 0,
           let seconds = record.copyDurationSeconds, seconds.isFinite, seconds > 0 {
            speed = String(format: "%.1f MB/s", Double(copyBytes) / seconds / 1_048_576)
        } else { speed = "—" }
        return [
            .init(title: "Started", value: date(record.startedAt)),
            .init(title: "Finished", value: date(record.endedAt)),
            .init(title: "Recorded source files", value: files.count.formatted()),
            .init(title: "Recorded source size", value: validSize ? ByteCountPresentation.fileSize(bytes) : "—"),
            .init(title: "Copy", value: duration(record.copyDurationSeconds)),
            .init(title: "Verify", value: record.verificationMode == .quick ? "Not performed (Quick)" : duration(record.verifyDurationSeconds)),
            .init(title: "Average copy speed (all backups)", value: speed)
        ]
    }
}
