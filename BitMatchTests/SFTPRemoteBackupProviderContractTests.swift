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
        #expect(SFTPRemoteBackupProvider.shellQuote("/remote/O'Reilly.mov") == "'/remote/O'\\\"'\\\"'Reilly.mov'")
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

    @Test func existingFinalFromLnIsClassifiedAsConflict() {
        #if os(macOS)
        #expect(SFTPRemoteBackupProvider.promotionError(stderr: Data("ln: File exists".utf8)) == .conflict)
        #expect(SFTPRemoteBackupProvider.promotionError(stderr: Data("shell disabled".utf8)) == .capabilityUnavailable(.noReplacePromotion))
        #endif
    }

    @Test func hostKeyVerificationFailureIsClassifiedBeforeCapabilityFailure() {
        #if os(macOS)
        #expect(SFTPRemoteBackupProvider.classify(stderr: Data("Host key verification failed.".utf8)) == .hostKeyMismatch)
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

    @Test func resumeOffsetMismatchStopsBeforeSFTPTransfer() async throws {
        #if os(macOS)
        let recorder = OpenSSHCommandRecorder(inspectLength: 3)
        let knownHosts = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("known_hosts")
        try FileManager.default.createDirectory(at: knownHosts.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("backup.example ssh-ed25519 AAAA\n".utf8).write(to: knownHosts)
        defer { try? FileManager.default.removeItem(at: knownHosts.deletingLastPathComponent()) }
        let provider = SFTPRemoteBackupProvider(profile: try fixtureProfile(), credential: .sshAgent, knownHostsURL: knownHosts, run: { command in await recorder.run(command) })
        let temporary = try RemoteRelativePath(components: ["Jobs", ".bitmatch-upload-item"])

        await #expect(throws: RemoteBackupError.resumeOffsetMismatch(local: 2, remote: 3)) {
            try await provider.upload(local: URL(fileURLWithPath: "/tmp/local.mov"), toTemporary: temporary, fromOffset: 2) { _ in }
        }

        #expect(!(await recorder.commands()).contains(where: { $0.executable == "/usr/bin/sftp" }))
        #endif
    }

    @Test func discardTemporaryAcceptsOnlyItemOwnedUUIDPath() async throws {
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

        try await provider.discardTemporary(temporary)

        let commands = await recorder.commands()
        #expect(commands.count == 1)
        #expect(commands[0].executable == "/usr/bin/ssh")
        #expect(commands[0].arguments.last == "rm -f 'Backups/Jobs/.bitmatch-upload-11111111-2222-3333-4444-555555555555'")
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

    init(inspectLength: Int64? = nil) { self.inspectLength = inspectLength }

    func run(_ command: OpenSSHCommand) -> OpenSSHCommandResult {
        recorded.append(command)
        switch command.executable {
        case "/usr/bin/ssh-keyscan":
            return .init(status: 0, stdout: Data("backup.example ssh-ed25519 AAAA\n".utf8), stderr: Data())
        case "/usr/bin/ssh-keygen":
            return .init(status: 0, stdout: Data("256 SHA256:test backup.example\n".utf8), stderr: Data())
        case "/usr/bin/ssh":
            let output = inspectLength.map { Data("\($0)\n".utf8) } ?? Data()
            return .init(status: 0, stdout: output, stderr: Data())
        default:
            return .init(status: 1, stdout: Data(), stderr: Data("unexpected command".utf8))
        }
    }

    func commands() -> [OpenSSHCommand] { recorded }
}

private actor SFTPDownloadRecorder {
    private let bytes: Data
    private var recorded: [OpenSSHCommand] = []
    private var path: String?

    init(bytes: Data) { self.bytes = bytes }

    func run(_ command: OpenSSHCommand) throws -> OpenSSHCommandResult {
        recorded.append(command)
        guard command.executable == "/usr/bin/sftp",
              let batch = command.standardInput.flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw RemoteBackupError.providerUnavailable
        }
        let fields = batch.components(separatedBy: "\"")
        guard fields.count >= 4, fields[0] == "get ", fields[1] == "Backups/Jobs/clip.mov" else {
            throw RemoteBackupError.providerUnavailable
        }
        path = fields[3]
        try bytes.write(to: URL(fileURLWithPath: fields[3]))
        return .init(status: 0, stdout: Data(), stderr: Data())
    }

    func commands() -> [OpenSSHCommand] { recorded }
    func downloadedPath() -> String? { path }
}
#endif
