import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

#if os(macOS)
/// Run through Scripts/test-local-sftp.sh. It supplies a disposable localhost
/// sshd, temporary agent key, pinned known_hosts, and temporary remote root.
/// This test never uses saved BitMatch profiles or credentials.
struct SFTPRemoteBackupLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_LIVE_SFTP_TEST"] == "1"
        || ProcessInfo.processInfo.environment["TEST_RUNNER_BITMATCH_LIVE_SFTP_TEST"] == "1"))
    func firstUploadReadbackAndNoReplacePromotion() async throws {
        let environment = ProcessInfo.processInfo.environment
        let portText = try #require(environment["BITMATCH_LIVE_SFTP_PORT"]
            ?? environment["TEST_RUNNER_BITMATCH_LIVE_SFTP_PORT"])
        let port = try #require(Int(portText))
        let knownHostsPath = try #require(environment["BITMATCH_LIVE_SFTP_KNOWN_HOSTS"]
            ?? environment["TEST_RUNNER_BITMATCH_LIVE_SFTP_KNOWN_HOSTS"])
        let agentSocket = try #require(environment["BITMATCH_LIVE_SFTP_AGENT_SOCK"]
            ?? environment["TEST_RUNNER_BITMATCH_LIVE_SFTP_AGENT_SOCK"])
        let remoteDirectoryPath = try #require(environment["BITMATCH_LIVE_SFTP_REMOTE_DIR"]
            ?? environment["TEST_RUNNER_BITMATCH_LIVE_SFTP_REMOTE_DIR"])
        let remoteDirectory = URL(fileURLWithPath: remoteDirectoryPath).standardizedFileURL
        try #require(remoteDirectory.path.hasPrefix("/tmp/bitmatch-sftp-smoke.")
            || remoteDirectory.path.hasPrefix("/private/tmp/bitmatch-sftp-smoke."))
        try #require(FileManager.default.fileExists(atPath: remoteDirectory
            .appendingPathComponent(".bitmatch-disposable-sftp-server").path))
        #expect(FileManager.default.fileExists(atPath: agentSocket))
        // This opt-in test runs alone. Only its process and OpenSSH children
        // see the disposable agent; the user's own agent remains untouched.
        setenv("SSH_AUTH_SOCK", agentSocket, 1)

        let profile = RemoteDestinationProfile(
            id: UUID(), name: "Disposable localhost test", host: "127.0.0.1", port: port,
            username: NSUserName(), root: try RemoteRelativePath(components: ["Backups"]),
            verificationMode: .sha256
        )
        let provider = SFTPRemoteBackupProvider(
            profile: profile, credential: .sshAgent,
            knownHostsURL: URL(fileURLWithPath: knownHostsPath)
        )
        let capabilities = try await provider.preflight(profile: profile, credential: .sshAgent)
        #expect(capabilities.missingRequirements(for: .sha256).isEmpty)

        let folder = try RemoteRelativePath(components: ["Run-\(UUID().uuidString.lowercased())"])
        try await provider.ensureDirectory(folder)
        let firstTemporary = try folder.appending(".bitmatch-upload-\(UUID().uuidString.lowercased())")
        let secondTemporary = try folder.appending(".bitmatch-upload-\(UUID().uuidString.lowercased())")
        let final = try folder.appending("clip.bin")

        let localFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localFolder) }
        let source = localFolder.appendingPathComponent("source.bin")
        let contender = localFolder.appendingPathComponent("contender.bin")
        try Data("BitMatch disposable first upload\n".utf8).write(to: source)
        try Data("different bytes\n".utf8).write(to: contender)
        let expected = try await ChecksumEngine.shared.generateChecksum(for: source, type: .sha256)
        let contenderExpected = try await ChecksumEngine.shared.generateChecksum(for: contender, type: .sha256)

        try await provider.upload(local: source, toTemporary: firstTemporary, fromOffset: 0, expectedSHA256: expected) { _ in }
        #expect(try await provider.inspect(path: firstTemporary)?.byteCount == Int64(Data("BitMatch disposable first upload\n".utf8).count))
        try await provider.promoteNoReplace(temporary: firstTemporary, final: final)
        #expect(try await provider.confirmsOwnedFinal(temporary: firstTemporary, final: final))
        #expect(try await provider.inspect(path: firstTemporary)?.byteCount == Int64(Data("BitMatch disposable first upload\n".utf8).count))
        let firstTemporaryOnDisk = remoteDirectory.appendingPathComponent("Backups")
            .appendingPathComponent(folder.description)
            .appendingPathComponent(try #require(firstTemporary.components.last))
        let finalOnDisk = remoteDirectory.appendingPathComponent("Backups")
            .appendingPathComponent(folder.description).appendingPathComponent("clip.bin")
        let temporaryInode = try #require(FileManager.default.attributesOfItem(atPath: firstTemporaryOnDisk.path)[.systemFileNumber] as? NSNumber)
        let finalInode = try #require(FileManager.default.attributesOfItem(atPath: finalOnDisk.path)[.systemFileNumber] as? NSNumber)
        #expect(temporaryInode == finalInode)
        #expect(try await provider.verificationEvidence(for: final, expectedSHA256: expected) == .readBackSHA256(expected))

        let linked = try folder.appending("linked")
        let dangling = try folder.appending("dangling")
        try FileManager.default.createSymbolicLink(
            at: finalOnDisk.deletingLastPathComponent().appendingPathComponent("linked"),
            withDestinationURL: finalOnDisk
        )
        try FileManager.default.createSymbolicLink(
            at: finalOnDisk.deletingLastPathComponent().appendingPathComponent("dangling"),
            withDestinationURL: finalOnDisk.deletingLastPathComponent().appendingPathComponent("missing.bin")
        )
        await #expect(throws: RemoteBackupError.unsafePath) { _ = try await provider.inspect(path: linked) }
        await #expect(throws: RemoteBackupError.unsafePath) { _ = try await provider.inspect(path: dangling) }

        // A symlink to an existing sink is more dangerous than a dangling
        // link: shell noclobber can follow it and report a successful upload.
        let deviceLink = try folder.appending(".bitmatch-upload-\(UUID().uuidString.lowercased())")
        try FileManager.default.createSymbolicLink(
            at: finalOnDisk.deletingLastPathComponent().appendingPathComponent(try #require(deviceLink.components.last)),
            withDestinationURL: URL(fileURLWithPath: "/dev/null")
        )
        await #expect(throws: RemoteBackupError.unsafePath) {
            try await provider.upload(local: source, toTemporary: deviceLink, fromOffset: 0, expectedSHA256: expected) { _ in }
        }

        try await provider.upload(local: contender, toTemporary: secondTemporary, fromOffset: 0, expectedSHA256: contenderExpected) { _ in }
        #expect(try await provider.confirmsOwnedFinal(temporary: secondTemporary, final: final) == false)
        await #expect(throws: RemoteBackupError.conflict) {
            try await provider.promoteNoReplace(temporary: secondTemporary, final: final)
        }
        #expect(try await provider.verificationEvidence(for: final, expectedSHA256: expected) == .readBackSHA256(expected))

        // Plain `ln temp link-to-directory` treats the link as a directory and
        // succeeds by writing inside it. No-follow promotion must refuse it.
        let outsideDirectory = remoteDirectory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let directoryLink = finalOnDisk.deletingLastPathComponent().appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: outsideDirectory)
        await #expect(throws: RemoteBackupError.conflict) {
            try await provider.promoteNoReplace(
                temporary: secondTemporary,
                final: try folder.appending("directory-link")
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path).isEmpty)

        // Names are JSON path components inside one shell-quoted helper
        // invocation; punctuation must remain data, never shell syntax.
        let quotedTemporary = try folder.appending(".bitmatch-upload-\(UUID().uuidString.lowercased())")
        let quotedFinal = try folder.appending("O'Reilly; clip.bin")
        try await provider.upload(local: source, toTemporary: quotedTemporary, fromOffset: 0, expectedSHA256: expected) { _ in }
        try await provider.promoteNoReplace(temporary: quotedTemporary, final: quotedFinal)
        #expect(try await provider.verificationEvidence(for: quotedFinal, expectedSHA256: expected) == .readBackSHA256(expected))
    }
}
#endif
