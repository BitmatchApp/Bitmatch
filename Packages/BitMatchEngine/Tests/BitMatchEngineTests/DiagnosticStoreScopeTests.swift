import Foundation
import Testing
@testable import BitMatchEngine

struct DiagnosticStoreScopeTests {
    @Test func unstructuredAndGroupChildrenInheritTheRecordingStore() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferDiagnosticStore(directory: root)
        let run = UUID()
        await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
            SharedLogger.verifyEvent(.verifyStarted, run: run, ordinal: 1, destinationIndex: 0, bytes: 0)
            let child = Task {
                SharedLogger.verifyEvent(.verifyRead, run: run, ordinal: 1, destinationIndex: 0, bytes: 4)
            }
            await child.value
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    SharedLogger.verifyEvent(.verifyDigestFinished, run: run, ordinal: 1, destinationIndex: 0, bytes: 4)
                }
                await group.waitForAll()
            }
            SharedLogger.verifyEvent(.verifyFinished, run: run, ordinal: 1, destinationIndex: 0, bytes: 4, outcome: .matched)
        }
        let records = try events(store)
        #expect(records.compactMap { $0["event"] as? String } == ["verifyStarted", "verifyRead", "verifyDigestFinished", "verifyFinished"])
        #expect(records.allSatisfy { $0["run"] as? String == run.uuidString })
        #expect(TransferDiagnostics.recordingStoreOverride == nil)
    }

    @Test func nestedThrowingScopeRestoresItsParentAndFixturePreservesIt() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = TransferDiagnosticStore(directory: root.appendingPathComponent("outer"))
        let inner = TransferDiagnosticStore(directory: root.appendingPathComponent("inner"))
        await TransferDiagnostics.$recordingStoreOverride.withValue(outer) {
            SharedLogger.transferEvent(.admitted, run: nil, code: 1)
            do {
                try TransferDiagnostics.$recordingStoreOverride.withValue(inner) {
                    SharedLogger.transferEvent(.phaseChanged, run: nil, code: 2)
                    throw ScopeProbe.expected
                }
                Issue.record("Nested scope must throw")
            } catch { #expect(error is ScopeProbe) }
            await FileOperationsTestLock.shared.run {
                #expect(TransferDiagnostics.recordingStore === outer)
                SharedLogger.transferEvent(.pipelineDrained, run: nil, code: 3)
            }
        }
        #expect(try events(outer).compactMap { $0["code"] as? Int } == [1, 3])
        #expect(try events(inner).compactMap { $0["code"] as? Int } == [2])
        #expect(TransferDiagnostics.recordingStoreOverride == nil)
    }

    @Test func concurrentScopesKeepEveryEventInTheirOwnFiles() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stores = ["first", "second"].map { TransferDiagnosticStore(directory: root.appendingPathComponent($0)) }
        let runs = [UUID(), UUID()]
        await withTaskGroup(of: Void.self) { group in
            for index in stores.indices {
                group.addTask {
                    await TransferDiagnostics.$recordingStoreOverride.withValue(stores[index]) {
                        for ordinal in 0..<200 {
                            await Task.yield()
                            SharedLogger.verifyEvent(.verifyRead, run: runs[index], ordinal: ordinal,
                                destinationIndex: index, bytes: Int64(ordinal))
                        }
                    }
                }
            }
            await group.waitForAll()
        }
        for index in stores.indices {
            let records = try events(stores[index])
            #expect(records.count == 200)
            #expect(records.allSatisfy { $0["run"] as? String == runs[index].uuidString })
            #expect(Set(records.compactMap { $0["ordinal"] as? Int }) == Set(0..<200))
        }
        #expect(TransferDiagnostics.recordingStoreOverride == nil)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-diagnostic-scope-\(UUID())")
    }
    private func events(_ store: TransferDiagnosticStore) throws -> [[String: Any]] {
        let object = try #require(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
        #expect(object["recordingHadErrors"] as? Bool == false)
        return try #require(object["events"] as? [[String: Any]])
    }
}
private enum ScopeProbe: Error { case expected }
