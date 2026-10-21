// PathContainmentTests.swift
// One containment rule for the engine (plan C18). Most path cases are text
// only; the safety regressions create and remove their own temporary symlinks.
import Foundation
import Testing
@testable import BitMatchEngine

struct PathContainmentTests {
    private let base = "var/folders/bitmatch_contain_\(UUID().uuidString)"

    @Test func lexicalPathMatrix() {
        let cwd = FileManager.default.currentDirectoryPath
        var cwdComponents: [String] = []
        for component in cwd.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." { continue }
            if component == ".." {
                if !cwdComponents.isEmpty { cwdComponents.removeLast() }
            } else {
                cwdComponents.append(component)
            }
        }
        if cwdComponents.count >= 2,
           cwdComponents[0] == "private",
           ["var", "etc", "tmp"].contains(cwdComponents[1]) {
            cwdComponents.removeFirst()
        }
        let relativeLeaf = "/" + (cwdComponents + ["leaf"]).joined(separator: "/")

        let cases: [(input: String, expected: String)] = [
            ("/alpha//beta///gamma/", "/alpha/beta/gamma"),
            ("/alpha/./beta", "/alpha/beta"),
            ("/alpha/beta/../gamma", "/alpha/gamma"),
            ("/../../alpha", "/alpha"),
            ("/../../", "/"),
            ("./relative/../leaf", relativeLeaf),
            ("/literal/%2F/~mike/Crème/CASe", "/literal/%2F/~mike/Crème/CASe"),
            ("/private/var/folders/bitmatch_missing/x", "/var/folders/bitmatch_missing/x"),
            ("/private/etc/config", "/etc/config"),
            ("/private/tmp/cache", "/tmp/cache"),
            ("/private/var/../tmp/cache", "/tmp/cache"),
            ("/privatevar/tmp/cache", "/privatevar/tmp/cache")
        ]

        for testCase in cases {
            #expect(
                PathContainment.comparablePath(testCase.input) == testCase.expected,
                "Unexpected lexical normalization for \(testCase.input)"
            )
        }

        let decomposedUnicode = "/literal/Cafe\u{301}/MiXeD"
        #expect(
            Array(PathContainment.comparablePath(decomposedUnicode).utf8)
                == Array(decomposedUnicode.utf8)
        )
        #expect(!PathContainment.isSamePath("/literal/Case", "/literal/case"))
    }

    @Test func componentsNotPrefixes() {
        #expect(PathContainment.isWithin("/Volumes/T7/Card", root: "/Volumes/T7"))
        #expect(!PathContainment.isWithin("/Volumes/T70/Card", root: "/Volumes/T7"))
        #expect(PathContainment.isWithin("/Volumes/T7", root: "/Volumes/T7"))
        #expect(!PathContainment.isStrictlyWithin("/Volumes/T7", root: "/Volumes/T7"))
        #expect(PathContainment.isStrictlyWithin("/Volumes/T7/a", root: "/Volumes/T7/"))
    }

    /// Plant: make `comparableComponents` return the standardized components unchanged.
    @Test func privateAliasesMatchBothWays() {
        #expect(PathContainment.isWithin("/private/\(base)/CARD", root: "/\(base)"))
        #expect(PathContainment.isWithin("/\(base)/CARD", root: "/private/\(base)"))
        #expect(PathContainment.isSamePath("/private/\(base)", "/\(base)"))
        #expect(PathContainment.comparablePath("/private/\(base)/x") == "/\(base)/x")
        #expect(!PathContainment.isWithin("/privatevar/x", root: "/var"))
    }

    /// This fixture intentionally distinguishes lexical text containment from
    /// filesystem resolution. If `..` follows an existing symlink, resolving
    /// the path may lead somewhere other than reducing the text components.
    /// PathContainment's contract is lexical; callers needing the filesystem
    /// target must resolve the symlink before passing the path.
    @Test func lexicalResultDoesNotChangeWhenPathAndSymlinkAppear() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.path + "/BitMatch-PathContainment-" + UUID().uuidString
        let parent = fixture + "/parent"
        let elsewhere = fixture + "/elsewhere"
        let link = parent + "/link"
        let candidate = link + "/../leaf"
        let lexicalTarget = parent + "/leaf"
        let symlinkResolvedTarget = fixture + "/leaf"
        defer { try? fm.removeItem(atPath: fixture) }

        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)

        let beforeLink = PathContainment.comparablePath(candidate)
        let expectedLexical = PathContainment.comparablePath(lexicalTarget)
        #expect(beforeLink == expectedLexical)

        try fm.createSymbolicLink(atPath: link, withDestinationPath: elsewhere)
        try Data("lexical target".utf8).write(to: URL(fileURLWithPath: lexicalTarget))
        try Data("symlink target".utf8).write(to: URL(fileURLWithPath: symlinkResolvedTarget))
        try Data("through link".utf8).write(to: URL(fileURLWithPath: elsewhere + "/item"))

        #expect(fm.fileExists(atPath: candidate))
        #expect(PathContainment.comparablePath(candidate) == beforeLink)
        #expect(PathContainment.comparablePath(candidate) == expectedLexical)

        // The old Foundation standardization can differ when it interprets
        // `link/..` through this existing symlink. Record both legitimate
        // outcomes explicitly rather than claiming the new lexical contract
        // is behavior-identical for unresolved symlink paths.
        let oldFoundationPath = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let oldFoundationComparable = PathContainment.comparablePath(oldFoundationPath)
        let expectedResolved = PathContainment.comparablePath(symlinkResolvedTarget)
        #expect(oldFoundationComparable == expectedLexical || oldFoundationComparable == expectedResolved)

        // Callers that need filesystem identity still resolve first.
        let resolvedByCaller = URL(fileURLWithPath: link + "/item").resolvingSymlinksInPath().path
        #expect(
            PathContainment.comparablePath(resolvedByCaller)
                == PathContainment.comparablePath(elsewhere + "/item")
        )
    }

    /// A path that traverses an existing symlink and then `..` names the
    /// filesystem target, even though reducing the text alone names a
    /// different path. Live overlap validation must follow the former.
    @Test func folderOverlapResolvesSymlinkBeforeParentTraversal() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.path + "/BitMatch-PathContainment-Overlap-" + UUID().uuidString
        let sourcePath = fixture + "/source"
        let parent = fixture + "/parent"
        let elsewhere = fixture + "/elsewhere"
        let link = parent + "/link"
        let destinationPath = link + "/../source"
        defer { try? fm.removeItem(atPath: fixture) }

        try fm.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: elsewhere)

        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        #expect(fm.fileExists(atPath: destinationPath))
        #expect(PathContainment.comparablePath(destinationPath) != PathContainment.comparablePath(sourcePath))
        #expect(SafetyValidator.folderOverlap(source, destination) == .same)
        #expect(SafetyValidator.destinationSafetyIssue(source: source, destination: destination) == "Destination is the source folder")
    }

    /// Resolving an existing alias must also preserve containment when the
    /// requested child below that alias does not exist yet.
    @Test func destinationSafetyRejectsNonexistentChildBelowSourceAlias() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.path + "/BitMatch-PathContainment-Nonexistent-" + UUID().uuidString
        let sourcePath = fixture + "/source"
        let alias = fixture + "/source-alias"
        defer { try? fm.removeItem(atPath: fixture) }

        try fm.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: sourcePath)

        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: alias + "/not-created/yet", isDirectory: true)
        #expect(!fm.fileExists(atPath: destination.path))
        #expect(SafetyValidator.folderOverlap(source, destination) == .secondInsideFirst)
        #expect(SafetyValidator.destinationSafetyIssue(source: source, destination: destination) == "Destination is inside the source folder")
    }

    @Test func folderOverlapFindsNonexistentSourceBelowDestinationAlias() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.path + "/BitMatch-PathContainment-SourceAlias-" + UUID().uuidString
        let destinationPath = fixture + "/destination"
        let alias = fixture + "/destination-alias"
        defer { try? fm.removeItem(atPath: fixture) }

        try fm.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: destinationPath)

        let source = URL(fileURLWithPath: alias + "/not-created/yet", isDirectory: true)
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        #expect(!fm.fileExists(atPath: source.path))
        #expect(SafetyValidator.folderOverlap(source, destination) == .firstInsideSecond)
        #expect(SafetyValidator.destinationSafetyIssue(source: source, destination: destination) == "Destination contains the source folder")
    }

    @Test func outsideSymlinkTargetDoesNotCreateFalseOverlap() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.path + "/BitMatch-PathContainment-OutsideAlias-" + UUID().uuidString
        let sourcePath = fixture + "/source"
        let outsidePath = fixture + "/outside"
        let alias = fixture + "/source-alias"
        defer { try? fm.removeItem(atPath: fixture) }

        try fm.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outsidePath, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: outsidePath)

        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: alias + "/not-created/yet", isDirectory: true)
        #expect(!fm.fileExists(atPath: destination.path))
        #expect(SafetyValidator.folderOverlap(source, destination) == nil)
        #expect(SafetyValidator.destinationSafetyIssue(source: source, destination: destination) == nil)
    }

    @Test func fixedTemporaryAliasKeepsNonexistentDescendantContained() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.standardizedFileURL
            .appendingPathComponent("BitMatch-PathContainment-SystemAlias-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = fixture.appendingPathComponent("source", isDirectory: true)
        let sourcePath = sourceURL.path
        let alternatePath: String?
        if sourcePath.hasPrefix("/private/var/") {
            alternatePath = String(sourcePath.dropFirst("/private".count))
        } else if sourcePath.hasPrefix("/var/") {
            alternatePath = "/private" + sourcePath
        } else if sourcePath.hasPrefix("/private/tmp/") {
            alternatePath = String(sourcePath.dropFirst("/private".count))
        } else if sourcePath.hasPrefix("/tmp/") {
            alternatePath = "/private" + sourcePath
        } else {
            // The platform's temp root does not use one of the fixed aliases.
            return
        }
        guard let alternatePath else { return }
        defer { try? fm.removeItem(at: fixture) }
        try fm.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let destination = URL(fileURLWithPath: alternatePath + "/not-created/yet", isDirectory: true)
        #expect(!fm.fileExists(atPath: destination.path))
        #expect(SafetyValidator.folderOverlap(sourceURL, destination) == .secondInsideFirst)
        #expect(SafetyValidator.destinationSafetyIssue(source: sourceURL, destination: destination) == "Destination is inside the source folder")
    }

    @Test func sixteenSymlinkPrefixesResolveBeforeNonexistentTail() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.path + "/BitMatch-PathContainment-LinkChain-" + UUID().uuidString
        let sourcePath = fixture + "/source"
        defer { try? fm.removeItem(atPath: fixture) }

        try fm.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
        for index in 0..<16 {
            let link = fixture + "/link-\(index)"
            let target = index == 15 ? sourcePath : fixture + "/link-\(index + 1)"
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        }

        let source = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let destination = URL(fileURLWithPath: fixture + "/link-0/not-created/yet", isDirectory: true)
        #expect(!fm.fileExists(atPath: destination.path))
        #expect(SafetyValidator.folderOverlap(source, destination) == .secondInsideFirst)
        #expect(SafetyValidator.destinationSafetyIssue(source: source, destination: destination) == "Destination is inside the source folder")
    }

    @Test func destinationValidationRejectsSymlinkCycleWithoutWriting() async throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.path + "/BitMatch-PathContainment-Cycle-" + UUID().uuidString
        let source = URL(fileURLWithPath: fixture + "/source", isDirectory: true)
        let first = URL(fileURLWithPath: fixture + "/cycle-a", isDirectory: true)
        let second = URL(fileURLWithPath: fixture + "/cycle-b", isDirectory: true)
        defer { try? fm.removeItem(atPath: fixture) }

        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceMarker = source.appendingPathComponent("source.txt")
        try Data("preserve source".utf8).write(to: sourceMarker)
        try fm.createSymbolicLink(at: first, withDestinationURL: second)
        try fm.createSymbolicLink(at: second, withDestinationURL: first)

        var wasRejected = false
        do {
            try await SafetyValidator.performSafetyChecks(
                source: source,
                destinations: [first],
                sourceSizeBytes: 0
            )
        } catch {
            wasRejected = true
        }

        #expect(wasRejected)
        let preservedSource = try Data(contentsOf: sourceMarker)
        #expect(preservedSource == Data("preserve source".utf8))
        #expect(!fm.fileExists(atPath: fixture + "/cycle-a/source"))
    }

    /// A restored backup in the temporary folder is refused under either
    /// spelling. (Symlink resolution already made both spellings agree here
    /// before C18; this pins it.)
    /// Plant: delete the temporary-roots check in `BackupTargetPolicy.refusal`.
    @Test func backupPolicyRefusesTemporaryFolderAcrossAlias() {
        let temporary = URL(fileURLWithPath: "/private/\(base)/T", isDirectory: true)
        let target = URL(fileURLWithPath: "/\(base)/T/Backups", isDirectory: true)
        let facts = BackupTargetPolicy.VolumeFacts(
            volumeRootPath: "/Volumes/Scratch", volumeID: "SCRATCH", volumeName: "Scratch",
            isRootFileSystem: false, isInternal: false, isRemovable: true, isEjectable: true
        )
        let refusal = BackupTargetPolicy.refusal(
            for: target, origin: .restored, source: nil,
            facts: { _ in facts }, temporaryDirectory: temporary
        )
        #expect(refusal?.hasSuffix("is a temporary folder.") == true)
    }

    /// The same backup chosen under both spellings is a duplicate.
    /// Plant: in `TransferReadiness.assess`, drop `PathContainment.comparablePath` from the uniqueness set.
    @Test func sameBackupUnderBothSpellingsIsADuplicate() {
        let readiness = TransferReadiness.assess(
            source: URL(fileURLWithPath: "/Volumes/CARD", isDirectory: true), sourceBytes: 1,
            isAnalysingSource: false,
            destinations: [URL(fileURLWithPath: "/private/\(base)/SSD"), URL(fileURLWithPath: "/\(base)/SSD")],
            settings: CameraLabelSettings(), verificationMode: .standard,
            availableBytes: { _ in .max }, isWritable: { _ in true }
        )
        #expect(readiness.blockers.contains("Destination folders must be unique"))
    }
}
