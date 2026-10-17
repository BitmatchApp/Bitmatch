import Darwin
import Foundation
import Testing
import BitMatchEngine
@testable import BitMatch

#if os(macOS)
struct SFTPRemoteBackupProcessTests {
    @Test func completedCommandStillReturnsStatusAndBothOutputStreams() async throws {
        let result = try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf output; printf warning >&2; exit 7"],
            standardInput: nil
        ))

        #expect(result.status == 7)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "output")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "warning")
    }

    @Test func completedCommandReceivesBatchInput() async throws {
        let batch = Data("put one\nput two\n".utf8)
        let result = try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
            executable: "/bin/cat", arguments: [], standardInput: batch
        ))

        #expect(result.status == 0)
        #expect(result.stdout == batch)
        #expect(result.stderr.isEmpty)
    }

    @Test func verboseChildOutputIsDrainedButCaptureStaysBounded() async throws {
        let result = try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "/usr/bin/head -c 4194304 /dev/zero; /usr/bin/head -c 4194304 /dev/zero >&2"],
            standardInput: nil
        ))

        #expect(result.status == 0)
        #expect(result.stdout.count == 1024 * 1024)
        #expect(result.stderr.count == 1024 * 1024)
    }

    @Test func streamsFileInputToExclusiveOutputWithoutCapturingFootage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let readback = directory.appendingPathComponent("readback")
        let chunk = Data(repeating: 0x8f, count: 1024 * 1024)
        try chunk.write(to: source)
        let sourceHandle = try FileHandle(forWritingTo: source)
        try sourceHandle.seekToEnd()
        for _ in 0..<15 { try sourceHandle.write(contentsOf: chunk) }
        try sourceHandle.close()

        let result = try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
            executable: "/bin/cat", arguments: [], standardInput: nil,
            standardInputFile: source, standardOutputFile: readback
        ))

        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: readback.path)[.size] as? Int == 16 * 1024 * 1024)
        #expect(try Data(contentsOf: readback) == Data(contentsOf: source))
    }

    @Test func exclusiveOutputRejectsExistingSymlinkWithoutChangingTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let output = directory.appendingPathComponent("output")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)

        await #expect(throws: Error.self) {
            try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
                executable: "/bin/sh", arguments: ["-c", "printf replaced"],
                standardInput: nil, standardOutputFile: output
            ))
        }
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
    }

    @Test func fileInputRejectsSymlinkAndFIFOBeforeStartingChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("source-link")
        let fifo = directory.appendingPathComponent("source-fifo")
        let marker = directory.appendingPathComponent("started")
        try Data("private bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try #require(Darwin.mkfifo(fifo.path, 0o600) == 0)

        await #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
                executable: "/bin/sh", arguments: ["-c", "printf started > \"$1\"", "sh", marker.path],
                standardInput: nil, standardInputFile: link
            ))
        }
        await #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
                executable: "/bin/sh", arguments: ["-c", "printf started > \"$1\"", "sh", marker.path],
                standardInput: nil, standardInputFile: fifo
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: target) == Data("private bytes".utf8))
    }

    @Test func sameSizeLeafReplacementAfterValidationCannotStartUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let old = directory.appendingPathComponent("old")
        let marker = directory.appendingPathComponent("started")
        try Data("original".utf8).write(to: source)
        let expected = try await ChecksumEngine.shared.generateChecksum(for: source, type: .sha256)
        try FileManager.default.moveItem(at: source, to: old)
        try Data("replaced".utf8).write(to: source)

        await #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
                executable: "/bin/sh", arguments: ["-c", "printf started > \"$1\"", "sh", marker.path],
                standardInput: nil, standardInputFile: source, expectedInputSHA256: expected
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func sameSizeAncestorSwapAfterValidationCannotStartUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-stream-\(UUID().uuidString)")
        let current = directory.appendingPathComponent("current")
        let other = directory.appendingPathComponent("other")
        let old = directory.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = current.appendingPathComponent("source")
        let marker = directory.appendingPathComponent("started")
        try Data("original".utf8).write(to: source)
        try Data("replaced".utf8).write(to: other.appendingPathComponent("source"))
        let expected = try await ChecksumEngine.shared.generateChecksum(for: source, type: .sha256)
        try FileManager.default.moveItem(at: current, to: old)
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: other)

        await #expect(throws: RemoteBackupError.localArtifactNotVerified) {
            try await SFTPRemoteBackupProvider.runProcess(OpenSSHCommand(
                executable: "/bin/sh", arguments: ["-c", "printf started > \"$1\"", "sh", marker.path],
                standardInput: nil, standardInputFile: source, expectedInputSHA256: expected
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func changedPinnedInputCannotReturnSuccessfulUpload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let ready = directory.appendingPathComponent("ready")
        let gate = directory.appendingPathComponent("gate")
        try Data("original".utf8).write(to: source)
        try #require(Darwin.mkfifo(gate.path, 0o600) == 0)
        let command = OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "cat >/dev/null; printf ready > \"$1\"; cat \"$2\" >/dev/null", "sh", ready.path, gate.path],
            standardInput: nil, standardInputFile: source
        )
        let task = Task { try await SFTPRemoteBackupProvider.runProcess(command) }
        guard await waitUntil(timeout: .seconds(3), { FileManager.default.fileExists(atPath: ready.path) }) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The child did not consume the pinned input")
            return
        }
        let editor = try FileHandle(forWritingTo: source)
        try editor.truncate(atOffset: 0)
        try editor.write(contentsOf: Data("changed".utf8))
        try editor.close()
        let release = try FileHandle(forWritingTo: gate)
        try release.write(contentsOf: Data("go".utf8))
        try release.close()

        await #expect(throws: RemoteBackupError.localArtifactNotVerified) { try await task.value }
    }

    @Test func cancellingFileInputCommandReapsChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let output = directory.appendingPathComponent("output")
        let marker = directory.appendingPathComponent("pid")
        try Data(repeating: 0x77, count: 1024 * 1024).write(to: source)
        let command = OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec /bin/sleep 8", "sh", marker.path],
            standardInput: nil, standardInputFile: source, standardOutputFile: output
        )
        let task = Task { try await SFTPRemoteBackupProvider.runProcess(command) }
        guard await waitUntil(timeout: .seconds(3), { FileManager.default.fileExists(atPath: marker.path) }) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The file-stream child never started")
            return
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let started = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func earlyExitWhileWritingInputCannotReportSuccess() async throws {
        let command = OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "exec 0<&-; exit 0"],
            standardInput: Data(repeating: 0x61, count: 4 * 1024 * 1024)
        )

        await #expect(throws: RemoteBackupError.self) {
            try await SFTPRemoteBackupProvider.runProcess(command)
        }
    }

    @Test func cancellingInFlightCommandStopsAndReapsChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf '%s\\n' \"$$\" > \"$1\"; exec /bin/sleep 5", "sh", marker.path],
            standardInput: nil
        )
        let task = Task { try await SFTPRemoteBackupProvider.runProcess(command) }
        guard await waitUntil(timeout: .seconds(3), { FileManager.default.fileExists(atPath: marker.path) }) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The child process never started")
            return
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let started = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func alreadyCancelledCommandNeverStartsAChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "printf started > \"$1\"", "sh", marker.path],
            standardInput: nil
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SFTPRemoteBackupProvider.runProcess(command)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func cancellationEscalatesWhenChildIgnoresTerminate() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; printf '%s\\n' \"$$\" > \"$1\"; exec /bin/sleep 8", "sh", marker.path],
            standardInput: nil
        )
        let task = Task { try await SFTPRemoteBackupProvider.runProcess(command) }
        guard await waitUntil(timeout: .seconds(3), { FileManager.default.fileExists(atPath: marker.path) }) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The TERM-ignoring child process never started")
            return
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let started = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func cancellationStillStopsChildThatClosedBothOutputPipes() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-no-output-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let command = OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", "exec 1>&- 2>&-; printf '%s\\n' \"$$\" > \"$1\"; exec /bin/sleep 8", "sh", marker.path],
            standardInput: nil
        )
        let task = Task { try await SFTPRemoteBackupProvider.runProcess(command) }
        guard await waitUntil(timeout: .seconds(3), { FileManager.default.fileExists(atPath: marker.path) }) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The output-closing child never started")
            return
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let started = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func cancellationStopsPipeOwningDescendantAfterDirectChildExits() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-family-\(UUID().uuidString)")
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent("bitmatch-sftp-ready-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: ready)
        }
        let script = #"""
        /bin/sh -c 'trap "" TERM; printf ready > "$1"; exec /bin/sleep 8' sh "$2" &
        child=$!
        printf '%s\n%s\n' "$$" "$child" > "$1"
        exit 0
        """#
        let command = OpenSSHCommand(
            executable: "/bin/sh",
            arguments: ["-c", script, "sh", marker.path, ready.path],
            standardInput: nil
        )
        let task = Task { try await SFTPRemoteBackupProvider.runProcess(command) }
        guard await waitUntil(timeout: .seconds(3), {
            FileManager.default.fileExists(atPath: marker.path) && FileManager.default.fileExists(atPath: ready.path)
        }) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The pipe-owning descendant never started")
            return
        }
        let pids = try String(contentsOf: marker, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        #expect(pids.count == 2)
        let parentPID = try #require(pids.first)
        let childPID = try #require(pids.last)
        guard await waitUntil(timeout: .seconds(3), {
            var exitInfo = siginfo_t()
            return Darwin.waitid(P_PID, id_t(parentPID), &exitInfo,
                                 WEXITED | WNOWAIT | WNOHANG) == 0
                && exitInfo.si_pid == parentPID
        }) else {
            task.cancel()
            _ = try? await task.value
            Issue.record("The direct child did not exit before cancellation")
            return
        }
        let started = ContinuousClock.now
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await waitUntil(timeout: .seconds(2), {
            Darwin.kill(childPID, 0) == -1 && errno == ESRCH
        }))
    }
}
#endif
