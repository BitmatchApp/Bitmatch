import Darwin
import Foundation
import Testing
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
}
#endif
