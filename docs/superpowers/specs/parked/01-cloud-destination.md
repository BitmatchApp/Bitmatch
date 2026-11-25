> **Status: Parked.** Parked on 2026-10-21 after review. Not scheduled. The original proposal follows unchanged below the line.
>
> **Blockers found in review**
> - Demand-gated in docs/TODO.md: cloud only on user demand and after defining staging, exclusive publication, interruption recovery and independent readback. None of those are defined here.
> - The app is sandboxed (BitMatch/BitMatch.entitlements); shelling out to a Homebrew- or download-installed rclone is not a credible distribution story.
> - ASWebAuthenticationSession is not how rclone's OAuth config flow works.
> - Claims to never parse ad-hoc text while parsing --stats-one-line output.
>
> **Worth keeping:** The uploaded · unverified versus verified semantics are right and already exist for SFTP; reuse them when this returns.
>
> **Un-park when:** A named user asks for an off-site object-storage destination, and a staging + exclusive-publication design is written first.

---

# 1. Cloud destination (rclone-backed)

## Goal

Add an optional off-site **object-storage destination** (Google Drive, Dropbox, S3, and any
other object store) that copies already-verified files off the Mac, with resumable transfers
and a queue — without writing or maintaining any provider SDK.

## Scope

**In scope**

- A "cloud destination" alongside the existing SFTP remote backup, selectable per transfer or
  per project.
- Copying the *verified local* files to the remote store.
- A durable upload queue with resume and retry.
- A first-run setup flow that installs the transfer tool and completes provider sign-in.
- Readback verification of the remote copy, with the same "uploaded · unverified" vs
  "verified" distinction already used for SFTP.

**Out of scope**

- Making a cloud destination count toward the safe-to-erase verdict as an independent local
  backup. It is an off-site copy, not a second local drive.
- Provider-specific features (shared drives, ACLs, versioning UI). The tool's own feature set
  is the surface.
- Bidirectional sync or general-purpose cloud browsing.

## Where it lands

Follow the SFTP precedent, which already draws a clean line between the engine and a Mac-only
transport:

- `Packages/BitMatchEngine` — a transport-agnostic `CloudDestination` value type and the
  *result/verdict* semantics (so evidence and verdicts stay in the engine, platform-free).
- `Shared/Core/Services/` — `CloudUploadQueue`, `CloudUploadCoordinator` (mirroring
  `RemoteBackupQueue` / `RemoteBackupCoordinator`), and the presentation model.
- `BitMatch/Core/Services/` — the Mac-only process adapter that actually runs the transfer
  tool and parses its progress (`RcloneCloudTransport`), plus the onboarding controller.
- `Shared/Views/` — the settings pane and the outcome rows; `BitMatch/Views/` — the Mac
  sign-in/onboarding window.

## Design

### Transport choice

Do not write a per-provider HTTP/OAuth client. Shell out to the **`rclone`** CLI as the
transport. It already implements every provider's OAuth, chunked resume, retry, and progress.
BitMatch's job is to drive it safely and parse its output — not to reimplement transfer.

The process adapter is behind a protocol so the engine and tests never touch the real CLI:

```swift
// Packages/BitMatchEngine/Sources/BitMatchEngine/Cloud/CloudDestination.swift
public struct CloudDestination: Hashable, Codable, Sendable {
    public let id: UUID
    public let displayName: String
    public let remoteRoot: String      // "drive:BitMatch Offloads"
    public let provider: String        // opaque; kept only for the process adapter
}

// Engine result, platform-free. The verdict is separate from transport success.
public struct CloudUploadResult: Codable, Sendable {
    public let fileURL: URL
    public let bytesTransferred: UInt64
    public let remoteVerified: Bool    // true only after an independent readback check
}
```

```swift
// BitMatch/Core/Services/RcloneCloudTransport.swift  (Mac only)
public protocol CloudTransport: Sendable {
    func isInstalled() async throws -> Bool
    func configure(provider: String) async throws          // runs the sign-in/config flow
    func upload(_ request: CloudUploadRequest) async throws -> CloudUploadResult
    func verify(_ request: CloudVerifyRequest) async throws -> Bool
}

public struct CloudUploadRequest: Sendable {
    public let localRoot: URL
    public let files: [RelativeFile]      // verified files to upload, relative to localRoot
    public let remoteRoot: String
    public let progress: (@Sendable (CloudProgress) -> Void)?
}

public struct CloudProgress: Sendable {
    public let transferredBytes: UInt64
    public let totalBytes: UInt64?
    public let speedBytesPerSecond: Double?
}
```

The concrete `RcloneCloudTransport` builds an `rclone` invocation and decodes its machine
readable progress. It never parses ad-hoc text: it uses rclone's structured output.

### The copy

After the local transfer verifies, the coordinator enqueues each verified file for upload:

1. `rclone copy <source> <remoteRoot> --transfers 4 --checksum --stats-one-line`
   with structured stats enabled, and `--stats-log-level NOTICE` scoped so only stats are
   emitted to the parsing channel.
2. Progress is decoded from rclone's stats lines (bytes and speed) and fed to the queue's
   progress feed, never onto the coordinator's `objectWillChange`.
3. On completion, the queue records `uploaded, unverified`, then runs a separate
   **readback check** — `rclone check <source> <remoteRoot> --checksum` — against the *local*
   verified files. Only a clean check flips the row to `verified` and only if it was requested.

### The queue and resume

The queue is durable and survives an app restart or an interrupted upload:

- A `CloudUploadQueue` persists per-file state to a JSON journal (in the same
  app-support area the transfer journal uses). State per file: `pending`, `inFlight`,
  `uploaded`, `verified`, `failed(attempts, lastError)`.
- One upload runs at a time by default (bounded concurrency is a later knob, not part of this
  slice).
- Resume is **rclone's own partial-file resume** (it keeps partial objects and continues them
  with `--checksum`). BitMatch records *intent* and *completion*, not raw byte offsets. A file
  marked `inFlight` when the app quit is retried as `pending` on next launch; rclone decides
  how much to re-send, and the final `--checksum` readback is always the gate.
- A failed upload retries with capped attempts and backoff; after the cap it stays `failed`
  with a recorded error and is surfaced in History, never silently dropped.

### Verdict semantics

An upload does not change the local safe-to-erase verdict. Remote status is a separate fact:

- `Uploaded · Unverified` — the copy reached the remote but no readback passed yet.
- `Uploaded · Verified` — `rclone check --checksum` passed against the local verified source.
- `Failed` — with the recorded reason.

This matches the existing SFTP distinction and the assurance-audit wording. A cloud
destination never substitutes for a required local backup, and never re-establishes source
assurance.

## Code sketch — onboarding

Onboarding must not require a Terminal:

```swift
// BitMatch/Core/Services/CloudOnboardingController.swift (Mac only)
public final class CloudOnboardingController: ObservableObject {
    @Published public private(set) var installed: Bool = false
    @Published public private(set) var configuring: Bool = false

    public func ensureInstalled() async throws {
        // 1. `rclone version` — present, done.
        // 2. Missing: offer to install via a signed Homebrew path, or download the
        //    official static binary and place it in the app's managed tools dir.
        // 3. `rclone config` opened in an embedded terminal-free flow, or drive the
        //    provider's OAuth in an ASWebAuthenticationSession and write the config
        //    via `rclone config create` non-interactively.
    }
}
```

Use an `ASWebAuthenticationSession` for the provider OAuth callback so the user never touches
a browser profile or a terminal. Keep the resulting remote name opaque in the UI.

## Acceptance criteria

- **Engine (pure):** `CloudDestination` round-trips through Codable; `CloudUploadResult`
  carries `remoteVerified` and nothing can set it `true` except the readback gate.
- **Queue:** a `CloudUploadQueueTests` fixture uploads N files through a fake `CloudTransport`,
  kills the queue mid-flight (simulated), relaunches from the persisted journal, and completes
  with exactly one `verified` row per file after the fake's `verify` returns `true`.
- **Verdict:** with the fake transport, a clean `verify` flips `uploaded, unverified` →
  `uploaded, verified`; a failing `verify` keeps the row unverified. `Plant:` mark the row
  `verified` without a readback and see the test fail.
- **Progress:** progress arrives on the queue feed only, not on `SharedAppCoordinator`'s
  `objectWillChange`. `Plant:` publish a progress tick on the coordinator and see the feed
  isolation test fail.
- **Onboarding:** `ensureInstalled()` is a no-op when rclone is present; the configure path
  records a remote without touching the user's shell. The real CLI path is behind
  `CloudTransport` so all tests use the fake.

## Validation gates

- `bash test.sh engine-test`, `bash test.sh mac-test`, `bash test.sh ipad-build`.
- A real smoke test with a disposable Drive/Dropbox folder and throwaway data, recording the
  remote object count and a `rclone check` result — kept separate from synthetic tests.
- Confirm the safe-to-erase wording and History rows do not claim remote verification as
  local independence.
