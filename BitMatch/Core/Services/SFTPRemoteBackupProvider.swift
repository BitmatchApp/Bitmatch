import Foundation
import BitMatchEngine
import CryptoKit

struct OpenSSHHostTrustRequest: Equatable, Sendable {
    let host: String
    let port: Int
    let sha256Fingerprint: String
}

typealias OpenSSHHostTrustConfirmation = @Sendable (OpenSSHHostTrustRequest) async throws -> Bool

enum SFTPRemoteBackupProviderFactory {
    static func make(profile: RemoteDestinationProfile, credential: RemoteCredential, confirmUnknownHost: OpenSSHHostTrustConfirmation? = nil) async throws -> any RemoteBackupProvider {
        #if os(macOS)
        return SFTPRemoteBackupProvider(profile: profile, credential: credential, confirmUnknownHost: confirmUnknownHost)
        #else
        throw RemoteBackupError.providerUnavailable
        #endif
    }
}

#if os(macOS)
import Darwin

struct OpenSSHCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let standardInput: Data?
    /// Stream a verified local backup directly into SSH without loading it
    /// into memory or reopening a remote pathname after the exclusive claim.
    let standardInputFile: URL?
    /// Immutable manifest digest. The exact descriptor sent to SSH is hashed
    /// before launch, closing the validation-then-reopen pathname gap.
    let expectedInputSHA256: String?
    /// Stream remote readback into an exclusive local file. Capturing the
    /// command's stdout in Data would scale memory with footage size.
    let standardOutputFile: URL?

    init(executable: String, arguments: [String], standardInput: Data?, standardInputFile: URL? = nil, expectedInputSHA256: String? = nil, standardOutputFile: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
        self.standardInputFile = standardInputFile
        self.expectedInputSHA256 = expectedInputSHA256
        self.standardOutputFile = standardOutputFile
    }
}

struct OpenSSHCommandResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// The confirmation closure is an intentional UI boundary. It must display
/// the supplied fingerprint and return true only after deliberate user
/// confirmation; the adapter persists the exact scanned key material itself.
typealias OpenSSHCommandRunner = @Sendable (OpenSSHCommand) async throws -> OpenSSHCommandResult

private final class OpenSSHProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var drainError: Error?
    private var inputWriteFailed = false

    func setStdout(_ data: Data) { lock.withLock { stdout = data } }
    func setStderr(_ data: Data) { lock.withLock { stderr = data } }
    func setDrainError(_ error: Error) { lock.withLock { drainError = error } }
    func markInputWriteFailure() { lock.withLock { inputWriteFailed = true } }
    func result(status: Int32) throws -> OpenSSHCommandResult {
        try lock.withLock {
            if let drainError { throw drainError }
            if status == 0 && inputWriteFailed { throw RemoteBackupError.providerUnavailable }
            return OpenSSHCommandResult(status: status, stdout: stdout, stderr: stderr)
        }
    }
}

private struct OpenSSHInputIdentity: Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(fileDescriptor: Int32) throws {
        var info = stat()
        guard Darwin.fstat(fileDescriptor, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw RemoteBackupError.localArtifactNotVerified
        }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
        byteCount = Int64(info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }
}

/// Owns one launched OpenSSH command until it exits and both pipes drain. A
/// ProxyCommand may leave descendants holding those pipes after ssh exits, so
/// cancellation signals the group created atomically with the child.
private final class OpenSSHProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var childPID: pid_t?
    private var cancelled = false
    private var finished = false
    private var forceKill: DispatchWorkItem?

    func launch(_ command: OpenSSHCommand, input: Pipe, inputFileFD: Int32?, output: Pipe, error: Pipe) throws -> pid_t {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            var actions: posix_spawn_file_actions_t?
            try Self.check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }

            let inputRead = input.fileHandleForReading.fileDescriptor
            let outputWrite = output.fileHandleForWriting.fileDescriptor
            let errorWrite = error.fileHandleForWriting.fileDescriptor
            try Self.check(posix_spawn_file_actions_adddup2(&actions, inputFileFD ?? inputRead, STDIN_FILENO))
            try Self.check(posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO))
            try Self.check(posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO))
            let descriptors = [inputRead, outputWrite, errorWrite,
                               input.fileHandleForWriting.fileDescriptor,
                               output.fileHandleForReading.fileDescriptor,
                               error.fileHandleForReading.fileDescriptor,
                               inputFileFD].compactMap { $0 }
            for descriptor in Set(descriptors) where descriptor > STDERR_FILENO {
                try Self.check(posix_spawn_file_actions_addclose(&actions, descriptor))
            }

            var attributes: posix_spawnattr_t?
            try Self.check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try Self.check(posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ))
            try Self.check(posix_spawnattr_setpgroup(&attributes, 0))

            let strings = ([command.executable] + command.arguments).map { $0.withCString { strdup($0) } }
            defer { strings.forEach { free($0) } }
            guard strings.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
            var arguments = strings + [nil]
            var pid: pid_t = 0
            let spawnError = command.executable.withCString { executable in
                arguments.withUnsafeMutableBufferPointer { buffer in
                    posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress, environ)
                }
            }
            try Self.check(spawnError)
            childPID = pid
            return pid
        }
    }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    }

    func cancel() {
        lock.withLock {
            guard !finished else { return }
            cancelled = true
            guard childPID != nil else { return }
            signal(SIGTERM)
            let work = DispatchWorkItem { [weak self] in self?.forceKillIfUnfinished() }
            forceKill = work
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    private func forceKillIfUnfinished() {
        lock.withLock {
            guard !finished else { return }
            signal(SIGKILL)
        }
    }

    /// A terminated direct child does not mean its pipe-owning descendants
    /// have exited. Keep signalling the owned group until both drains finish.
    private func signal(_ value: Int32) {
        if let childPID, childPID > 0 { _ = Darwin.kill(-childPID, value) }
    }

    func complete() -> Bool {
        lock.withLock {
            finished = true
            childPID = nil
            forceKill?.cancel()
            forceKill = nil
            return cancelled
        }
    }
}

actor SFTPRemoteBackupProvider: RemoteBackupProvider {
    private let profile: RemoteDestinationProfile
    private let credential: RemoteCredential
    private let knownHostsURL: URL
    private let confirmUnknownHost: OpenSSHHostTrustConfirmation?
    private let run: OpenSSHCommandRunner

    init(
        profile: RemoteDestinationProfile,
        credential: RemoteCredential,
        knownHostsURL: URL? = nil,
        confirmUnknownHost: OpenSSHHostTrustConfirmation? = nil,
        run: OpenSSHCommandRunner? = nil
    ) {
        self.profile = profile
        self.credential = credential
        self.knownHostsURL = knownHostsURL ?? Self.profileKnownHostsURL(profileID: profile.id)
        self.confirmUnknownHost = confirmUnknownHost
        self.run = run ?? { try await SFTPRemoteBackupProvider.runProcess($0) }
    }

    func preflight(profile requested: RemoteDestinationProfile, credential supplied: RemoteCredential) async throws -> RemoteProviderCapabilities {
        guard requested.id == profile.id, supplied == credential, supplied.isSSHAgentOnly else {
            throw RemoteBackupError.authenticationFailed
        }
        try await establishExplicitTrustIfNeeded()
        let result = try await run(try helperCommand(action: "check"))
        guard result.status == 0,
              String(decoding: result.stdout, as: UTF8.self).contains("__BITMATCH_HELPER_READY__") else {
            throw result.status == 255 ? classify(result) : RemoteBackupError.streamUploadUnavailable
        }
        return RemoteProviderCapabilities(supportsNoReplacePromotion: true, supportsVerificationEvidence: true)
    }

    func inspect(path: RemoteRelativePath) async throws -> RemoteObject? {
        let result = try await run(try helperCommand(action: "inspect", paths: [path]))
        guard result.status == 0 else { throw classifyHelper(result) }
        let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        guard let count = Int64(output), count >= 0 else { throw RemoteBackupError.providerUnavailable }
        return RemoteObject(byteCount: count)
    }

    func ensureDirectory(_ path: RemoteRelativePath) async throws {
        let result = try await run(try helperCommand(action: "mkdir", paths: [path]))
        guard result.status == 0 else { throw classifyHelper(result) }
    }

    func discardTemporary(_ path: RemoteRelativePath) async throws {
        guard let basename = path.components.last,
              basename.hasPrefix(".bitmatch-upload-"),
              UUID(uuidString: String(basename.dropFirst(".bitmatch-upload-".count))) != nil
        else {
            throw RemoteBackupError.unsafePath
        }
        // Even an item-owned name can be replaced between a check and `rm`.
        // The queue rotates attempt names and leaves old partials for explicit
        // operator cleanup instead of unlinking a possible replacement.
        throw RemoteBackupError.temporaryCleanupFailed
    }

    func upload(local: URL, toTemporary path: RemoteRelativePath, fromOffset: Int64, expectedSHA256: String, progress: @Sendable (Int64) async -> Void) async throws {
        try Task.checkCancellation()
        guard expectedSHA256.count == 64,
              expectedSHA256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw RemoteBackupError.localArtifactNotVerified
        }
        let remoteObject = try await inspect(path: path)
        try Task.checkCancellation()
        guard fromOffset == 0 else {
            throw RemoteBackupError.resumeOffsetMismatch(local: fromOffset, remote: remoteObject?.byteCount ?? 0)
        }
        guard remoteObject == nil else {
            throw RemoteBackupError.temporaryClaimFailed
        }
        // The helper pins each parent directory and opens the leaf with
        // O_EXCL|O_NOFOLLOW. A pathname swap cannot redirect its stream.
        let sshCommand = try helperCommand(action: "upload", paths: [path])
        let result = try await run(OpenSSHCommand(
            executable: sshCommand.executable,
            arguments: sshCommand.arguments,
            standardInput: nil,
            standardInputFile: local,
            expectedInputSHA256: expectedSHA256
        ))
        try Task.checkCancellation()
        guard result.status == 0 else { throw classifyHelper(result, claim: true) }
        let complete = try await inspect(path: path)?.byteCount ?? 0
        try Task.checkCancellation()
        await progress(complete)
    }

    func promoteNoReplace(temporary: RemoteRelativePath, final: RemoteRelativePath) async throws {
        // linkat pins both parent directories, refuses an existing final name
        // (including a directory symlink), and leaves the temp hard link for
        // explicit operator cleanup. No pathname-only removal follows it.
        let result = try await run(try helperCommand(action: "promote", paths: [temporary, final]))
        guard result.status == 0 else { throw classifyHelper(result, promotion: true) }
    }

    func confirmsOwnedFinal(temporary: RemoteRelativePath, final: RemoteRelativePath) async throws -> Bool {
        let result = try await run(try helperCommand(action: "same", paths: [temporary, final]))
        // A replaced symlink or non-file is never ownership evidence.
        if result.status == 43 { return false }
        guard result.status == 0 else { throw classifyHelper(result) }
        let answer = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch answer {
        case "__BITMATCH_SAME__": return true
        case "__BITMATCH_DIFFERENT__": return false
        default: throw RemoteBackupError.providerUnavailable
        }
    }

    func verificationEvidence(for path: RemoteRelativePath, expectedSHA256: String) async throws -> RemoteVerificationEvidence {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let sshCommand = try helperCommand(action: "download", paths: [path])
        let result = try await run(OpenSSHCommand(
            executable: sshCommand.executable,
            arguments: sshCommand.arguments,
            standardInput: nil,
            standardOutputFile: temporary
        ))
        guard result.status == 0 else { throw classifyHelper(result) }
        try Task.checkCancellation()
        let actual = try await ChecksumEngine.shared.generateChecksum(for: temporary, type: .sha256)
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else { throw RemoteBackupError.verificationFailed }
        return .readBackSHA256(actual)
    }

    func close() async {}

    static func profileKnownHostsURL(profileID: UUID) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BitMatch/SFTP/\(profileID.uuidString.lowercased())/known_hosts")
    }

    private func establishExplicitTrustIfNeeded() async throws {
        guard !FileManager.default.fileExists(atPath: knownHostsURL.path) else { return }
        guard let confirmUnknownHost else { throw RemoteBackupError.hostKeyMismatch }
        let scanned = try await run(OpenSSHCommand(
            executable: "/usr/bin/ssh-keyscan",
            arguments: ["-p", "\(try Self.validatedPortNumber(profile.port))", try Self.validatedHost(profile.host)],
            standardInput: nil
        ))
        guard scanned.status == 0, !scanned.stdout.isEmpty else { throw RemoteBackupError.hostKeyMismatch }
        let fingerprint = try await run(OpenSSHCommand(
            executable: "/usr/bin/ssh-keygen",
            arguments: ["-lf", "-", "-E", "sha256"],
            standardInput: scanned.stdout
        ))
        guard fingerprint.status == 0, !fingerprint.stdout.isEmpty else { throw RemoteBackupError.hostKeyMismatch }
        let request = OpenSSHHostTrustRequest(
            host: profile.host,
            port: profile.port,
            sha256Fingerprint: String(decoding: fingerprint.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard try await confirmUnknownHost(request) else { throw RemoteBackupError.hostKeyMismatch }
        try FileManager.default.createDirectory(at: knownHostsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try scanned.stdout.write(to: knownHostsURL, options: .atomic)
    }

    /// Hostnames, usernames, and ports reach OpenSSH argv directly. An
    /// argument array prevents shell interpolation but not option injection,
    /// so anything that could parse as an option is rejected here, before
    /// any command is built. Stored profiles predate this check, hence
    /// validation at use time rather than only in the destination editor.
    nonisolated static func validatedHost(_ host: String) throws -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 255, !trimmed.hasPrefix("-") else {
            throw RemoteBackupError.invalidDestination
        }
        // DNS names, IPv4, IPv6 (with optional %zone), and ssh_config aliases.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_:%")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RemoteBackupError.invalidDestination
        }
        return trimmed
    }

    nonisolated static func validatedUsername(_ username: String) throws -> String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64, !trimmed.hasPrefix("-") else {
            throw RemoteBackupError.invalidDestination
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RemoteBackupError.invalidDestination
        }
        return trimmed
    }

    nonisolated static func validatedPortNumber(_ port: Int) throws -> Int {
        guard (1...65_535).contains(port) else {
            throw RemoteBackupError.invalidDestination
        }
        return port
    }

    private func ssh(command: String) throws -> OpenSSHCommand {
        // "--" is a verified option boundary on the system ssh (see ssh(1));
        // validation above is the primary guard, "--" the backstop.
        OpenSSHCommand(executable: "/usr/bin/ssh", arguments: try commonArguments(portFlag: "-p") + ["-T", "--", Self.validatedHost(profile.host), command], standardInput: nil)
    }

    private func sftp(batch: String) throws -> OpenSSHCommand {
        // The user@host destination can never start with "-" after validation.
        let destination = "\(try Self.validatedUsername(profile.username))@\(try Self.validatedHost(profile.host))"
        return OpenSSHCommand(executable: "/usr/bin/sftp", arguments: try sftpArguments() + ["-b", "-", destination], standardInput: Data(batch.utf8))
    }

    private func commonArguments(portFlag: String) throws -> [String] {
        Self.fixedArguments(knownHostsURL: knownHostsURL, port: try Self.validatedPortNumber(profile.port), username: try Self.validatedUsername(profile.username), portFlag: portFlag)
    }

    private func sftpArguments() throws -> [String] {
        Self.fixedArguments(knownHostsURL: knownHostsURL, port: try Self.validatedPortNumber(profile.port), username: nil, portFlag: "-P")
    }

    /// Profile roots are deliberately relative to the authenticated SFTP
    /// account. Never prepend `/`, which would escape that configured root.
    private func remote(_ path: RemoteRelativePath) throws -> String {
        try profile.root.appending(path: path).description
    }
    private func shellQuote(_ value: String) -> String { Self.shellQuote(value) }
    private func sftpQuote(_ value: String) throws -> String { try Self.sftpQuote(value) }

    private static let helperSource: String? = {
        let url = Bundle.main.url(forResource: "SFTPRemoteHelper", withExtension: "py")
            ?? Bundle.main.url(forResource: "SFTPRemoteHelper", withExtension: "py", subdirectory: "Resources")
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private func helperCommand(action: String, paths: [RemoteRelativePath] = []) throws -> OpenSSHCommand {
        guard let source = Self.helperSource else { throw RemoteBackupError.providerUnavailable }
        let encodedPaths = try paths.map { path -> String in
            let components = try profile.root.appending(path: path).components
            let jsonData = try JSONSerialization.data(withJSONObject: components)
            guard let json = String(data: jsonData, encoding: .utf8) else {
                throw RemoteBackupError.unsafePath
            }
            return Self.shellQuote(json)
        }
        let command = (["python3", "-c", Self.shellQuote(source), Self.shellQuote(action)] + encodedPaths)
            .joined(separator: " ")
        return try ssh(command: command)
    }

    private func classifyHelper(
        _ result: OpenSSHCommandResult,
        claim: Bool = false,
        promotion: Bool = false
    ) -> RemoteBackupError {
        switch result.status {
        case 42:
            return promotion ? .conflict : claim ? .temporaryClaimFailed : .providerUnavailable
        case 43:
            return .unsafePath
        case 44, 127:
            return .streamUploadUnavailable
        case 46:
            return .remoteStorageFull
        case 47:
            return .permissionDenied
        case 48:
            return .capabilityUnavailable(.noReplacePromotion)
        case 45:
            return .providerUnavailable
        case 255:
            return classify(result)
        default:
            return .providerUnavailable
        }
    }

    private func classify(_ result: OpenSSHCommandResult) -> RemoteBackupError {
        Self.classify(stderr: result.stderr)
    }

    nonisolated static func classify(stderr: Data) -> RemoteBackupError {
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        if text.contains("host key verification") || text.contains("no matching host key") { return .hostKeyMismatch }
        if text.contains("no space left on device") || text.contains("disk quota exceeded") { return .remoteStorageFull }
        if text.contains("permission denied") { return .permissionDenied }
        if text.contains("authentication") { return .authenticationFailed }
        return .networkUnavailable
    }

    static func fixedArguments(knownHostsURL: URL, port: Int, username: String?, portFlag: String) -> [String] {
        var arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(knownHostsURL.path)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "PreferredAuthentications=publickey", "-o", "PubkeyAuthentication=yes", portFlag, "\(port)"]
        if let username { arguments += ["-l", username] }
        return arguments
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    nonisolated static func sftpQuote(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteBackupError.unsafePath
        }
        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    nonisolated static func relativeRemotePath(root: RemoteRelativePath, path: RemoteRelativePath) throws -> String {
        try root.appending(path: path).description
    }

    private nonisolated static func validatePinnedInput(
        fileDescriptor: Int32,
        identity: OpenSSHInputIdentity,
        expectedSHA256: String
    ) throws {
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var offset: Int64 = 0
        while offset < identity.byteCount {
            try Task.checkCancellation()
            let requested = Int(min(Int64(bufferSize), identity.byteCount - offset))
            let count = Darwin.pread(fileDescriptor, buffer, requested, off_t(offset))
            if count < 0 {
                if errno == EINTR { continue }
                throw RemoteBackupError.localArtifactNotVerified
            }
            guard count > 0 else { throw RemoteBackupError.localArtifactNotVerified }
            autoreleasepool {
                hasher.update(data: Data(bytes: buffer, count: count))
            }
            offset += Int64(count)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame,
              try OpenSSHInputIdentity(fileDescriptor: fileDescriptor) == identity else {
            throw RemoteBackupError.localArtifactNotVerified
        }
    }

    /// Keep command responses and error markers, but never let an unexpected
    /// remote shell flood grow the app's memory. Continue draining to EOF so
    /// the child can exit and be reaped even after the capture limit is hit.
    private nonisolated static func captureBoundedOutput(_ handle: FileHandle) -> Data {
        let limit = 1024 * 1024
        var captured = Data()
        while true {
            let reachedEnd = autoreleasepool { () -> Bool in
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { return true }
                if captured.count < limit {
                    captured.append(chunk.prefix(limit - captured.count))
                }
                return false
            }
            if reachedEnd { return captured }
        }
    }

    // Kept internal so the real subprocess lifetime can be exercised by tests.
    static func runProcess(_ command: OpenSSHCommand) async throws -> OpenSSHCommandResult {
        guard command.standardInput == nil || command.standardInputFile == nil else {
            throw RemoteBackupError.providerUnavailable
        }
        guard command.expectedInputSHA256 == nil || command.standardInputFile != nil else {
            throw RemoteBackupError.providerUnavailable
        }
        try Task.checkCancellation()
        let openedInput: (handle: FileHandle, identity: OpenSSHInputIdentity)? = try command.standardInputFile.map { url in
            // The queue already hashed this local artifact. Reject a replaced
            // leaf rather than following it between that check and SSH launch.
            let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                let code = errno
                if [ELOOP, ENOENT, ENOTDIR, EACCES, EPERM].contains(code) {
                    throw RemoteBackupError.localArtifactNotVerified
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            do {
                let identity = try OpenSSHInputIdentity(fileDescriptor: fd)
                return (FileHandle(fileDescriptor: fd, closeOnDealloc: true), identity)
            } catch {
                _ = Darwin.close(fd)
                throw error
            }
        }
        defer { try? openedInput?.handle.close() }
        if let openedInput, let expectedSHA256 = command.expectedInputSHA256 {
            try Self.validatePinnedInput(
                fileDescriptor: openedInput.handle.fileDescriptor,
                identity: openedInput.identity,
                expectedSHA256: expectedSHA256
            )
        }
        let fileOutput: FileHandle? = try command.standardOutputFile.map { url in
            let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        defer { try? fileOutput?.close() }

        let lifetime = OpenSSHProcessLifetime()
        let result: OpenSSHCommandResult = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OpenSSHCommandResult, Error>) in
                let output = Pipe(); let stderrPipe = Pipe(); let input = Pipe()
                let collected = OpenSSHProcessOutput()
                let drains = DispatchGroup()
                drains.enter()
                drains.enter()
                drains.enter()
                do {
                    // A fast-exiting child can close stdin while a batch is
                    // being written. Return EPIPE instead of raising SIGPIPE.
                    guard Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    let pid = try lifetime.launch(command, input: input, inputFileFD: openedInput?.handle.fileDescriptor, output: output, error: stderrPipe)
                    // The child keeps only its duplicated standard streams.
                    input.fileHandleForReading.closeFile()
                    output.fileHandleForWriting.closeFile()
                    stderrPipe.fileHandleForWriting.closeFile()

                    DispatchQueue.global().async {
                        if let fileOutput {
                            var writeFailure: Error?
                            while true {
                                let reachedEnd = autoreleasepool { () -> Bool in
                                    let chunk = output.fileHandleForReading.readData(ofLength: 1024 * 1024)
                                    if chunk.isEmpty { return true }
                                    if writeFailure == nil {
                                        do { try fileOutput.write(contentsOf: chunk) }
                                        catch { writeFailure = error }
                                    }
                                    return false
                                }
                                if reachedEnd { break }
                            }
                            if let writeFailure { collected.setDrainError(writeFailure) }
                        } else {
                            collected.setStdout(Self.captureBoundedOutput(output.fileHandleForReading))
                        }
                        output.fileHandleForReading.closeFile()
                        drains.leave()
                    }
                    DispatchQueue.global().async {
                        collected.setStderr(Self.captureBoundedOutput(stderrPipe.fileHandleForReading))
                        stderrPipe.fileHandleForReading.closeFile()
                        drains.leave()
                    }
                    // Reap only after all streams close. While the leader is
                    // unreaped, its PID cannot be reused by an unrelated job.
                    drains.notify(queue: .global()) {
                        var exitInfo = siginfo_t()
                        var observed: Int32
                        repeat {
                            observed = Darwin.waitid(P_PID, id_t(pid), &exitInfo, WEXITED | WNOWAIT)
                        } while observed == -1 && errno == EINTR
                        let wasCancelled = lifetime.complete()
                        var rawStatus: Int32 = 0
                        var waited: pid_t
                        repeat { waited = Darwin.waitpid(pid, &rawStatus, 0) }
                            while waited == -1 && errno == EINTR
                        let status = observed == 0 && exitInfo.si_pid == pid && waited == pid
                            ? Self.exitStatus(rawStatus) : nil
                        if wasCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else if let status {
                            do { continuation.resume(returning: try collected.result(status: status)) }
                            catch { continuation.resume(throwing: error) }
                        } else {
                            continuation.resume(throwing: RemoteBackupError.providerUnavailable)
                        }
                    }
                    if openedInput == nil, let data = command.standardInput {
                        do { try input.fileHandleForWriting.write(contentsOf: data) }
                        catch { collected.markInputWriteFailure() }
                    }
                    input.fileHandleForWriting.closeFile()
                    drains.leave()
                } catch {
                    input.fileHandleForReading.closeFile()
                    input.fileHandleForWriting.closeFile()
                    output.fileHandleForReading.closeFile()
                    output.fileHandleForWriting.closeFile()
                    stderrPipe.fileHandleForReading.closeFile()
                    stderrPipe.fileHandleForWriting.closeFile()
                    let wasCancelled = lifetime.complete()
                    drains.leave()
                    drains.leave()
                    drains.leave()
                    continuation.resume(throwing: wasCancelled ? CancellationError() : error)
                }
            }
        }, onCancel: {
            lifetime.cancel()
        })
        try Task.checkCancellation()
        if let openedInput,
           try OpenSSHInputIdentity(fileDescriptor: openedInput.handle.fileDescriptor) != openedInput.identity {
            throw RemoteBackupError.localArtifactNotVerified
        }
        return result
    }

    private nonisolated static func exitStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        return signal == 0 ? (rawStatus >> 8) & 0xff : 128 + signal
    }
}
#endif
