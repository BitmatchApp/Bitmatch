import CryptoKit
import Foundation
import XCTest
import BitMatchEngine
#if canImport(Darwin)
import Darwin
#endif
@testable import BitMatch

/// Promise 1, "the card is sacred": a transfer leaves every entry in the
/// source tree exactly as it found it. Nothing is added, removed, rewritten,
/// resized, re-dated, or re-permissioned, in any verification mode.
@MainActor
final class SourceTreeUnchangedTests: XCTestCase {
    func testTransferLeavesSourceTreeUnchangedInEveryVerificationMode() async throws {
        try await FileOperationsTestLock.shared.run {
            for mode in VerificationMode.allCases {
                let fixture = try DisposableTransferFixture(
                    seed: 20_260_925,
                    fileCount: 6,
                    bytesPerFile: 64 * 1024
                )
                defer { fixture.cleanup() }
                let source = sourceTreeCanonicalDirectoryURL(fixture.source)
                try seedSourceMetadata(source)
                let before = try SourceTreeSnapshot(root: source)

                // Drive the executor the app uses, with every writer on
                // (report and ASC MHL), so evidence written to the wrong
                // folder is caught too, not just the copy loop.
                let executor = await MainActor.run {
                    CopyVerifyExecutor(
                        platformManager: MacOSPlatformManager.shared,
                        timingService: OperationTimingService(),
                        errorService: ErrorReportingService(),
                        stateService: OperationStateService(),
                        backgroundTaskService: IOSBackgroundTaskService.shared
                    )
                }
                let config = CopyVerifyConfig(
                    operationId: UUID(),
                    sourceURL: source,
                    destinationURLs: fixture.destinations,
                    verificationMode: mode,
                    cameraLabelSettings: CameraLabelSettings(),
                    reportSettings: ReportPrefs(makeReport: true),
                    estimatedFiles: fixture.manifest.count,
                    estimatedBytes: 0,
                    currentMode: .copyAndVerify,
                    generateASCMHL: true
                )
                let finalState = StateBox()
                let maybeOperation = try await executor.execute(
                    config: config,
                    callbacks: CopyVerifyCallbacks(
                        onProgress: { _ in },
                        onResult: { _ in },
                        onStateChange: { finalState.value = $0 },
                        onAuthoritativeResults: { _ in }
                    )
                )
                let operation = try XCTUnwrap(maybeOperation, "\(mode.rawValue): executor returned no operation")

                // Guard against a vacuous pass: the transfer must actually
                // have read every source file and finished green.
                XCTAssertEqual(
                    operation.results.count,
                    fixture.manifest.count * fixture.destinations.count,
                    "\(mode.rawValue): unexpected result count"
                )
                XCTAssertTrue(
                    operation.results.allSatisfy(\.success),
                    "\(mode.rawValue): transfer reported failures"
                )
                // Quick copies are never reported as verified (P2), so only
                // the checksum modes are required to finish green.
                guard case .completed(let info) = finalState.value, info.success || mode == .quick else {
                    XCTFail("\(mode.rawValue): operation did not complete as expected: \(finalState.value)")
                    continue
                }

                let after = try SourceTreeSnapshot(root: source)
                XCTAssertEqual(
                    after.entries.keys.sorted(),
                    before.entries.keys.sorted(),
                    "\(mode.rawValue): entries were added to or removed from the source"
                )
                for (path, entry) in before.entries.sorted(by: { $0.key < $1.key }) {
                    XCTAssertEqual(
                        after.entries[path],
                        entry,
                        "\(mode.rawValue): source entry '\(path)' changed"
                    )
                }
            }
        }
    }
    func testCancellationAfterReadbackLeavesSourceMetadataUnchanged() async throws {
        try await exerciseUnsuccessfulHandoff(cancel: true)
    }

    func testReportPublicationFailureLeavesSourceMetadataUnchanged() async throws {
        try await exerciseUnsuccessfulHandoff(cancel: false)
    }

    private func exerciseUnsuccessfulHandoff(cancel: Bool) async throws {
        try await FileOperationsTestLock.shared.run {
            let fixture = try DisposableTransferFixture(seed: 20261010, fileCount: 3, bytesPerFile: 64 * 1024)
            defer { fixture.cleanup() }
            let source = sourceTreeCanonicalDirectoryURL(fixture.source)
            try seedSourceMetadata(source)
            let before = try SourceTreeSnapshot(root: source)
            XCTAssertFalse(before.entries["."]?.extendedAttributes.isEmpty ?? true)
            if !cancel {
                // A real destination conflict during report publication, after media verification.
                for destination in fixture.destinations {
                    try Data("existing file must not be overwritten".utf8).write(to: destination.appendingPathComponent("Reports"))
                }
            }
            let executor = CopyVerifyExecutor(platformManager: MacOSPlatformManager.shared,
                timingService: OperationTimingService(), errorService: ErrorReportingService(),
                stateService: OperationStateService(), backgroundTaskService: IOSBackgroundTaskService.shared)
            let config = CopyVerifyConfig(operationId: UUID(), sourceURL: source, destinationURLs: fixture.destinations,
                verificationMode: .standard, cameraLabelSettings: CameraLabelSettings(),
                reportSettings: ReportPrefs(makeReport: true), estimatedFiles: fixture.manifest.count,
                estimatedBytes: 0, currentMode: .copyAndVerify, generateASCMHL: true)
            let finalState = StateBox()
            var authoritativeCount = 0
            do {
                _ = try await executor.execute(config: config, callbacks: CopyVerifyCallbacks(
                    onProgress: { _ in }, onResult: { _ in }, onStateChange: { finalState.value = $0 },
                    onAuthoritativeResults: { rows in
                        authoritativeCount = rows.count
                        if cancel { executor.cancel() }
                    }))
                if cancel { XCTFail("Cancellation must throw") }
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch {
                XCTAssertFalse(cancel, "Explicit cancellation should propagate CancellationError")
            }
            XCTAssertEqual(authoritativeCount, fixture.manifest.count * fixture.destinations.count)
            if cancel {
                XCTAssertEqual(finalState.value, .cancelled)
            } else {
                guard case .completed(let info) = finalState.value else {
                    XCTFail("Expected a retained unsafe report-failure outcome"); return
                }
                XCTAssertFalse(info.success)
                XCTAssertTrue(info.message.contains("report could not be saved"))
            }
            let after = try SourceTreeSnapshot(root: source)
            XCTAssertEqual(after.entries, before.entries)
        }
    }

}

private func seedSourceMetadata(_ source: URL) throws {
    let targets = [source] + (try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey]))
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.prefix(1)
    for url in targets {
        let value = Data("source metadata must stay intact".utf8)
        let result = value.withUnsafeBytes { setxattr(url.path, "com.bitmatch.source-test", $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        if result != 0 {
            if errno == ENOTSUP { throw XCTSkip("Fixture filesystem does not support extended attributes") }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private func sourceExtendedAttributes(_ url: URL) throws -> [String: Data] {
    let length = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
    guard length >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    if length == 0 { return [:] }
    var buffer = [CChar](repeating: 0, count: length)
    let read = listxattr(url.path, &buffer, length, XATTR_NOFOLLOW)
    guard read == length else { throw POSIXError(.EIO) }
    let names = buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    var output: [String: Data] = [:]
    for name in names {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var value = Data(count: size)
        let count = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard count == size else { throw POSIXError(.EIO) }
        output[name] = value
    }
    return output
}

@MainActor
private final class StateBox {
    var value: OperationState = .idle
}

/// Every file and directory under a root, including hidden entries and the
/// root itself (key "."). Directory modification dates catch entries that
/// were created and then removed during the transfer.
private struct SourceTreeSnapshot {
    struct Entry: Equatable {
        let isDirectory: Bool
        let size: Int64
        let modificationDate: Date?
        let posixPermissions: Int?
        let sha256: String?
        let creationDate: Date?
        let ownerID: Int?
        let groupID: Int?
        let extendedAttributes: [String: Data]
    }

    let entries: [String: Entry]

    init(root: URL) throws {
        let fileManager = FileManager.default
        var entries: [String: Entry] = [:]
        let relativePaths = try fileManager.subpathsOfDirectory(atPath: root.path)
        for relativePath in ["."] + relativePaths {
            let url = relativePath == "." ? root : root.appendingPathComponent(relativePath)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let isDirectory = type == .typeDirectory
            let sha256: String?
            if type == .typeRegular {
                let data = try Data(contentsOf: url)
                sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else {
                sha256 = nil
            }
            entries[relativePath] = Entry(
                isDirectory: isDirectory,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modificationDate: attributes[.modificationDate] as? Date,
                posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
                sha256: sha256,
                creationDate: attributes[.creationDate] as? Date,
                ownerID: (attributes[.ownerAccountID] as? NSNumber)?.intValue,
                groupID: (attributes[.groupOwnerAccountID] as? NSNumber)?.intValue,
                extendedAttributes: try sourceExtendedAttributes(url)
            )
        }
        self.entries = entries
    }
}

private func sourceTreeCanonicalDirectoryURL(_ url: URL) -> URL {
    #if canImport(Darwin)
    guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    #else
    return url.resolvingSymlinksInPath().standardizedFileURL
    #endif
}
