import Foundation
import BitMatchEngine

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
    private var inputWriteFailed = false

    func setStdout(_ data: Data) { lock.withLock { stdout = data } }
    func setStderr(_ data: Data) { lock.withLock { stderr = data } }
    func markInputWriteFailure() { lock.withLock { inputWriteFailed = true } }
    func didInputWriteFail() -> Bool { lock.withLock { inputWriteFailed } }
    func result(status: Int32) -> OpenSSHCommandResult {
        lock.withLock { OpenSSHCommandResult(status: status, stdout: stdout, stderr: stderr) }
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

    func launch(_ command: OpenSSHCommand, input: Pipe, output: Pipe, error: Pipe) throws -> pid_t {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            var actions: posix_spawn_file_actions_t?
            try Self.check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }

            let inputRead = input.fileHandleForReading.fileDescriptor
            let outputWrite = output.fileHandleForWriting.fileDescriptor
            let errorWrite = error.fileHandleForWriting.fileDescriptor
            try Self.check(posix_spawn_file_actions_adddup2(&actions, inputRead, STDIN_FILENO))
            try Self.check(posix_spawn_file_actions_adddup2(&actions, outputWrite, STDOUT_FILENO))
            try Self.check(posix_spawn_file_actions_adddup2(&actions, errorWrite, STDERR_FILENO))
            for descriptor in [inputRead, outputWrite, errorWrite,
                               input.fileHandleForWriting.fileDescriptor,
                               output.fileHandleForReading.fileDescriptor,
                               error.fileHandleForReading.fileDescriptor] where descriptor > STDERR_FILENO {
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
        let result = try await run(try ssh(command: "if command -v ln >/dev/null 2>&1 && command -v rm >/dev/null 2>&1; then exit 0; else printf __BITMATCH_NO_LN_RM__ >&2; exit 42; fi"))
        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self).lowercased()
            if result.status == 42, stderr.contains("__bitmatch_no_ln_rm__") {
                throw RemoteBackupError.capabilityUnavailable(.noReplacePromotion)
            }
            throw classify(result)
        }
        return RemoteProviderCapabilities(supportsNoReplacePromotion: true, supportsVerificationEvidence: true)
    }

    func inspect(path: RemoteRelativePath) async throws -> RemoteObject? {
        let remotePath = try remote(path)
        let result = try await run(try ssh(command: "if test -e \(shellQuote(remotePath)); then wc -c < \(shellQuote(remotePath)); fi"))
        guard result.status == 0 else { throw classify(result) }
        let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        guard let count = Int64(output), count >= 0 else { throw RemoteBackupError.providerUnavailable }
        return RemoteObject(byteCount: count)
    }

    func ensureDirectory(_ path: RemoteRelativePath) async throws {
        let result = try await run(try ssh(command: "mkdir -p \(shellQuote(try remote(path)))"))
        guard result.status == 0 else { throw classify(result) }
    }

    func discardTemporary(_ path: RemoteRelativePath) async throws {
        guard let basename = path.components.last,
              basename.hasPrefix(".bitmatch-upload-"),
              UUID(uuidString: String(basename.dropFirst(".bitmatch-upload-".count))) != nil
        else {
            throw RemoteBackupError.unsafePath
        }
        let result = try await run(try ssh(command: "rm -f \(shellQuote(try remote(path)))"))
        guard result.status == 0 else { throw classify(result) }
    }

    func upload(local: URL, toTemporary path: RemoteRelativePath, fromOffset: Int64, progress: @Sendable (Int64) async -> Void) async throws {
        guard fromOffset >= 0 else { throw RemoteBackupError.resumeOffsetMismatch(local: fromOffset, remote: 0) }
        let remoteObject = try await inspect(path: path)
        guard (remoteObject?.byteCount ?? 0) == fromOffset else {
            throw RemoteBackupError.resumeOffsetMismatch(local: fromOffset, remote: remoteObject?.byteCount ?? 0)
        }
        let batch = "put -a \(try sftpQuote(local.path)) \(try sftpQuote(try remote(path)))\n"
        let result = try await run(try sftp(batch: batch))
        guard result.status == 0 else { throw classify(result) }
        let complete = try await inspect(path: path)?.byteCount ?? 0
        await progress(complete)
    }

    func promoteNoReplace(temporary: RemoteRelativePath, final: RemoteRelativePath) async throws {
        let temporaryPath = try remote(temporary)
        let finalPath = try remote(final)
        let command = "ln \(shellQuote(temporaryPath)) \(shellQuote(finalPath)) && rm \(shellQuote(temporaryPath))"
        let result = try await run(try ssh(command: command))
        guard result.status == 0 else { throw classifyPromotion(result) }
    }

    func verificationEvidence(for path: RemoteRelativePath, expectedSHA256: String) async throws -> RemoteVerificationEvidence {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = try await run(try sftp(batch: "get \(try sftpQuote(try remote(path))) \(try sftpQuote(temporary.path))\n"))
        guard result.status == 0 else { throw classify(result) }
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

    private func classify(_ result: OpenSSHCommandResult) -> RemoteBackupError {
        Self.classify(stderr: result.stderr)
    }

    nonisolated static func classify(stderr: Data) -> RemoteBackupError {
        let text = String(decoding: stderr, as: UTF8.self).lowercased()
        if text.contains("host key verification") || text.contains("no matching host key") { return .hostKeyMismatch }
        if text.contains("permission denied") { return .permissionDenied }
        if text.contains("authentication") { return .authenticationFailed }
        return .networkUnavailable
    }

    private func classifyPromotion(_ result: OpenSSHCommandResult) -> RemoteBackupError {
        Self.promotionError(stderr: result.stderr)
    }

    static func fixedArguments(knownHostsURL: URL, port: Int, username: String?, portFlag: String) -> [String] {
        var arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(knownHostsURL.path)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "PreferredAuthentications=publickey", "-o", "PubkeyAuthentication=yes", portFlag, "\(port)"]
        if let username { arguments += ["-l", username] }
        return arguments
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
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

    nonisolated static func promotionError(stderr: Data) -> RemoteBackupError {
        String(decoding: stderr, as: UTF8.self).lowercased().contains("file exists")
            ? .conflict
            : .capabilityUnavailable(.noReplacePromotion)
    }

    // Kept internal so the real subprocess lifetime can be exercised by tests.
    static func runProcess(_ command: OpenSSHCommand) async throws -> OpenSSHCommandResult {
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
                    // A fast-exiting ssh/sftp child can close stdin while a
                    // batch is being written. Return EPIPE, never SIGPIPE.
                    guard Darwin.fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    let pid = try lifetime.launch(command, input: input, output: output, error: stderrPipe)
                    // Only the child keeps the duplicated standard streams.
                    input.fileHandleForReading.closeFile()
                    output.fileHandleForWriting.closeFile()
                    stderrPipe.fileHandleForWriting.closeFile()
                    DispatchQueue.global().async {
                        collected.setStdout(output.fileHandleForReading.readDataToEndOfFile())
                        output.fileHandleForReading.closeFile()
                        drains.leave()
                    }
                    DispatchQueue.global().async {
                        collected.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        stderrPipe.fileHandleForReading.closeFile()
                        drains.leave()
                    }
                    // Do not reap the group leader until its output closes.
                    // Observe its exit without reaping, then disarm the group
                    // timer while its PID is still reserved. Only then reap.
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
                            if status == 0 && collected.didInputWriteFail() {
                                continuation.resume(throwing: RemoteBackupError.providerUnavailable)
                            } else {
                                continuation.resume(returning: collected.result(status: status))
                            }
                        } else {
                            continuation.resume(throwing: RemoteBackupError.providerUnavailable)
                        }
                    }
                    if let data = command.standardInput {
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
                    if wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: {
            lifetime.cancel()
        })
        try Task.checkCancellation()
        return result
    }

    private nonisolated static func exitStatus(_ rawStatus: Int32) -> Int32 {
        let signal = rawStatus & 0x7f
        return signal == 0 ? (rawStatus >> 8) & 0xff : 128 + signal
    }
}
#endif
