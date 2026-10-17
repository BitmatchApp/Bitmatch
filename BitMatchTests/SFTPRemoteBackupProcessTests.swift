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
