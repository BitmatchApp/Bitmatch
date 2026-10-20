import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import BitMatchEngine

final class ASCMHLGeneratorTests: XCTestCase {
    func testCreatorDetailsAreEscapedWithoutChangingMediaOrExistingHistory() throws {
        let (root, file) = try fixture()
        let media = try Data(contentsOf: root.appendingPathComponent("clip.txt"))
        let manifest = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            operatorName: "  Renée & <DIT>  ", notes: "First line\nBackup \"B\" <ready>\u{0}"
        )
        let bytes = try Data(contentsOf: manifest)
        let document = try XMLDocument(data: bytes)
        let comment = try XCTUnwrap(document.nodes(forXPath: "//*[local-name()='comment']").first?.stringValue)
        XCTAssertTrue(comment.contains("Operator: Renée & <DIT>"))
        XCTAssertTrue(comment.contains("Notes: First line\nBackup \"B\" <ready>�"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("clip.txt")), media)
        let chain = try XMLDocument(contentsOf: manifest.deletingLastPathComponent().appendingPathComponent("ascmhl_chain.xml"))
        XCTAssertEqual(try chain.nodes(forXPath: "//*[local-name()='c4']").first?.stringValue,
                       ASCMHLGenerator.c4(bytes))
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            operatorName: "Someone else", notes: "Replacement"))
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }

    func testBlankCreatorDetailsKeepOriginalComment() throws {
        let (root, file) = try fixture()
        let manifest = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test", operatorName: " ", notes: "\n")
        let document = try XMLDocument(contentsOf: manifest)
        let comment = try XCTUnwrap(document.nodes(forXPath: "//*[local-name()='comment']").first?.stringValue)
        XCTAssertFalse(comment.contains("Operator:"))
        XCTAssertFalse(comment.contains("Notes:"))
    }

    func testC4MatchesOfficialReferenceEmptyDataVector() {
        XCTAssertEqual(ASCMHLGenerator.c4(Data()), "c459dsjfscH38cYeXXYogktxf4Cd9ibshE3BHUo6a58hBXmRQdZrAkZzsWcbWtDg5oQstpDuni4Hirj75GEmTc1sFT")
    }

    func testEmptyInventoryDoesNotPublishHistory() throws {
        let (root, _) = try fixture()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [], startTime: Date(), toolVersion: "test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testSourceOverlapAndAncestorSymlinkCannotPublish() throws {
        let (root, file) = try fixture()
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for source in [root, root.deletingLastPathComponent(), nested] {
            XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), sourceURL: source, toolVersion: "test")) { error in
                guard case ASCMHLGenerator.GenerationError.sourceOverlap = error else {
                    return XCTFail("Expected source overlap, got \(error)")
                }
            }
        }
        let alias = root.deletingLastPathComponent().appendingPathComponent("ascmhl-alias-\(UUID())")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: alias.appendingPathComponent("nested"), files: [file], startTime: Date(), sourceURL: root, toolVersion: "test")) { error in
            guard case ASCMHLGenerator.GenerationError.sourceOverlap = error else {
                return XCTFail("Expected source overlap through alias, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent("ascmhl").path))
    }

    private func fixture() throws -> (URL, ASCMHLGenerator.VerifiedFile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let data = Data("verified media".utf8)
        try data.write(to: root.appendingPathComponent("clip.txt"))
        return (root, .init(relativePath: "clip.txt", size: Int64(data.count), expectedSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }

    func testChangedDestinationDoesNotPublishHistory() throws {
        let (root, file) = try fixture()
        try Data("corrupt media!".utf8).write(to: root.appendingPathComponent("clip.txt"))
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), toolVersion: "test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testExistingHistoryIsByteForBytePreserved() throws {
        let (root, file) = try fixture()
        let manifest = try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), toolVersion: "test")
        let chain = manifest.deletingLastPathComponent().appendingPathComponent("ascmhl_chain.xml")
        let original = try Data(contentsOf: manifest)
        let originalChain = try Data(contentsOf: chain)
        XCTAssertTrue(String(decoding: original, as: UTF8.self).contains(#"<tool version="test">BitMatch</tool>"#),
                      "the manifest names the app version it was given")
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), toolVersion: "test"))
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        XCTAssertEqual(try Data(contentsOf: chain), originalChain)
    }

    func testFallbackDoesNotReplaceAnEmptyHistorySwappedAfterClaimValidation() throws {
        let (root, file) = try fixture()
        let history = root.appendingPathComponent("ascmhl", isDirectory: true)
        let displacedClaim = root.appendingPathComponent("displaced-claim", isDirectory: true)
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(
                fileSystemType: { "exfat" },
                beforePublishingClaim: {
                    try FileManager.default.moveItem(at: history, to: displacedClaim)
                    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false)
                }
            )
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: history.path), [],
                       "The substituted empty directory must not be replaced by a finished history")
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedClaim.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.appendingPathComponent("ascmhl_chain.xml").path))
    }

    func testDirectFATFallbackPublishesACompleteCheckableHistory() async throws {
        let (root, file) = try fixture()
        let manifest = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(fileSystemType: { "exfat" })
        )
        let history = manifest.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.appendingPathComponent("ascmhl_chain.xml").path))
        let status = history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: status.path))
        XCTAssertTrue(try ASCMHLGenerator.publicationIsComplete(at: status))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".bitmatch-ascmhl-") })
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let discovery = try await checker.discover(under: root)
        let result = try await checker.check(discovery) { _ in }
        XCTAssertTrue(result.isIntact)
        XCTAssertEqual(result.recordedFileCount, 1)
    }

    func testInterruptedDirectFATWritesStayMarkedAndUncheckable() async throws {
        for stopAfterChain in [false, true] {
            let (root, file) = try fixture()
            let media = try Data(contentsOf: root.appendingPathComponent("clip.txt"))
            let history = root.appendingPathComponent("ascmhl", isDirectory: true)
            do {
                _ = try ASCMHLGenerator.generateInitialHistory(
                    destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
                    readHooks: .init(
                        fileSystemType: { "exfat" },
                        didWritePublicHistoryFile: { name in
                            if (name == "ascmhl_chain.xml") == stopAfterChain { throw CancellationError() }
                        }
                    )
                )
                XCTFail("An interrupted public history must not be reported as published")
            } catch is CancellationError {
                // The warning stays even when both evidence files have been written.
            }
            let contents = try FileManager.default.contentsOfDirectory(atPath: history.path)
            XCTAssertTrue(contents.contains(ASCMHLGenerator.publicationStatusName))
            XCTAssertFalse(try ASCMHLGenerator.publicationIsComplete(at:
                history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)))
            XCTAssertEqual(contents.contains("ascmhl_chain.xml"), stopAfterChain)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("clip.txt")), media)
            let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            do {
                _ = try await checker.discover(under: root)
                XCTFail("Check must refuse a marked history")
            } catch let error as SavedChecksumCheck.CheckError {
                XCTAssertEqual(error, .unreadableEvidence)
            }
            XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
                destinationURL: root, files: [file], startTime: Date(), toolVersion: "test"
            ))
        }
    }

    func testMovedDestinationRootLeavesIncompleteHistoryAndCannotReportSuccess() throws {
        let (root, file) = try fixture()
        let movedRoot = root.deletingLastPathComponent().appendingPathComponent("moved-mhl-root-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: movedRoot) }
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(
                fileSystemType: { "exfat" },
                didWritePublicHistoryFile: { name in
                    guard name == "ascmhl_chain.xml" else { return }
                    try FileManager.default.moveItem(at: root, to: movedRoot)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                }
            )
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            movedRoot.appendingPathComponent("ascmhl").appendingPathComponent(ASCMHLGenerator.publicationStatusName).path))
    }

    func testSubstitutedPrivateStageIsNeverRemovedByCleanup() throws {
        let (root, file) = try fixture()
        let movedStage = root.appendingPathComponent("moved-stage", isDirectory: true)
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(
                fileSystemType: { "apfs" },
                beforeExclusiveRename: {
                    let stageName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
                        .first { $0.hasPrefix(".bitmatch-ascmhl-") })
                    let stage = root.appendingPathComponent(stageName, isDirectory: true)
                    try FileManager.default.moveItem(at: stage, to: movedStage)
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                    throw CancellationError()
                }
            )
        )) { XCTAssertTrue($0 is CancellationError) }
        let substituteName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
            .first { $0.hasPrefix(".bitmatch-ascmhl-") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent(substituteName).path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedStage.path))
    }

    func testUnexpectedPublicHistoryEntryKeepsIncompleteMarker() throws {
        let (root, file) = try fixture()
        let history = root.appendingPathComponent("ascmhl", isDirectory: true)
        let other = history.appendingPathComponent("other.mhl")
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(
                fileSystemType: { "exfat" },
                didWritePublicHistoryFile: { name in
                    if name == "ascmhl_chain.xml" { try Data("preserve".utf8).write(to: other) }
                }
            )
        ))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "preserve")
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            history.appendingPathComponent(ASCMHLGenerator.publicationStatusName).path))
    }

    func testInvalidAppleDoubleLookalikeCannotAuthorizeFATCompletion() throws {
        let (root, file) = try fixture()
        let history = root.appendingPathComponent("ascmhl", isDirectory: true)
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(
                fileSystemType: { "exfat" },
                didWritePublicHistoryFile: { name in
                    guard name == "ascmhl_chain.xml" else { return }
                    let manifest = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: history.path)
                        .first { $0.hasSuffix(".mhl") })
                    try Data("not AppleDouble".utf8).write(to: history.appendingPathComponent("._" + manifest))
                }
            )
        ))
        let status = history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)
        XCTAssertFalse(try ASCMHLGenerator.publicationIsComplete(at: status))
        let manifest = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: history.path)
            .first { $0.hasSuffix(".mhl") })
        XCTAssertEqual(try Data(contentsOf: history.appendingPathComponent("._" + manifest)),
                       Data("not AppleDouble".utf8))
    }

    func testStatusSubstitutionCannotBeDeletedOrCompleted() throws {
        let (root, file) = try fixture()
        let history = root.appendingPathComponent("ascmhl", isDirectory: true)
        let status = history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)
        let movedStatus = root.appendingPathComponent("moved-status.txt")
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(
                fileSystemType: { "exfat" },
                beforePublishingCompletion: {
                    try FileManager.default.moveItem(at: status, to: movedStatus)
                    try Data("other writer's status".utf8).write(to: status)
                }
            )
        ))
        XCTAssertEqual(try Data(contentsOf: status), Data("other writer's status".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedStatus.path))
    }

    func testChangedChainAtCompletionNeverReportsPublication() async throws {
        for afterCompletion in [false, true] {
            let (root, file) = try fixture()
            let history = root.appendingPathComponent("ascmhl", isDirectory: true)
            let chain = history.appendingPathComponent("ascmhl_chain.xml")
            let progress = MHLPublicationProbe()
            let changeChain: @Sendable () throws -> Void = {
                try Data("another writer changed the chain".utf8).write(to: chain)
            }
            XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
                destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
                readHooks: .init(
                    fileSystemType: { "exfat" },
                    beforePublishingCompletion: afterCompletion ? nil : changeChain,
                    afterPublishingCompletion: afterCompletion ? changeChain : nil
                ),
                progress: { progress.record($0.published) }
            ))
            XCTAssertFalse(progress.published, "No complete progress event may escape after a chain change")
            let status = history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)
            XCTAssertFalse(try ASCMHLGenerator.publicationIsComplete(at: status))
            let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            do {
                _ = try await checker.discover(under: root)
                XCTFail("Check must reject a changed chain")
            } catch let error as SavedChecksumCheck.CheckError {
                XCTAssertEqual(error, .unreadableEvidence)
            }
        }
    }

    func testSubstitutedPrivateStageCannotReportPublication() throws {
        let (root, file) = try fixture()
        let movedStage = root.appendingPathComponent("moved-stage", isDirectory: true)
        let progress = MHLPublicationProbe()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(
                fileSystemType: { "apfs" },
                beforeExclusiveRename: {
                    let stageName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
                        .first { $0.hasPrefix(".bitmatch-ascmhl-") })
                    let stage = root.appendingPathComponent(stageName, isDirectory: true)
                    try FileManager.default.moveItem(at: stage, to: movedStage)
                    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
                    try Data("foreign".utf8).write(to: stage.appendingPathComponent("keep.txt"))
                }
            ),
            progress: { progress.record($0.published) }
        ))
        XCTAssertFalse(progress.published)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedStage.appendingPathComponent("ascmhl_chain.xml").path))
        let substituteName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: root.path)
            .first { $0.hasPrefix(".bitmatch-ascmhl-") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(substituteName).appendingPathComponent("keep.txt")),
                       Data("foreign".utf8))
    }

    func testRemovingStatusAfterPartialFATManifestStillCannotPassCheck() async throws {
        let (root, file) = try fixture()
        let history = root.appendingPathComponent("ascmhl", isDirectory: true)
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(
                fileSystemType: { "exfat" },
                didWritePublicHistoryFile: { name in
                    if name.hasSuffix(".mhl") { throw CancellationError() }
                }
            )
        ))
        try FileManager.default.removeItem(at: history.appendingPathComponent(ASCMHLGenerator.publicationStatusName))
        let manifest = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: history.path)
            .first { $0.hasSuffix(".mhl") })
        XCTAssertEqual(rename(history.appendingPathComponent(manifest).path,
                              history.appendingPathComponent(manifest.uppercased()).path), 0)
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        do {
            _ = try await checker.discover(under: root)
            XCTFail("A FAT manifest without its publication status is never legacy evidence")
        } catch let error as SavedChecksumCheck.CheckError {
            XCTAssertEqual(error, .unreadableEvidence)
        }
    }

    func testCompletedFATStatusBindsExactManifestAndChainBytes() async throws {
        for target in ["manifest", "chain"] {
            let (root, file) = try fixture()
            let manifest = try ASCMHLGenerator.generateInitialHistory(
                destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
                readHooks: .init(fileSystemType: { "exfat" })
            )
            let history = manifest.deletingLastPathComponent()
            let status = history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)
            let changed = target == "manifest" ? manifest : history.appendingPathComponent("ascmhl_chain.xml")
            var bytes = try Data(contentsOf: changed)
            bytes.append(0x20)
            try bytes.write(to: changed)
            XCTAssertFalse(try ASCMHLGenerator.publicationIsComplete(at: status))
            let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
            do {
                _ = try await checker.discover(under: root)
                XCTFail("A \(target) change must invalidate the publication record")
            } catch let error as SavedChecksumCheck.CheckError {
                XCTAssertEqual(error, .unreadableEvidence)
            }
        }
    }

    func testSupportedExternalChainExtensionPreservesInitialCompletionWitness() async throws {
        let (root, file) = try fixture()
        let manifest = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root, files: [file], startTime: Date(), toolVersion: "test",
            readHooks: .init(fileSystemType: { "exfat" })
        )
        let history = manifest.deletingLastPathComponent()
        let chainURL = history.appendingPathComponent("ascmhl_chain.xml")
        let secondName = "0002_External.mhl"
        let manifestBytes = try Data(contentsOf: manifest)
        try manifestBytes.write(to: history.appendingPathComponent(secondName))
        let originalChain = try String(contentsOf: chainURL, encoding: .utf8)
        let extensionEntry = "<hashlist sequencenr=\"2\"><path>\(secondName)</path><c4>\(ASCMHLGenerator.c4(manifestBytes))</c4></hashlist>"
        let extendedChain = originalChain.replacingOccurrences(
            of: "</ascmhldirectory>", with: "  \(extensionEntry)\n</ascmhldirectory>"
        )
        XCTAssertNotEqual(extendedChain, originalChain)
        try extendedChain.write(to: chainURL, atomically: false, encoding: .utf8)
        let status = history.appendingPathComponent(ASCMHLGenerator.publicationStatusName)
        XCTAssertTrue(try ASCMHLGenerator.publicationIsComplete(at: status))
        let checker = SavedChecksumCheck(fileAccess: LocalFileAccess(), checksum: ChecksumEngine.shared)
        let discovery = try await checker.discover(under: root)
        let result = try await checker.check(discovery) { _ in }
        XCTAssertTrue(result.isIntact)
        XCTAssertEqual(result.validatedHistoryDirectories, [history])
        // The original status remains an exact witness, not a resealed history.
        let expectedStatus = ASCMHLGenerator.publicationOpening + ASCMHLGenerator.publicationCompletion(
            name: manifest.lastPathComponent, manifest: manifestBytes, chain: Data(originalChain.utf8))
        XCTAssertEqual(try Data(contentsOf: status), expectedStatus)
    }

    func testNestedHistoryAndUnsafePathsAreRejected() throws {
        let (root, file) = try fixture()
        for path in ["../clip.txt", "/clip.txt", "a/../clip.txt", "ascmhl/clip.txt", "a\\clip.txt"] {
            XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [.init(relativePath: path, size: file.size, expectedSHA256: file.expectedSHA256)], startTime: Date(), toolVersion: "test"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested/ascmhl"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file], startTime: Date(), toolVersion: "test"))
    }

    func testSymlinkAndDuplicatePathsAreRejected() throws {
        let (root, file) = try fixture()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [file, file], startTime: Date(), toolVersion: "test"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias.txt").path, withDestinationPath: "clip.txt")
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(destinationURL: root, files: [.init(relativePath: "alias.txt", size: file.size, expectedSHA256: file.expectedSHA256)], startTime: Date(), toolVersion: "test"))
    }

    func testVerifiedReadbackDigestsAvoidMHLDataRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-reuse-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let data = Data((0..<8193).map { UInt8($0 % 251) })
        let source = sourceRoot.appendingPathComponent("clip.bin")
        try data.write(to: source)
        try data.write(to: root.appendingPathComponent("clip.bin"))
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )
        let roundTripped = try JSONDecoder().decode(
            VerificationResult.self,
            from: JSONEncoder().encode(verification)
        )
        XCTAssertNil(roundTripped.destinationDigests)
        XCTAssertNil(roundTripped.destinationReadIdentity)
        let reads = MHLReadProbe()
        let manifest = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [.init(
                relativePath: "clip.bin",
                size: Int64(data.count),
                expectedSHA256: verification.sourceDigests?.sha256 ?? "",
                verifiedSHA256: verification.destinationDigests?.sha256,
                verifiedMD5: verification.destinationDigests?.md5,
                destinationReadIdentity: verification.destinationReadIdentity
            )],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init(
                didOpenForRead: { _ in reads.didOpen() },
                didRead: { _, count in reads.didRead(count) },
                fileSystemType: { "apfs" }
            )
        )
        XCTAssertEqual(reads.opens, 0)
        XCTAssertEqual(reads.bytes, 0)
        let xml = try String(contentsOf: manifest, encoding: .utf8)
        let expectedMD5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(xml.contains(expectedMD5))
    }

    func testReadbackDigestsAreNotReusedWithoutRealChangeTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-exfat-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-exfat-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let data = Data((0..<8193).map { UInt8($0 % 251) })
        let source = sourceRoot.appendingPathComponent("clip.bin")
        try data.write(to: source)
        try data.write(to: root.appendingPathComponent("clip.bin"))
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )
        let reads = MHLReadProbe()

        _ = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [.init(
                relativePath: "clip.bin",
                size: Int64(data.count),
                expectedSHA256: verification.sourceDigests?.sha256 ?? "",
                verifiedSHA256: verification.destinationDigests?.sha256,
                verifiedMD5: verification.destinationDigests?.md5,
                destinationReadIdentity: verification.destinationReadIdentity
            )],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init(
                didOpenForRead: { _ in reads.didOpen() },
                didRead: { _, count in reads.didRead(count) },
                fileSystemType: { "exfat" }
            )
        )

        XCTAssertEqual(reads.opens, 1)
        XCTAssertEqual(reads.bytes, data.count)
    }

    func testMissingReadbackDigestFallsBackToDiskAndTamperStillFails() async throws {
        let (root, file) = try fixture()
        let reads = MHLReadProbe()
        _ = try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [file],
            startTime: Date(),
            toolVersion: "test",
            readHooks: .init(
                didOpenForRead: { _ in reads.didOpen() },
                didRead: { _, count in reads.didRead(count) }
            )
        )
        XCTAssertEqual(reads.opens, 1)
        XCTAssertEqual(reads.bytes, Int(file.size))

        let (tamperedRoot, tamperedFile) = try fixture()
        try Data("corrupt media!".utf8).write(to: tamperedRoot.appendingPathComponent("clip.txt"))
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: tamperedRoot,
            files: [tamperedFile],
            startTime: Date(),
            toolVersion: "test",
            readHooks: .init()
        ))
    }

    func testTamperAfterVerificationInvalidatesDigestReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-tamper-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-tamper-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let original = Data("verified bytes".utf8)
        let source = sourceRoot.appendingPathComponent("clip.bin")
        let destination = root.appendingPathComponent("clip.bin")
        try original.write(to: source)
        try original.write(to: destination)
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )
        var corrupted = original
        corrupted[0] ^= 0xff
        try corrupted.write(to: destination)
        let file = ASCMHLGenerator.VerifiedFile(
            relativePath: "clip.bin",
            size: Int64(original.count),
            expectedSHA256: verification.sourceDigests?.sha256 ?? "",
            verifiedSHA256: verification.destinationDigests?.sha256,
            verifiedMD5: verification.destinationDigests?.md5,
            destinationReadIdentity: verification.destinationReadIdentity
        )
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [file],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init()
        )) { error in
            guard case ASCMHLGenerator.GenerationError.changedFile = error else {
                return XCTFail("Expected changedFile, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testReadbackSHA256MustIndependentlyMatchExpectedSHA256() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-independent-sha-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-independent-sha-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let data = Data("verified bytes".utf8)
        let source = sourceRoot.appendingPathComponent("clip.bin")
        try data.write(to: source)
        try data.write(to: root.appendingPathComponent("clip.bin"))
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )
        let file = ASCMHLGenerator.VerifiedFile(
            relativePath: "clip.bin",
            size: Int64(data.count),
            expectedSHA256: String(repeating: "0", count: 64),
            verifiedSHA256: verification.destinationDigests?.sha256,
            verifiedMD5: verification.destinationDigests?.md5,
            destinationReadIdentity: verification.destinationReadIdentity
        )

        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [file],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init()
        )) { error in
            guard case ASCMHLGenerator.GenerationError.changedFile = error else {
                return XCTFail("Expected changedFile, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testTamperWithRestoredModificationTimeCannotReuseDigests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-restored-mtime-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ascmhl-restored-mtime-source-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        let original = Data("verified bytes".utf8)
        let source = sourceRoot.appendingPathComponent("clip.bin")
        let destination = root.appendingPathComponent("clip.bin")
        try original.write(to: source)
        try original.write(to: destination)
        let pinned = try PinnedDestinationDirectory.open(destination: root, rootComponents: [])
        let verification = try await DestinationWriter.verifyPinnedDestinationFile(
            source: source,
            pinnedRoot: pinned,
            relativePath: "clip.bin",
            verificationMode: .standard,
            checksumService: ChecksumEngine.shared
        )

        var before = stat()
        XCTAssertEqual(lstat(destination.path, &before), 0)
        var corrupted = original
        corrupted[0] ^= 0xff
        try corrupted.write(to: destination)
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, destination.path, &times, 0), 0)
        var after = stat()
        XCTAssertEqual(lstat(destination.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        XCTAssertTrue(
            after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
                || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec
        )

        let file = ASCMHLGenerator.VerifiedFile(
            relativePath: "clip.bin",
            size: Int64(original.count),
            expectedSHA256: verification.sourceDigests?.sha256 ?? "",
            verifiedSHA256: verification.destinationDigests?.sha256,
            verifiedMD5: verification.destinationDigests?.md5,
            destinationReadIdentity: verification.destinationReadIdentity
        )
        let reads = MHLReadProbe()
        XCTAssertThrowsError(try ASCMHLGenerator.generateInitialHistory(
            destinationURL: root,
            files: [file],
            startTime: Date(),
            sourceURL: sourceRoot,
            toolVersion: "test",
            readHooks: .init(
                didOpenForRead: { _ in reads.didOpen() },
                didRead: { _, count in reads.didRead(count) }
            )
        )) { error in
            guard case ASCMHLGenerator.GenerationError.changedFile = error else {
                return XCTFail("Expected changedFile, got \(error)")
            }
        }
        XCTAssertEqual(reads.opens, 1)
        XCTAssertEqual(reads.bytes, original.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }
}

private final class MHLReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var openCount = 0
    private var byteCount = 0

    var opens: Int { lock.withLock { openCount } }
    var bytes: Int { lock.withLock { byteCount } }
    func didOpen() { lock.withLock { openCount += 1 } }
    func didRead(_ count: Int) { lock.withLock { byteCount += count } }
}

private final class MHLPublicationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var published: Bool { lock.withLock { value } }
    func record(_ published: Bool) { lock.withLock { value = value || published } }
}
