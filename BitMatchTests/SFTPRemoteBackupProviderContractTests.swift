import CryptoKit
import Foundation
import Testing
@testable import BitMatch

struct SFTPRemoteBackupProviderContractTests {
    @Test func opensshUsesStrictNoninteractiveAgentOnlyArguments() {
        #if os(macOS)
        let arguments = SFTPRemoteBackupProvider.fixedArguments(
            knownHostsURL: URL(fileURLWithPath: "/tmp/profile/known_hosts"), port: 2222, username: "archive", portFlag: "-p"
        )
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("PasswordAuthentication=no"))
        #expect(arguments.contains("KbdInteractiveAuthentication=no"))
        #expect(arguments.contains("PreferredAuthentications=publickey"))
        #expect(arguments.contains("UserKnownHostsFile=/tmp/profile/known_hosts"))

        let sftpArguments = SFTPRemoteBackupProvider.fixedArguments(
            knownHostsURL: URL(fileURLWithPath: "/tmp/profile/known_hosts"), port: 2222, username: nil, portFlag: "-P"
        )
        #expect(!sftpArguments.contains("-l"))
        #endif
    }

    @Test func remotePathsUsePOSIXSingleQuoteEscaping() {
        #if os(macOS)
        #expect(SFTPRemoteBackupProvider.shellQuote("/remote/O'Reilly.mov") == "'/remote/O'\"'\"'Reilly.mov'")
        #endif
    }

    @Test func quotedRemoteNamesRemainOneShellArgument() throws {
        #if os(macOS)
        let name = "O'Reilly; clip.bin"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + SFTPRemoteBackupProvider.shellQuote(name)]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == name)
        #endif
    }

    @Test func sftpArgumentsEscapeQuotesAndRejectControlCharacters() throws {
        #if os(macOS)
        #expect(try SFTPRemoteBackupProvider.sftpQuote("/tmp/a\\b\"c") == "\"/tmp/a\\\\b\\\"c\"")
        #expect(throws: RemoteBackupError.unsafePath) {
            try SFTPRemoteBackupProvider.sftpQuote("/tmp/injected\nput target")
        }
        #endif
    }

    @Test func remotePathsRemainRelativeToTheSFTPAccountRoot() throws {
        #if os(macOS)
        let root = try RemoteRelativePath(components: ["Backups"])
        let file = try RemoteRelativePath(components: ["Jobs", "Card-001.mov"])
        #expect(try SFTPRemoteBackupProvider.relativeRemotePath(root: root, path: file) == "Backups/Jobs/Card-001.mov")
        #endif
    }

    @Test func hostKeyVerificationFailureIsClassifiedBeforeCapabilityFailure() {
        #if os(macOS)
        #expect(SFTPRemoteBackupProvider.classify(stderr: Data("Host key verification failed.".utf8)) == .hostKeyMismatch)
        #endif
    }

    @Test func remoteStorageFailureIsNotMisclassifiedAsNetworkRetry() {
        #if os(macOS)
        #expect(SFTPRemoteBackupProvider.classify(stderr: Data("cat: write error: No space left on device".utf8)) == .remoteStorageFull)
        #expect(SFTPRemoteBackupProvider.classify(stderr: Data("Disk quota exceeded".utf8)) == .remoteStorageFull)
        #endif
    }

    @Test func firstTrustScansAndFingerprintsBeforeSSHAuthentication() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder()
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }
        let provider = SFTPRemoteBackupProvider(
            profile: try fixtureProfile(), credential: .sshAgent, knownHostsURL: knownHosts,
            confirmUnknownHost: { request in request.sha256Fingerprint.contains("SHA256:test") },
            run: { command in await recorder.run(command) }
        )

        _ = try await provider.preflight(profile: try fixtureProfile(), credential: .sshAgent)

        let commands = await recorder.commands()
        #expect(commands.map(\.executable) == ["/usr/bin/ssh-keyscan", "/usr/bin/ssh-keygen", "/usr/bin/ssh"])
        #endif
    }

    @Test func missingRemotePythonFailsClearlyAtPreflight() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder(missingPython: true)
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }
        let profile = try fixtureProfile()
        let provider = SFTPRemoteBackupProvider(profile: profile, credential: .sshAgent,
                                                knownHostsURL: knownHosts, run: { command in await recorder.run(command) })

        await #expect(throws: RemoteBackupError.streamUploadUnavailable) {
            _ = try await provider.preflight(profile: profile, credential: .sshAgent)
        }
        #expect((await recorder.commands()).count == 1)
        #endif
    }

    @Test func promotionLinksWithoutPathnameCleanup() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder()
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }
        let provider = SFTPRemoteBackupProvider(profile: try fixtureProfile(), credential: .sshAgent,
                                                knownHostsURL: knownHosts, run: { command in await recorder.run(command) })
        let temporary = try RemoteRelativePath(components: ["Jobs", ".bitmatch-upload-11111111-2222-3333-4444-555555555555"])
        let final = try RemoteRelativePath(components: ["Jobs", "A.mov"])

        try await provider.promoteNoReplace(temporary: temporary, final: final)

        let commands = await recorder.commands()
        #expect(commands.count == 1)
        #expect(commands[0].arguments.last?.contains("'promote' '[\"Backups\",\"Jobs\",\".bitmatch-upload-11111111-2222-3333-4444-555555555555\"]' '[\"Backups\",\"Jobs\",\"A.mov\"]'") == true)
        #endif
    }

    @Test func nonzeroOffsetStopsBeforeStreaming() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder(inspectLength: 3)
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }
        let provider = SFTPRemoteBackupProvider(profile: try fixtureProfile(), credential: .sshAgent, knownHostsURL: knownHosts, run: { command in await recorder.run(command) })
        let temporary = try RemoteRelativePath(components: ["Jobs", ".bitmatch-upload-item"])

        await #expect(throws: RemoteBackupError.resumeOffsetMismatch(local: 2, remote: 3)) {
            try await provider.upload(local: URL(fileURLWithPath: "/tmp/local.mov"), toTemporary: temporary, fromOffset: 2, expectedSHA256: String(repeating: "a", count: 64)) { _ in }
        }

        #expect(!(await recorder.commands()).contains(where: { $0.standardInputFile != nil }))
        #endif
    }

    @Test func firstUploadClaimsAndStreamsThroughOneSSHCommand() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder()
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }
        let provider = SFTPRemoteBackupProvider(
            profile: try fixtureProfile(), credential: .sshAgent,
            knownHostsURL: knownHosts, run: { command in await recorder.run(command) }
        )
        let temporary = try RemoteRelativePath(components: ["Jobs", ".bitmatch-upload-11111111-2222-3333-4444-555555555555"])

        try await provider.upload(local: URL(fileURLWithPath: "/tmp/local.mov"), toTemporary: temporary, fromOffset: 0, expectedSHA256: String(repeating: "a", count: 64)) { _ in }

        let commands = await recorder.commands()
        #expect(commands.count == 3)
        #expect(commands[0].executable == "/usr/bin/ssh")
        #expect(commands[1].executable == "/usr/bin/ssh")
        #expect(commands[1].arguments.last?.contains("'upload' '[\"Backups\",\"Jobs\",\".bitmatch-upload-11111111-2222-3333-4444-555555555555\"]'") == true)
        #expect(commands[1].standardInputFile == URL(fileURLWithPath: "/tmp/local.mov"))
        #expect(commands[1].expectedInputSHA256 == String(repeating: "a", count: 64))
        #expect(commands[1].standardInput == nil)
        #expect(commands[2].executable == "/usr/bin/ssh")
        #endif
    }

    @Test func failedExclusiveClaimNeverReportsUploadComplete() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder(claimFails: true)
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }
        let provider = SFTPRemoteBackupProvider(
            profile: try fixtureProfile(), credential: .sshAgent,
            knownHostsURL: knownHosts, run: { command in await recorder.run(command) }
        )
        let temporary = try RemoteRelativePath(components: ["Jobs", ".bitmatch-upload-11111111-2222-3333-4444-555555555555"])

        await #expect(throws: RemoteBackupError.temporaryClaimFailed) {
            try await provider.upload(local: URL(fileURLWithPath: "/tmp/local.mov"), toTemporary: temporary, fromOffset: 0, expectedSHA256: String(repeating: "a", count: 64)) { _ in }
        }
        #expect((await recorder.commands()).filter { $0.standardInputFile != nil }.count == 1)
        #endif
    }

    @Test func symlinkedRemoteObjectNeverStartsStream() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder(unsafeInspect: true)
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }
        let provider = SFTPRemoteBackupProvider(
            profile: try fixtureProfile(), credential: .sshAgent,
            knownHostsURL: knownHosts, run: { command in await recorder.run(command) }
        )
        let temporary = try RemoteRelativePath(components: ["Jobs", ".bitmatch-upload-11111111-2222-3333-4444-555555555555"])

        await #expect(throws: RemoteBackupError.unsafePath) {
            try await provider.upload(local: URL(fileURLWithPath: "/tmp/local.mov"), toTemporary: temporary, fromOffset: 0, expectedSHA256: String(repeating: "a", count: 64)) { _ in }
        }
        #expect(!(await recorder.commands()).contains(where: { $0.standardInputFile != nil }))
        #endif
    }

    @Test func discardTemporaryRefusesPathnameOnlyDeletion() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder()
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }

        let provider = SFTPRemoteBackupProvider(
            profile: try fixtureProfile(), credential: .sshAgent,
            knownHostsURL: knownHosts,
            run: { command in await recorder.run(command) }
        )
        let itemID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let temporary = try RemoteRelativePath(
            components: ["Jobs", ".bitmatch-upload-\(itemID.uuidString.lowercased())"]
        )

        await #expect(throws: RemoteBackupError.temporaryCleanupFailed) {
            try await provider.discardTemporary(temporary)
        }

        let commands = await recorder.commands()
        #expect(commands.isEmpty)
        #endif
    }

    @Test func discardTemporaryRejectsFinalAndShellUnsafePathsBeforeSSH() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder()
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }

        let provider = SFTPRemoteBackupProvider(
            profile: try fixtureProfile(), credential: .sshAgent,
            knownHostsURL: knownHosts,
            run: { command in await recorder.run(command) }
        )
        let itemID = "11111111-2222-3333-4444-555555555555"
        let final = try RemoteRelativePath(components: ["Jobs", "Card-001.mov"])
        let malformedTemporary = try RemoteRelativePath(components: ["Jobs", ".bitmatch-upload-item"])
        let shellUnsafeTemporary = try RemoteRelativePath(components: ["Jobs", ".bitmatch-upload-\(itemID);touch"])

        for path in [final, malformedTemporary, shellUnsafeTemporary] {
            await #expect(throws: RemoteBackupError.unsafePath) {
                try await provider.discardTemporary(path)
            }
        }

        #expect(await recorder.commands().isEmpty)
        #endif
    }

    @Test func verifiedModeRequiresNoReplacePromotionCapability() async throws {
        let capabilities = RemoteProviderCapabilities(
            supportsNoReplacePromotion: false,
            supportsVerificationEvidence: true
        )

        #expect(capabilities.missingRequirements(for: .sha256) == [.noReplacePromotion])
    }

    @Test func verifiedModeRequiresVerificationEvidenceCapability() async throws {
        let capabilities = RemoteProviderCapabilities(
            supportsNoReplacePromotion: true,
            supportsVerificationEvidence: false
        )

        #expect(capabilities.missingRequirements(for: .sha256) == [.verificationEvidence])
    }

    @Test func sha256ModeDownloadsAndHashesRemoteBytesWithoutReadingTheCard() async throws {
        #if os(macOS)
        let bytes = Data("remote clip bytes".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let download = SFTPDownloadRecorder(bytes: bytes)
        let provider = SFTPRemoteBackupProvider(
            profile: try fixtureProfile(), credential: .sshAgent,
            run: { command in try await download.run(command) }
        )
        let remoteFile = try RemoteRelativePath(components: ["Jobs", "clip.mov"])

        let evidence = try await provider.verificationEvidence(for: remoteFile, expectedSHA256: digest)
        #expect(evidence == .readBackSHA256(digest))
        #expect(await download.commands().count == 1)
        #expect(await download.downloadedPath().map { !FileManager.default.fileExists(atPath: $0) } == true)

        await #expect(throws: RemoteBackupError.verificationFailed) {
            try await provider.verificationEvidence(for: remoteFile, expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(await download.commands().count == 2)
        #expect(await download.downloadedPath().map { !FileManager.default.fileExists(atPath: $0) } == true)
        #endif
    }

    @Test func uploadOnlyStillRequiresNoReplacePromotion() async throws {
        let capabilities = RemoteProviderCapabilities(
            supportsNoReplacePromotion: false,
            supportsVerificationEvidence: false
        )

        #expect(capabilities.missingRequirements(for: .uploadOnly) == [.noReplacePromotion])
    }

    @Test func typedRemoteErrorsClassifyRetryabilityAndFailClosedState() {
        #expect(RemoteBackupError.networkUnavailable.isTransientNetworkFault)
        #expect(!RemoteBackupError.authenticationFailed.isTransientNetworkFault)
        #expect(RemoteBackupError.authenticationFailed.failClosedState == .paused)
        #expect(RemoteBackupError.unsafePath.failClosedState == .paused)
        #expect(RemoteBackupError.invalidDestination.failClosedState == .paused)
        #expect(RemoteBackupError.permissionDenied.failClosedState == .paused)
    }

    @Test func sshConnectionPartsRejectOptionInjection() throws {
        #if os(macOS)
        #expect(try SFTPRemoteBackupProvider.validatedHost("backup.example") == "backup.example")
        #expect(try SFTPRemoteBackupProvider.validatedHost("  archive-01.lan  ") == "archive-01.lan")
        #expect(try SFTPRemoteBackupProvider.validatedHost("2001:db8::1") == "2001:db8::1")
        for evil in ["-oProxyCommand=touch /tmp/pwned", "--help", "", "host name", "a/b", "a@b", "a;b", "a\nb", "a\u{7}b"] {
            #expect(throws: RemoteBackupError.invalidDestination) {
                try SFTPRemoteBackupProvider.validatedHost(evil)
            }
        }
        #expect(try SFTPRemoteBackupProvider.validatedUsername("archive") == "archive")
        for evil in ["-lroot", "root evil", "a@b", "a/b", "a:b", ""] {
            #expect(throws: RemoteBackupError.invalidDestination) {
                try SFTPRemoteBackupProvider.validatedUsername(evil)
            }
        }
        #expect(try SFTPRemoteBackupProvider.validatedPortNumber(2222) == 2222)
        for badPort in [0, -1, 70_000] {
            #expect(throws: RemoteBackupError.invalidDestination) {
                try SFTPRemoteBackupProvider.validatedPortNumber(badPort)
            }
        }
        #endif
    }

    @Test func optionLikeHostNeverReachesSSH() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder()
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }

        var profile = try fixtureProfile()
        profile.host = "-oProxyCommand=touch /tmp/pwned"
        let provider = SFTPRemoteBackupProvider(
            profile: profile, credential: .sshAgent,
            knownHostsURL: knownHosts,
            run: { command in await recorder.run(command) }
        )

        await #expect(throws: RemoteBackupError.invalidDestination) {
            try await provider.ensureDirectory(try RemoteRelativePath(components: ["Jobs"]))
        }
        #expect(await recorder.commands().isEmpty)
        #endif
    }

    @Test func sshInsertsOptionBoundaryBeforeHost() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder()
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }

        let provider = SFTPRemoteBackupProvider(
            profile: try fixtureProfile(), credential: .sshAgent,
            knownHostsURL: knownHosts,
            run: { command in await recorder.run(command) }
        )
        try await provider.ensureDirectory(try RemoteRelativePath(components: ["Jobs"]))

        let commands = await recorder.commands()
        #expect(commands.count == 1)
        let arguments = commands[0].arguments
        let dashTDashIndex = arguments.firstIndex(of: "-T")
        let hostIndex = arguments.firstIndex(of: "backup.example")
        #expect(dashTDashIndex != nil && hostIndex != nil)
        #expect(arguments[(dashTDashIndex! + 1)...(hostIndex! - 1)].contains("--"))
        #endif
    }
}

#if os(macOS)
private func fixtureProfile() throws -> RemoteDestinationProfile {
    RemoteDestinationProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Archive",
        host: "backup.example", port: 22, username: "archive",
        root: try RemoteRelativePath(components: ["Backups"]), verificationMode: .sha256
    )
}

private actor OpenSSHCommandRecorder {
    private var recorded: [OpenSSHCommand] = []
    private let inspectLength: Int64?
    private let claimFails: Bool
    private let unsafeInspect: Bool
    private let missingPython: Bool

    init(inspectLength: Int64? = nil, claimFails: Bool = false, unsafeInspect: Bool = false, missingPython: Bool = false) {
        self.inspectLength = inspectLength
        self.claimFails = claimFails
        self.unsafeInspect = unsafeInspect
        self.missingPython = missingPython
    }

    func run(_ command: OpenSSHCommand) -> OpenSSHCommandResult {
        recorded.append(command)
        switch command.executable {
        case "/usr/bin/ssh-keyscan":
            return .init(status: 0, stdout: Data("backup.example ssh-ed25519 AAAA\n".utf8), stderr: Data())
        case "/usr/bin/ssh-keygen":
            return .init(status: 0, stdout: Data("256 SHA256:test backup.example\n".utf8), stderr: Data())
        case "/usr/bin/ssh":
            let remoteCommand = command.arguments.last ?? ""
            if missingPython, remoteCommand.hasSuffix(" 'check'") {
                return .init(status: 127, stdout: Data(), stderr: Data("python3: command not found".utf8))
            }
            if remoteCommand.hasSuffix(" 'check'") {
                return .init(status: 0, stdout: Data("__BITMATCH_HELPER_READY__\n".utf8), stderr: Data())
            }
            if command.standardInputFile != nil, claimFails {
                return .init(status: 42, stdout: Data(), stderr: Data("cannot overwrite existing file".utf8))
            }
            if remoteCommand.contains("'inspect'"), unsafeInspect {
                return .init(status: 43, stdout: Data(), stderr: Data("__BITMATCH_UNSAFE_PATH__".utf8))
            }
            let output = remoteCommand.contains("'inspect'")
                ? (inspectLength.map { Data("\($0)\n".utf8) } ?? Data())
                : Data()
            return .init(status: 0, stdout: output, stderr: Data())
        case "/usr/bin/sftp":
            return .init(status: 0, stdout: Data(), stderr: Data())
        default:
            return .init(status: 1, stdout: Data(), stderr: Data("unexpected command".utf8))
        }
    }

    func commands() -> [OpenSSHCommand] { recorded }
}

private actor SFTPDownloadRecorder {
    private let bytes: Data
    private var recorded: [OpenSSHCommand] = []
    private var outputPath: String?

    init(bytes: Data) { self.bytes = bytes }

    func run(_ command: OpenSSHCommand) throws -> OpenSSHCommandResult {
        recorded.append(command)
        guard command.executable == "/usr/bin/ssh",
              command.arguments.last?.contains("'download'") == true,
              command.standardInput == nil,
              command.standardInputFile == nil,
              let outputURL = command.standardOutputFile else {
            throw RemoteBackupError.providerUnavailable
        }
        outputPath = outputURL.path
        try bytes.write(to: outputURL)
        return .init(status: 0, stdout: Data(), stderr: Data())
    }

    func commands() -> [OpenSSHCommand] { recorded }
    func downloadedPath() -> String? { outputPath }
}
#endif
