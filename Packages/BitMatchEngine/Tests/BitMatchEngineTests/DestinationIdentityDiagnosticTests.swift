import Foundation
import Synchronization
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatchEngine

final class DestinationIdentityDiagnosticTests: XCTestCase, @unchecked Sendable {
    private let diagnosticKeys: Set<String> = [
        "timestamp", "session", "appVersion", "build", "event", "run", "code",
        "taskCancelled", "destinationIndex", "sourceOrdinal", "totalBytes", "wasReused",
        "identityCheckReason", "identityChangedFields", "readIdentityPresent",
        "currentIdentityPresent", "identityLookupFailed", "footprintMB"
    ]

    private func fixture() throws -> (URL, TransferDiagnosticStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitmatch-identity-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let crashStore = LocalCrashEvidenceStore(
            directory: directory.appendingPathComponent("UnusedCrashEvidence"), consentProvider: { false }
        )
        return (directory, TransferDiagnosticStore(directory: directory, systemEvidenceStore: crashStore))
    }

    private func identity(
        device: UInt64 = 1_234_567_890_123, inode: UInt64 = 2_345_678_901_234,
        size: Int64 = 3_456_789_012_345,
        modificationSeconds: Int64 = 4_567_890_123_456, modificationNanoseconds: Int64 = 678_901_234,
        changeSeconds: Int64 = 5_678_901_234_567, changeNanoseconds: Int64 = 789_012_345
    ) -> VerifiedFileIdentity {
        .init(device: device, inode: inode, size: size,
              modificationSeconds: modificationSeconds, modificationNanoseconds: modificationNanoseconds,
              changeSeconds: changeSeconds, changeNanoseconds: changeNanoseconds)
    }

    private func events(_ store: TransferDiagnosticStore) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: store.exportData()) as? [String: Any])
        XCTAssertEqual(object["recordingHadErrors"] as? Bool, false)
        XCTAssertEqual(object["incompleteRecords"] as? Int, 0)
        return try XCTUnwrap(object["events"] as? [[String: Any]])
    }

    private func record(recorded: VerifiedFileIdentity?, current: VerifiedFileIdentity?,
                        error: Error? = nil, wasReused: Bool = true) throws -> [String: Any] {
        let (_, store) = try fixture()
        let run = UUID()
        TransferDiagnostics.$recordingStoreOverride.withValue(store) {
            SharedLogger.destinationIdentityRejected(
                run: run, destinationIndex: 2, sourceOrdinal: 7, bytes: 0, wasReused: wasReused,
                recorded: recorded, current: current, lookupError: error
            )
        }
        let records = try events(store)
        XCTAssertEqual(records.count, 1)
        let event = try XCTUnwrap(records.first)
        XCTAssertEqual(event["event"] as? String, "destinationIdentityRejected")
        XCTAssertEqual(event["run"] as? String, run.uuidString)
        XCTAssertEqual(event["destinationIndex"] as? Int, 2)
        XCTAssertEqual(event["sourceOrdinal"] as? Int, 7)
        XCTAssertNil(event["ordinal"], "Manifest order must not masquerade as verify-job copy order")
        XCTAssertEqual(event["totalBytes"] as? Int64, 0)
        XCTAssertEqual(event["wasReused"] as? Bool, wasReused)
        XCTAssertEqual(event["taskCancelled"] as? Bool, false)
        XCTAssertTrue(Set(event.keys).isSubset(of: diagnosticKeys), "Only reviewed diagnostic fields may be exported")
        return event
    }

    // Plant: collapse missing read evidence and a missing pathname into one reason.
    func testMissingReadIdentityAndMissingCurrentFileHaveDistinctReasons() throws {
        let noRead = try record(recorded: nil, current: identity())
        XCTAssertEqual(noRead["identityCheckReason"] as? String, "missingReadIdentity")
        XCTAssertEqual(noRead["readIdentityPresent"] as? Bool, false)
        XCTAssertEqual(noRead["currentIdentityPresent"] as? Bool, true)
        XCTAssertEqual(noRead["identityLookupFailed"] as? Bool, false)
        XCTAssertEqual(noRead["identityChangedFields"] as? [String], [])
        XCTAssertNil(noRead["code"])

        let noCurrent = try record(recorded: identity(), current: nil)
        XCTAssertEqual(noCurrent["identityCheckReason"] as? String, "missingCurrentFile")
        XCTAssertEqual(noCurrent["readIdentityPresent"] as? Bool, true)
        XCTAssertEqual(noCurrent["currentIdentityPresent"] as? Bool, false)
        XCTAssertEqual(noCurrent["identityLookupFailed"] as? Bool, false)
        XCTAssertEqual(noCurrent["identityChangedFields"] as? [String], [])
        XCTAssertNil(noCurrent["code"])
    }

    func testMissingReadEvidenceRemainsPrimaryWhenLookupAlsoFails() throws {
        let event = try record(recorded: nil, current: nil,
                               error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        XCTAssertEqual(event["identityCheckReason"] as? String, "missingReadIdentity")
        XCTAssertEqual(event["readIdentityPresent"] as? Bool, false)
        XCTAssertEqual(event["currentIdentityPresent"] as? Bool, false)
        XCTAssertEqual(event["identityLookupFailed"] as? Bool, true)
        XCTAssertEqual(event["code"] as? Int, Int(EACCES))
    }

    // Plant: discard the lookup error before recording the final identity rejection.
    func testPOSIXLookupErrorRetainsOnlyItsNumericCode() throws {
        let marker = "PRIVATE_LOOKUP_\(UUID().uuidString)"
        let event = try record(recorded: identity(), current: nil,
            error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                           userInfo: [NSFilePathErrorKey: "/production/\(marker)/clip.mov",
                                      NSLocalizedDescriptionKey: marker]))
        XCTAssertEqual(event["identityCheckReason"] as? String, "lookupError")
        XCTAssertEqual(event["identityLookupFailed"] as? Bool, true)
        XCTAssertEqual(event["code"] as? Int, Int(EACCES))
        XCTAssertEqual(event["identityChangedFields"] as? [String], [])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self).contains(marker))
    }

    // Plant: export the NSError domain, description, path or arbitrary non-POSIX code.
    func testApplicationDefinedLookupErrorsCannotAddUnreviewedInformation() throws {
        let marker = "PRIVATE_ERROR_\(UUID().uuidString)"
        let event = try record(recorded: identity(), current: nil,
            error: NSError(domain: marker, code: 987_654_321,
                           userInfo: [NSFilePathErrorKey: "/private/\(marker)",
                                      NSLocalizedDescriptionKey: marker]))
        XCTAssertEqual(event["identityCheckReason"] as? String, "lookupError")
        XCTAssertEqual(event["identityLookupFailed"] as? Bool, true)
        XCTAssertNil(event["code"], "An application-defined code is not a POSIX errno")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        XCTAssertFalse(text.contains(marker))
        XCTAssertFalse(text.contains("987654321"))
    }

    // Plant: omit one comparison or merge inode changes with all metadata changes.
    func testEachChangedFieldIsClassifiedWithoutExportingItsValue() throws {
        let before = identity()
        let cases: [(VerifiedFileIdentity, String)] = [
            (identity(device: before.device + 1), "device"),
            (identity(inode: before.inode + 1), "inode"),
            (identity(size: before.size + 1), "size"),
            (identity(modificationSeconds: before.modificationSeconds + 1), "modificationTime"),
            (identity(modificationNanoseconds: before.modificationNanoseconds + 1), "modificationTime"),
            (identity(changeSeconds: before.changeSeconds + 1), "changeTime"),
            (identity(changeNanoseconds: before.changeNanoseconds + 1), "changeTime")
        ]
        for (after, field) in cases {
            let event = try record(recorded: before, current: after, wasReused: field == "inode")
            XCTAssertEqual(event["identityCheckReason"] as? String, "changedIdentity", field)
            XCTAssertEqual(event["identityChangedFields"] as? [String], [field])
            XCTAssertEqual(event["readIdentityPresent"] as? Bool, true)
            XCTAssertEqual(event["currentIdentityPresent"] as? Bool, true)
            XCTAssertEqual(event["identityLookupFailed"] as? Bool, false)
            XCTAssertNil(event["code"])
            let text = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            for value in [before, after] {
                for privateValue in [String(value.device), String(value.inode), String(value.size),
                                     String(value.modificationSeconds), String(value.modificationNanoseconds),
                                     String(value.changeSeconds), String(value.changeNanoseconds)] {
                    XCTAssertFalse(text.contains(privateValue), "Raw \(field) values must remain private")
                }
            }
        }
    }

    func testSimultaneousChangesRetainEveryClosedFieldNameOnce() throws {
        let before = identity()
        let after = identity(device: before.device + 1, inode: before.inode + 1, size: before.size + 1,
                             modificationSeconds: before.modificationSeconds + 1,
                             modificationNanoseconds: before.modificationNanoseconds + 1,
                             changeSeconds: before.changeSeconds + 1,
                             changeNanoseconds: before.changeNanoseconds + 1)
        let event = try record(recorded: before, current: after)
        XCTAssertEqual(event["identityChangedFields"] as? [String],
                       ["device", "inode", "size", "modificationTime", "changeTime"])
    }

    // Plant: make the added optional event fields required during decoding.
    func testEarlierDiagnosticRecordWithoutIdentityFieldsStillExports() throws {
        let (directory, store) = try fixture()
        let old = """
        {"timestamp":"2026-10-04T05:52:33Z","session":"10F46567-3287-4CC1-A39E-B9D451CC7430","appVersion":"0.2.3","build":"23","event":"copyDrained","run":"5537CD06-69AE-4460-B457-6834B35B325B","taskCancelled":false,"explicit":false}
        """
        try Data((old + "\n").utf8).write(to: directory.appendingPathComponent("current.jsonl"), options: .withoutOverwriting)
        let records = try events(store)
        XCTAssertEqual(records.count, 1)
        let event = try XCTUnwrap(records.first)
        XCTAssertEqual(event["event"] as? String, "copyDrained")
        XCTAssertEqual(event["run"] as? String, "5537CD06-69AE-4460-B457-6834B35B325B")
        for key in ["identityCheckReason", "identityChangedFields", "readIdentityPresent",
                    "currentIdentityPresent", "identityLookupFailed", "wasReused", "sourceOrdinal"] {
            XCTAssertNil(event[key], "Older records must not invent \(key)")
        }
    }

#if os(macOS)
    // Plant: omit destinationIdentityRejected at the real final-coverage guard.
    // This exercises a pathname replacement, not an injected diagnostic call.
    func testRealFinalCoverageRejectionRecordsReasonAndKeepsPrivatePathsOut() async throws {
        let (directory, store) = try fixture()
        let marker = "PRIVATE_CAMERA_\(UUID().uuidString)"
        let source = directory.appendingPathComponent(marker, isDirectory: true)
        let backup = directory.appendingPathComponent("Backup", isDirectory: true)
        for folder in [source, backup] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let clip = source.appendingPathComponent(marker + ".bin")
        let original = Data(repeating: 0x31, count: 8_193)
        let changed = Data(repeating: 0x72, count: original.count)
        try original.write(to: clip, options: .withoutOverwriting)
        let preserved = directory.appendingPathComponent("PreservedOriginal.bin")
        let mutation = Mutex((ran: false, error: Optional<String>.none))
        let completed = Mutex(false)
        let run = UUID()

        let operation = try await TransferDiagnostics.$recordingStoreOverride.withValue(store) {
            try await TransferDiagnostics.$runID.withValue(run) {
                try await FileOperationsTestLock.shared.run {
                    try await TransferPipeline(fileSystem: LocalFileAccess(), checksum: ChecksumEngine.shared)
                        .performFileOperation(sourceURL: source, destinationURLs: [backup],
                            verificationMode: .standard, settings: CameraLabelSettings(),
                            progressCallback: { progress in
                                if progress.currentStage == .completed { completed.withLock { $0 = true } }
                            }, onFileResult: { row in
                                guard row.verificationResult?.isValid == true else { return }
                                let shouldMutate = mutation.withLock { value in
                                    guard !value.ran else { return false }
                                    value.ran = true
                                    return true
                                }
                                guard shouldMutate else { return }
                                do {
                                    try FileManager.default.moveItem(at: row.destinationURL, to: preserved)
                                    try changed.write(to: row.destinationURL, options: .withoutOverwriting)
                                } catch { mutation.withLock { $0.error = String(describing: error) } }
                            })
                }
            }
        }

        XCTAssertTrue(mutation.withLock { $0.ran }, "The verified callback must perform the real replacement")
        XCTAssertNil(mutation.withLock { $0.error })
        XCTAssertEqual(try Data(contentsOf: clip), original)
        XCTAssertEqual(try Data(contentsOf: preserved), original)
        let row = try XCTUnwrap(operation.results.first)
        XCTAssertEqual(operation.results.count, 1)
        XCTAssertFalse(row.success)
        XCTAssertNil(row.verificationResult)
        XCTAssertFalse(completed.withLock { $0 })
        XCTAssertEqual(try Data(contentsOf: row.destinationURL), changed)

        let rejections = try events(store).filter { $0["event"] as? String == "destinationIdentityRejected" }
        XCTAssertEqual(rejections.count, 1)
        let event = try XCTUnwrap(rejections.first)
        XCTAssertEqual(event["run"] as? String, run.uuidString)
        XCTAssertEqual(event["identityCheckReason"] as? String, "changedIdentity")
        XCTAssertTrue((event["identityChangedFields"] as? [String])?.contains("inode") == true)
        XCTAssertEqual(event["wasReused"] as? Bool, false)
        XCTAssertEqual(event["destinationIndex"] as? Int, 0)
        XCTAssertEqual(event["sourceOrdinal"] as? Int, 1)
        XCTAssertNil(event["ordinal"])
        XCTAssertEqual(event["totalBytes"] as? Int64, Int64(original.count))
        XCTAssertTrue(Set(event.keys).isSubset(of: diagnosticKeys))
        XCTAssertFalse(String(decoding: try store.exportData(), as: UTF8.self).contains(marker))
    }
#endif
}
