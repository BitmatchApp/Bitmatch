> **Status: Parked, first candidate for a full spec after the visual polish PRs.** Parked on 2026-10-21 after review. Not scheduled. The original proposal follows unchanged below the line.
>
> **Blockers found in review**
> - Fatal as written: a loopback-only server bound to 127.0.0.1 cannot be reached by a phone on the LAN. Needs an NWListener bound to the LAN with Bonjour discovery and the network-server entitlement.
> - Bearer token plus a one-time secret over plaintext HTTP on a shared network is not enough; pairing must establish a per-device key and the channel must be encrypted.
>
> **Worth keeping:** Read-only, Mac as sole state owner, no accounts or relay, revocable devices: all consistent with the roadmapped fourth mode. The monitor screen must reuse the shared queue row grammar (card name, state label, meta line) landing in the transfer-row PR, not invent a second one.
>
> **Un-park when:** After the visual polish PRs merge: write a full spec with the transport fixed, then plan. This is the one with real product pull (glance from across the cart on a phone).

---

# 2. Remote pairing & read-only monitoring

## Goal

Let a companion device (iPhone/iPad) watch a Mac's transfers **read-only** over the local
network, with an authenticated, revocable pairing — no accounts, no cloud relay, no
filesystem browsing or remote control in this slice.

## Scope

**In scope (slice 1 — monitoring only)**

- A loopback-only HTTP server on the Mac that serves a read-only JSON projection of the
  coordinator's state.
- Pairing: the Mac shows a one-time code / QR; the device scans it and the Mac confirms.
- A **revocable, per-device token**, distinct from any Mac-internal token.
- Bearer-token auth on every request; read-only scope.
- A device list in settings with per-device revocation.
- The server serves an authoritative snapshot and paginated history, and marks connection
  freshness (live / delayed / unknown) separately from transfer phase.

**Out of scope (later slices)**

- Remote start/pause/retry/cancel, queue management, or any write command.
- Screen sharing, filesystem browsing, shells, or cloud relays.
- Bluetooth; core transport is Wi-Fi / wired Ethernet.
- Auto eject/format, facility management, multi-host coordination.

## Where it lands

- `BitMatch/Core/Services/` (Mac only) — `RemoteHostServer`, `RemoteDeviceRegistry`,
  `RemotePairingService`.
- `Shared/Core/Models/` — the JSON payload types (snapshot, per-destination progress, history
  page) and the pure presentation the device screen draws.
- `BitMatch-iPad/` + `Platforms/iOS/` — the read-only client (`RemoteMonitorClient`) and its
  screen, using the same presentation models as the Mac.
- `Shared/Views/` — the shared monitor screen.

The Mac's `SharedAppCoordinator` remains the **sole** state owner. The server is a projection
of it, never a second engine or a duplicate of state. It reads the same `LiveProgressFeed`,
`LiveResultsFeed`, journal, and operation state the UI already observes.

## Design

### The server

Bind to `127.0.0.1` on an ephemeral port (never a fixed, well-known port; the pairing payload
carries the actual port). Every request requires `Authorization: Bearer <token>` and is
rejected with `401` otherwise. The server is read-only: it has no endpoints that mutate
anything.

Endpoints (all JSON, all authenticated):

- `GET /state` — authoritative snapshot: operation state, current phase, source presence,
  per-destination progress, overall verdict, and the connection's own freshness marker.
- `GET /queue` — the transfer queue/history rows in the same shape the local UI shows,
  paginated (`?cursor=&limit=`).
- `GET /history/<id>` — one finished attempt's evidence summary (counts, verdict, exclusions),
  without exposing raw paths by default (see privacy below).

The snapshot is **authoritative at the moment it is read**, and the client always treats it as
"as of a moment in time." A client that reconnects fetches fresh state; it never re-attaches a
cached "safe" verdict to a newly detected card.

### Pairing

Pairing establishes a persistent, revocable identity for a device. The flow:

1. **Mac opt-in.** The user opens Remote settings and chooses "Pair a device." The Mac starts
   advertising over Bonjour (a privacy-safe station alias, not the raw Mac network name) and
   generates a one-time pairing secret with a short expiry.
2. **The device scans.** The Mac shows a QR (or a short code) encoding `{ host, port, secret }`.
   The device sends the secret once, over the local network, along with a generated
   device public key / identity.
3. **Mac confirms.** The Mac shows the device's human-readable identity and asks the user to
   approve. On approval, the Mac issues a **device token** (random, 256-bit) stored alongside
   the device identity.
4. **Revocation.** The device list shows every paired device; revoke deletes the token and
   identity. A revoked device's token stops working immediately.

The pairing secret is one-time and short-lived; the device token is long-lived and revocable;
they are never the same value.

### Token & identity

```swift
// Shared/Core/Models/RemoteModels.swift
public struct RemoteDeviceIdentity: Codable, Hashable, Sendable {
    public let id: UUID
    public let alias: String          // chosen by the user, privacy-safe
    public let createdAt: Date
}

public struct RemotePairingPayload: Codable, Sendable {
    public let host: String
    public let port: UInt16
    public let secret: String          // one-time, short-lived
}
```

```swift
// BitMatch/Core/Services/RemoteDeviceRegistry.swift  (Mac only)
import CryptoKit

public final class RemoteDeviceRegistry: Sendable {
    public struct Record: Codable, Sendable {
        public let identity: RemoteDeviceIdentity
        public let tokenHash: Data     // store a hash, never the raw token
    }

    public func issueToken(for id: UUID) -> String
    public func isValidToken(_ token: String) -> Bool   // constant-time compare of the hash
    public func revoke(id: UUID)
    public func devices() -> [RemoteDeviceIdentity]
}
```

Store only a hash of the token (e.g., SHA-256) in the registry; keep the raw token only in the
device's keychain. Use a constant-time comparison when validating.

### Privacy

The server minimizes exposure by default:

- Paths are not sent in the snapshot or queue; rows carry file *counts*, sizes, and statuses.
- A "show paths" option is off by default and is a display-only setting on the device.
- The device alias, not the Mac's hostname, is what the Mac surfaces for a connected client.

## Code sketch — the monitor client

```swift
// BitMatch-iPad/Remote/RemoteMonitorClient.swift  (iOS)
public actor RemoteMonitorClient {
    public struct Config: Sendable {
        public let host: String
        public let port: UInt16
        public let token: String
    }

    public private(set) var state: RemoteSnapshot?
    public private(set) var lastUpdated: Date?

    public func refresh() async throws {
        // GET /state with Bearer token; decode RemoteSnapshot; record lastUpdated.
    }
}
```

The client is a thin reader over the same `RemoteSnapshot` the Mac server serializes. The
device screen draws `RemoteSnapshot` through a presentation model, exactly as the Mac screens
draw their own models.

## Safety & verdict semantics

- The device can never change anything. There is no write path.
- Connection freshness is separate from transfer phase: "live" vs "delayed" vs "unknown" is
  reported, and a stale 100% or a timeout never implies completion.
- Disconnect or background suspension on the device does not affect Mac work; Mac sleep/quit
  makes the device view stale (marked as such).
- A cached "safe to erase" verdict is never reattached to a new card.

## Acceptance criteria

- **Auth:** an unauthenticated request to any endpoint returns `401`; a revoked token returns
  `401` on its next request. `Plant:` accept a token whose hash is not in the registry and see
  the auth test fail.
- **Read-only:** the server exposes no mutating route. `Plant:` add a `POST /cancel` and see
  the route-audit test fail.
- **Pairing:** the one-time secret expires after its TTL; a replayed secret is rejected;
  approving a device issues a token that `isValidToken` accepts; revoking it stops acceptance.
  `Plant:` issue a second token for the same one-time secret and see the replay test fail.
- **Snapshot:** `/state` matches the coordinator's current operation state and verdict at the
  moment of the read. `Plant:` hardcode the verdict in the snapshot and see the parity test
  fail.
- **Privacy:** paths are absent from the default snapshot and queue payloads.

## Validation gates

- `bash test.sh engine-test`, `bash test.sh mac-test`, `bash test.sh ipad-build`.
- A manual check: pair a simulator device against a Mac on the same Wi-Fi, watch a small
  transfer, then revoke and confirm the device drops with `401`.
- A network edge check: disconnect the device mid-transfer and confirm the device shows
  "delayed/unknown" and never implies completion.
