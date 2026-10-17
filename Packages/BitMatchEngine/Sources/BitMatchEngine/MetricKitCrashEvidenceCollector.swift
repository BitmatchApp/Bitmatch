import Foundation
import MetricKit

/// MetricKit delivers previous-session diagnostics when Apple makes them
/// available, sometimes much later. This subscriber is intentionally separate
/// from transfer state: a report can never change a transfer's result.
public final class MetricKitCrashEvidenceCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = MetricKitCrashEvidenceCollector(store: .shared)

    private let store: LocalCrashEvidenceStore
    private let lock = NSLock()
    private var subscribed = false

    public init(store: LocalCrashEvidenceStore) {
        self.store = store
    }

    public func configure(enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        store.setEnabled(enabled)
        let shouldSubscribe = enabled && store.collectionToken() != nil
        if shouldSubscribe && !subscribed {
            MXMetricManager.shared.add(self)
            subscribed = true
        } else if !shouldSubscribe && subscribed {
            MXMetricManager.shared.remove(self)
            subscribed = false
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let token = store.collectionToken() else { return }
        for payload in payloads {
            // The callback may race with opt-out or Clear. append checks the
            // original token and the current preference under the store lock.
            for crash in payload.crashDiagnostics ?? [] {
                store.append(Self.crashSummary(crash, payload: payload), token: token)
            }
            for hang in payload.hangDiagnostics ?? [] {
                store.append(Self.hangSummary(hang, payload: payload), token: token)
            }
        }
    }

    private static func crashSummary(_ crash: MXCrashDiagnostic, payload: MXDiagnosticPayload) -> LocalCrashEvidence {
        LocalCrashEvidence(kind: .crash,
            periodBegin: payload.timeStampBegin, periodEnd: payload.timeStampEnd,
            appVersion: crash.applicationVersion, build: crash.metaData.applicationBuildVersion,
            processID: positivePID(crash.metaData.pid), signal: crash.signal?.intValue,
            exceptionType: crash.exceptionType?.intValue, exceptionCode: crash.exceptionCode?.int64Value,
            frames: MetricKitFrameParser.frames(from: crash.callStackTree.jsonRepresentation()))
    }

    private static func hangSummary(_ hang: MXHangDiagnostic, payload: MXDiagnosticPayload) -> LocalCrashEvidence {
        LocalCrashEvidence(kind: .hang,
            periodBegin: payload.timeStampBegin, periodEnd: payload.timeStampEnd,
            appVersion: hang.applicationVersion, build: hang.metaData.applicationBuildVersion,
            processID: positivePID(hang.metaData.pid),
            hangSeconds: hang.hangDuration.converted(to: UnitDuration.seconds).value,
            frames: MetricKitFrameParser.frames(from: hang.callStackTree.jsonRepresentation()))
    }

    private static func positivePID(_ pid: pid_t) -> Int32? { pid > 0 ? pid : nil }
}

/// Parse only symbolication-safe numbers and UUIDs from Apple's stack JSON.
/// In particular, never retain binaryName, absolute address, or raw JSON.
enum MetricKitFrameParser {
    static func frames(from data: Data) -> [LocalCrashEvidence.Frame] {
        guard data.count <= 1_000_000,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tree = root["callStackTree"] as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return [] }

        // If Apple does not identify an attributed thread, don't guess one.
        guard let attributed = stacks.first(where: { $0["threadAttributed"] as? Bool == true }),
              let roots = attributed["callStackRootFrames"] as? [[String: Any]] else { return [] }
        var pending = Array(roots.prefix(16).reversed())
        var result: [LocalCrashEvidence.Frame] = []
        var visited = 0
        while let frame = pending.popLast(), result.count < 8, visited < 64 {
            visited += 1
            if let rawUUID = frame["binaryUUID"] as? String,
               let uuid = UUID(uuidString: rawUUID),
               let number = frame["offsetIntoBinaryTextSegment"] as? NSNumber,
               number.int64Value >= 0 {
                result.append(.init(binaryUUID: uuid, offset: number.uint64Value))
            }
            if let children = frame["subFrames"] as? [[String: Any]] {
                pending.append(contentsOf: children.prefix(16).reversed())
            }
        }
        return result
    }
}
