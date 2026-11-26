# BitMatch Remote: the iPad and iPhone as the Mac's control surface — design

Date: 2026-11-26
Status: approved by Mike on 2026-11-26 after review by a builder reviewer and by Codex, their findings folded in below. Supersedes the "read-only first" slice in `docs/REMOTE_PROTOCOL_CONTRACT.md`; everything else in that contract (pairing, session freshness, privacy, command idempotency, validation gates) still applies and is referenced here rather than repeated.

Baseline: `main` after 0.2.14 (the HDD-aware worker settings are part of the settings surface from the start).

## Intent and why

On set, the Mac that runs BitMatch is usually busy being something else: the DIT cart's Mac Studio running Resolve and camera monitoring, or a producer's MacBook with email and the shoot spreadsheet open. BitMatch should run there in the background with its offload settings already set, and the person doing offloads should drive it from an iPad standing beside the screen (or an iPhone in their hand): see the card the Mac detected, pick backups, start, pause, cancel, watch progress, read the verdict, eject, and change settings, without anyone on the Mac switching windows.

The iPad also stays a complete standalone offloader (hub, card reader, drives, or onto its own storage). Remote is a mode of the same app, not a different app.

Mike's words: "the MacBook is never taken over by having to open BitMatch. It's just the iPad controlling the transfer on the computer." And the DIT may want anything from "just hit Start and Pause" to "manage it fully on the iPad". Both are the same product; the short path is a subset of the long one.

## Goals

- In remote mode the iPad and iPhone can do everything the Mac's own Copy & Verify Setup, Progress, Outcome, Transfers (History and queue) and transfer-related Settings screens can do for a Mac-hosted transfer, choosing from what the Mac knows: detected cards, mounted volumes, saved backups, presets, projects and recipes.
- One tap from "card appeared on the Mac" to Start when the Mac's presets are what the DIT wants.
- The Mac stays the only authority for storage, queue, transfers, verification, journal, reports and verdicts. The iPad never computes a verdict, never caches one as current, and never shows "safe to erase" from stale data.
- Connecting is "plug it in or sit it next to the Mac and it connects": peer-to-peer Wi‑Fi between the devices needs no router, no network, no account and no internet. The cable charges the iPad. Where peer-to-peer is unavailable the app says so and offers infrastructure Wi‑Fi.
- Works on the same Wi‑Fi network from anywhere in range as the secondary case.
- Mac hosting stays free, open source and offline. No relay, no daemon, no helper, no accounts.
- The Mac's own window keeps working at the same time; both are views of one coordinator, and the Mac's local actions obey the same admission rules as remote ones.

## Non-goals and anti-goals

- No screen mirroring, no UI-click simulation, no accessibility-driven control (rejected approach C).
- No arbitrary filesystem browser on the iPad. Choices come from host-provided lists.
- No app-data transport over the USB cable. iOS exposes no public device-to-Mac link for this; the cable is power. A future public API becomes an additional transport behind the same session protocol.
- Compare (Check) and Master Report stay local to each device in this release: the iPad runs them on its own storage as today; remote mode does not drive the Mac's Compare. (My call: Compare takes two arbitrary folders, which the no-browser rule cannot serve well; revisit after Remote ships.)
- No remote use of the iPad's own storage as a backup for a Mac-hosted transfer.
- No internet relay, cloud account, Apple push notifications, or Mac background daemon. The host lives inside the running BitMatch app (the menu bar companion already keeps it alive with the window closed).
- A command the Mac cannot verify at execution time is refused, never guessed. A lost reply never causes a second Start, Cancel or Eject. A result the Mac cannot prove after a crash is reported as unknown, never re-run.
- Remote never weakens the sandbox: the Mac only touches volumes the Mac user has granted; the iPad cannot grant access the Mac lacks. When a grant is needed, the iPad says "grant on the Mac".
- Remote does not add prompts the Mac does not already have. Local confirmations (cancel) stay local on each device; only state the coordinator already owns is remoted.

## Constraints

- Mac and iPad already share `SharedAppCoordinator`, the readiness rules, `DestinationSelectionPolicy`, `BackupTargetPolicy`, the presentation models and the unified screens (THESIS P5). Remote must reuse them; no second engine, no second rule set. 41 shared views observe the concrete coordinator class, which is non-final; the engine package cannot see `Shared` types, so protocol messages are mirrored DTOs.
- The Mac app is sandboxed with `network.client` only; hosting needs `com.apple.security.network.server`. Both targets declare `NSLocalNetworkUsageDescription` and `NSBonjourServices` for `_bitmatch._tcp` (a declared specific service needs no multicast entitlement). Local Network privacy applies to macOS 15 and later as well as iOS; denied, undetermined and later-revoked permission each have a visible state and recovery path.
- Transport is Apple's Network framework. `includePeerToPeer` is set on browser, listener and connection; the Bonjour endpoint is kept, never a resolved IP. Peer-to-peer is a path the system may or may not choose; the app shows which path it is on and falls back to infrastructure Wi‑Fi. iOS suspends the app in the background; a suspended iPad is a stale view, never a stuck transfer. Keeping the screen awake is a foreground convenience only.
- Pairing and sessions follow `REMOTE_PROTOCOL_CONTRACT.md`, with the concrete mechanism in "Connection and pairing" below.
- File-system work on the Mac is already routed through `DriveAccessWorker` and `BoundedBlockingExecutor`; host handlers call the same coordinator intents and inherit those protections.
- Local validation only (CI off): engine suite, Mac suite, Mac build, iPad build, plus a real two-device walkthrough before release. Simulator cannot prove peer-to-peer or background behaviour.

## Approaches considered

1. **Remote the coordinator (chosen).** The iPad keeps its screens; in remote mode their state is a host snapshot plus revisioned updates of the coordinator's published state, and each user action becomes a command the Mac validates and runs through the existing intents. Full management and one-tap Start are one code path. Cost: a presentation and intent boundary has to be carved out of a 3,800-line coordinator, and the command set defined precisely; the first slice is engine-side with nothing on screen.
2. **A purpose-built remote UI.** New small screens for card, Start/Pause/Cancel/Eject, progress, verdict, a few settings. Fastest to demo, but a second UI to keep in step with the Mac's rules, and "manage it fully" later means building 1 anyway. Rejected.
3. **Drive the Mac's window** by mirroring or simulated clicks. Rejected: forbidden by the contract, collapses when someone else uses the Mac, and could never be trusted for a safe-to-erase verdict.

Mike chose 1.

## Design

### Shape

- **`RemoteHost`** (Mac): advertises, pairs, authenticates sessions, publishes snapshots and updates from the live `SharedAppCoordinator`, and executes commands by calling the coordinator's existing intents through an admission layer. Enabled in Settings → Remote; off by default.
- **`RemoteClient`** (iPad/iPhone): discovers hosts, pairs, keeps one session, holds the latest snapshot and applies updates, sends commands with request IDs and waits for results.
- **`RemoteCoordinatorView`**: an object the shared screens bind to in remote mode in place of the local coordinator, exposing the same observed surface, fed from the snapshot, with the same intent methods, which become commands. Screens change only wording (connection freshness, "on <Mac name>") and intent routing. Remote screens cannot reach local services, derive a verdict, or write local settings; the type system enforces this by giving the view only the remote surface.

The protocol lives in the engine package (`Packages/BitMatchEngine/Sources/BitMatchEngine/Remote/`) as versioned `Codable` messages so both apps compile the same definitions and tests drive them without a network.

### Slice 0: the boundary inventory (from the builder and Codex reviews)

Before any protocol code: a written inventory of (a) every coordinator property and nested observable the shared Copy & Verify, Progress, Outcome, Transfers and Settings screens observe, and (b) every user action on those screens mapped to the coordinator intent it calls, its preconditions, its result, and whether Remote supports it (with the wording shown when it does not). Mode switching, queue reorder, review/skip/stop, retry, remove, History paging and export requests all appear in it. The inventory is the snapshot schema and the command enum; the `RemoteCoordinatorView` type is designed from it. Checked in under `docs/superpowers/specs/` as an appendix to this design.

### What the iPad can choose

The host sends lists, never paths to browse:

- **Cards:** sources the Mac has detected (its camera-card detection) and mounted removable volumes, each as an opaque host ID bound to a **media incarnation** (the Mac's durable volume identity plus mount generation), with a privacy-safe name, capacity, detected camera, and whether the Mac has access.
- **Backups:** saved destinations, mounted external volumes, and startup-disk folders the Mac user has already granted, as opaque IDs with name, free space, and the Mac's `BackupTargetPolicy` verdict.
- **Presets, folder recipes, projects, camera-label settings, report settings, AppleDouble preference, verification mode, worker settings, queue-new-cards-automatically, auto-eject-when-safe:** the same values the Mac holds, editable from the iPad through commands; the Mac persists them. Notifications, sounds and update settings stay Mac-local (my call: they describe the Mac, not the transfer).
- **Projects with an SFTP remote profile:** startable from the iPad; the upload queue is shown read-only (state, progress, failures) and controlled only on the Mac in this release. Decided by Mike 2026-11-26.

### Commands and admission

One `RemoteCommand` enum, each case carrying `clientID`, `requestID`, a content hash, the host `sessionID`, and the relevant **resource revision** (selection, queue, operation, or settings), not a single global revision, so progress traffic never invalidates a Start. First release:

- `selectSource(cardID)`, `setDestinations([backupID])`, `setVerificationMode`, `setSettings(patch)`
- `start(selectionRevision)`, `enqueue`, `startQueue`, `pause(operationID)`, `resume(operationID)`, `cancel(operationID)`, `retry(recordID)`, `removeQueued(recordID)`, `reorderQueue`
- `eject(cardID, mediaIncarnation)`: refused unless the host's current safe-to-erase verdict for that record and that exact media holds at execution time; a second eject while one is pending answers "already in progress", never success.
- `answerAppleDoubleReview(reviewID, paths)`: the one operator review the coordinator already owns as state. Cancel confirmation stays a local iPad dialog before `cancel` is sent. Reauthorisation is Mac-only and shown as "grant on the Mac".
- `requestExport(recordID, format)`, `pageHistory(cursor)`.

**Admission** (Codex blocker 1 and 3): the host keeps a durable admission store keyed by client and request ID with states `pending → done(result) | unknown`. A command is admitted before any side effect, its ID reserved so a duplicate arriving mid-flight sees `pending`. Reservations are taken in one main-actor turn and revalidated after every `await` inside the intent, exactly as the existing eject (claim record, await, recheck journal) and cancel (target ID checked in one turn) already do; `start`, `pause`, `resume` carry the expected selection or operation identity for the same reason. Local Mac UI actions go through the same admission so remote and local cannot interleave inside an intent. After a crash, pending admissions are reconciled against the transfer journal and mounted media; when the outcome cannot be proved the result is `unknown` and the iPad shows "Check the Mac", never a retry. The store survives reconnect and host restart for the session's lifetime plus 24 hours; an ID reused with different content is rejected.

### Snapshot, updates and the safety claim

Two ordered streams per session: a **reliable state stream** (selection, readiness wording, queue rows, outcome, prompts, settings, host identity, operator-needed reasons) with a base revision and atomic snapshot installation, and a **progress stream** of replaceable coalesced samples with the host's time, dropped first under pressure and never carrying state. A revision gap, overflow, reconnect, host restart or protocol mismatch forces a fresh snapshot.

The **safety claim** ("safe to erase", "verified", eject enabled) is a separate object in the state stream, bound to host identity, session epoch, transfer record and media incarnation, and it has a **liveness lease**: it is shown as current only while heartbeats arrive within the lease and the claim's revision is the latest. On lease expiry, disconnect, backgrounding, revision gap or media change, the claim is dropped from the current view and the iPad shows connection freshness instead; on foreground it stays hidden until a fresh snapshot installs. Past results remain visible in Transfers, marked as history, never as the current card's verdict. Heartbeats alone do not renew a claim; the claim's own revision must be current.

History on the iPad in remote mode is paged from the host. Exports (PDF, CSV, JSON) are rendered on the Mac and sent on request; the iPad offers the share sheet. Evidence always comes from the authority.

### Connection and pairing

- **Discovery:** Bonjour `_bitmatch._tcp`, advertising only an operator-chosen station alias, only while Remote is enabled.
- **Pairing (my call, replacing "public identity" wording):** Settings → Remote → "Pair a device" shows a six-digit code and QR valid for two minutes, single use, five attempts. Both devices run a CryptoKit P‑256 key agreement over the connection and confirm it with an HMAC of both public keys, the code and both device names, verified on both sides before anything else is sent; the result is a per-client pre-shared secret derived with HKDF. Each side stores it in its Keychain under the other's client ID and shows the two device names for confirmation. This is platform cryptography (CryptoKit, Network framework) with no custom cipher; it is a short-code-authenticated exchange and is listed for security review before release. Minting X.509 identities on iOS has no public API and TLS client certificates would need a hand-rolled encoder or a new dependency, which is why the identity is a per-client secret rather than a certificate.
- **Session:** TLS-PSK on the Network framework connection (`sec_protocol_options_add_pre_shared_key`), the PSK identity being the client ID, so both sides authenticate each other with the pairing-derived secret. One active session per client; several clients at once are fine. Revocation on the Mac deletes the secret, closes that client's connection at once and drops its queued commands as `rejected`. Host identity change invalidates all pairings.
- **Lifecycle:** the iPad keeps the screen awake while connected and charging. Backgrounding, lock, termination, Mac sleep, Mac quit and network changes mark the view stale and expire the safety claim; foreground reconnects and resnapshots. The transfer continues only while the Mac does.

### Where remote mode lives on the iPad

A "Remote" entry alongside Copy & Verify, Check and Master Report. Entering it discovers hosts; choosing a paired host swaps the object the Copy & Verify screens bind to for a `RemoteCoordinatorView`. Leaving returns to the local coordinator. A local transfer in progress is never interrupted by entering remote mode, and remote mode is unavailable while a local transfer runs.

### Mac side

Settings → Remote: enable, station alias, pairing, paired devices, revoke, current connections and their path (peer-to-peer or Wi‑Fi). The menu bar companion shows "Remote: 1 device connected". The Mac window, if open, reflects remote-driven changes immediately because it reads the same coordinator.

### Slices (delivery order, each shippable)

0. **Boundary inventory** (above): observed-state and action inventories, the `RemoteCoordinatorView` type, no behaviour change. Mac and iPad still build and pass.
1. **Protocol and host plumbing, no UI:** messages, snapshot builder, two streams, admission store with crash reconciliation, command executor through existing intents, engine and Mac tests driving host and client in one process with injected failures at every boundary (duplicate IDs, concurrent different IDs, stale revisions, crash between side effect and persist).
2. **Pairing and connection:** advertise, pair, TLS-PSK session, Keychain storage, revocation, liveness lease and freshness indicator, Local Network permission states; Mac Settings → Remote; iPad Remote entry showing the live snapshot read-only.
3. **Control with presets:** detected card → Start with the Mac's current backups and settings; Pause, Resume, Cancel, Eject with media binding; AppleDouble review answered from the iPad.
4. **Full management:** choosing cards and backups from host lists, settings patches, projects and recipes, queue management, History paging and exports.

### Validation (per contract, with additions)

Replay, expired and exhausted codes, wrong host, revoked client mid-session, two clients issuing different commands concurrently, duplicate request IDs in flight, crash between side effect and admission persist, host restart mid-transfer, iPad backgrounded mid-transfer and on verdict, Wi‑Fi dropping and returning, lease expiry with a green verdict on screen, media replaced between verdict and eject, stale-revision commands, lost replies to Start, and the Mac's own window used concurrently. Real devices: an iPad on peer-to-peer with no infrastructure network present (not merely the router off), an iPad on infrastructure Wi‑Fi, Ethernet-plus-Wi‑Fi Mac, blocked Bonjour, an iPhone, and the cart case with the Mac's window closed. Record what ran and what did not, as the project does.

## Left to the builder

- Wire encoding and framing; versioned.
- Exact snapshot field set and the `RemoteCoordinatorView` typing, from the slice 0 inventory.
- Coalescing rates, page sizes, heartbeat interval and lease length, and the stale wording shown.
- Admission store format and location (it lives beside the journal and uses the same flushed-write path).
- Test seams for driving host and client in one process.

## Decisions taken with Mike

- Projects with an SFTP remote profile: uploads stay Mac-managed; the iPad shows their state read-only. Full upload control is a later release.
