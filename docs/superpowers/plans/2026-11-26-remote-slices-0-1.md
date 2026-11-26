# BitMatch Remote, slices 0 and 1: boundary inventory and host/client cores — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define the remote protocol and build host and client cores that drive a `SharedAppCoordinator` through idempotent, revisioned commands and publish snapshots with a leased safety claim, all proven in one process with no networking.

**Architecture:** The engine package gains `Remote/` with versioned `Codable` messages, per-resource revisions, a state applier with gap detection, a safety-claim lease, and a durable admission store. The `Shared` layer gains `RemoteSurface`, the protocol the coordinator conforms to and that the views will later bind to, plus a snapshot builder, a command executor and `RemoteCoordinatorView`. A `RemoteHostCore` and `RemoteClientCore` exchange messages through an in-memory link in tests. Pairing, TLS and UI are later plans.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing (engine and Mac test targets), Combine for coordinator observation, Foundation `Codable` JSON. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-26-bitmatch-remote-design.md` (read it first; this plan argues from it).

## Global Constraints

- Baseline `main` after 0.2.14; branch from it in a worktree.
- The engine package (`Packages/BitMatchEngine`) cannot import `Shared`; anything that needs `SharedAppCoordinator`, `ReportPrefs` or presentation types lives in `Shared/Core/Remote/` and is tested in `BitMatchTests`.
- The Mac stays sole authority: no code in this plan computes a verdict on the client side; the client only displays what a snapshot says.
- Every command is admitted before any side effect; an unknown outcome is reported as `unknown`, never retried by the host.
- The safety claim is never shown as current without a live lease and the latest claim revision.
- No new prompts: the only remoted review is `answerAppleDoubleReview`.
- Durable files use the flushed write path (F_FULLFSYNC, rename, folder flush) already in `TransferJournal`.
- Validation before merge: `./test.sh engine-test`, `./test.sh mac-test`, `./test.sh mac-build`, `./test.sh ipad-build`, one at a time.
- Commit messages follow the repository's plain-sentence style and end with the attribution lines in use this session.

## Review Focus

Inputs the spec implies but no later task's tests would exercise unless added here; each line's test is added to the task named.

1. A duplicate `requestID` arriving while the first copy is still `pending` must get `pending`, not a second execution (Task 5 and Task 8).
2. A state update whose base revision skips one must mark the applier `needsSnapshot` and leave the last installed state untouched, never half-applied (Task 3).
3. A heartbeat alone must not revive a safety claim whose revision is older than the latest state revision (Task 4).
4. An `eject` whose `mediaIncarnation` no longer matches the mounted media must be refused with `.mediaChanged`, even when the record's verdict is safe (Task 6).
5. A `RemoteCommand` encoded by protocol version 2 and decoded by version 1 must fail decoding as `.unsupportedProtocolVersion`, not as a Swift decoding error (Task 2).

---

### Task 0: Boundary inventory and `RemoteSurface`

**Files:**
- Create: `docs/superpowers/specs/2026-11-26-remote-boundary-inventory.md`
- Create: `Shared/Core/Remote/RemoteSurface.swift`
- Modify: `Shared/Core/Services/SharedAppCoordinator.swift` (add `extension SharedAppCoordinator: RemoteSurface {}` and nothing else)
- Test: `BitMatchTests/RemoteSurfaceTests.swift`

**Interfaces:**
- Produces: `protocol RemoteSurface: AnyObject, ObservableObject` with the read properties and intents the Copy & Verify, Progress, Outcome, Transfers and transfer Settings screens use. Read side (exact names, matching the coordinator): `currentMode: AppMode`, `verificationMode: VerificationMode`, `sourceURL: URL?`, `destinationURLs: [URL]`, `detectedCamera: CameraCard?`, `isOperationInProgress: Bool`, `currentOperation: FileOperation?`, `queueIsRunning: Bool`, `queueMessage: String?`, `queueSessionRecordIDs: Set<UUID>`, `queuePausedRecordID: UUID?`, `reportSettings: ReportPrefs`, `generateASCMHL: Bool`, `usesProjectWorkflow: Bool`, `transferJournal: LocalTransferJournal`, `stateService: OperationStateService`, `timingService: OperationTimingService`, `generalSettings: GeneralSettings`. Intent side: `startSetupTransfersPrepared() async throws -> UUID?`, `enqueueSelectionPrepared() async throws -> UUID`, `startQueue()`, `pauseOperation() async`, `resumeOperation() async`, `cancelOperation(ifCurrentTargetID: UUID, origin: TransferCancelOrigin) -> Bool`, `retryTransferPrepared(_: UUID, generateASCMHL: Bool?) async`, `removeQueuedTransfer(_: UUID) throws`, `ejectQueueSource(...)` with the coordinator's existing signature, `addDestination(...)` and `removeDestinationFolder(_:)` with their existing signatures, `saveVerificationMode()`. The inventory may add or drop names; the protocol must match the inventory exactly.

- [ ] **Step 1: Produce the observed-state inventory**

Run from the worktree root and save the output as the first table of the inventory document, then hand-check each line against the view:

```bash
grep -rhoE "coordinator\.[a-zA-Z_]+" Shared/Views BitMatch/Views BitMatch-iPad --include='*.swift' | sort | uniq -c | sort -rn
```

Document columns: property or intent, which screens use it, read or intent, remote-supported (yes / no with the wording shown when not).

- [ ] **Step 2: Write the failing test**

```swift
@MainActor @Test func theCoordinatorIsARemoteSurface() {
    let coordinator = SharedAppCoordinator()
    let surface: any RemoteSurface = coordinator
    #expect(surface.currentMode == .copyAndVerify)
    #expect(surface.destinationURLs.isEmpty)
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `./test.sh mac-test` filtered by Xcode's `-only-testing:BitMatchTests/RemoteSurfaceTests` (add `-only-testing` to the `mac-test` invocation locally; do not commit test.sh changes).
Expected: FAIL, "cannot find type 'RemoteSurface' in scope".

- [ ] **Step 4: Write `RemoteSurface` and the empty conformance extension**

The protocol lists exactly the inventory's "remote-supported: yes" members with the coordinator's existing signatures. `@MainActor protocol RemoteSurface: AnyObject, ObservableObject`. The extension in the coordinator file is empty: every requirement already exists.

- [ ] **Step 5: Run the test to verify it passes**

Expected: PASS. Also run `./test.sh mac-build` and `./test.sh ipad-build`: both succeed.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-11-26-remote-boundary-inventory.md Shared/Core/Remote/RemoteSurface.swift Shared/Core/Services/SharedAppCoordinator.swift BitMatchTests/RemoteSurfaceTests.swift
git commit -m "Remote slice 0: the coordinator's remote surface, inventoried and named"
```

---

### Task 1: Durable JSON file writer extracted from the journal

**Files:**
- Create: `Packages/BitMatchEngine/Sources/BitMatchEngine/File/DurableJSONFile.swift`
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/TransferJournal.swift` (`persist` and `flushToDrive` move; `persist` becomes a call into the new type; `FlushAfterPublishFailure` stays public to the module and is thrown by the new type)
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/DurableJSONFileTests.swift`

**Interfaces:**
- Produces: `enum DurableJSONFile { static func write(_ data: Data, to fileURL: URL) throws }` with the exact sequence the journal uses today (sweep `.<name>.tmp-*`, temp file, F_FULLFSYNC with the ENOTSUP/EOPNOTSUPP/ENOTTY/EINVAL/ENOSYS fallback to fsync, close, rename, folder flush), throwing `FlushAfterPublishFailure` for a failure after the rename.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func writesLeaveOnlyTheFileBehind() throws   // temp dir, write twice, contents == second data, directory has exactly one entry
@Test func aStaleTemporaryIsSweptBeforeWriting() throws   // pre-create ".x.json.tmp-abc", write, it is gone
```

- [ ] **Step 2: Run to verify they fail** (`swift test --filter DurableJSONFileTests` inside the package, with the `arch -arm64 ... --build-system native --no-parallel --disable-xctest` flags `test.sh` uses). Expected: FAIL, type not found.

- [ ] **Step 3: Move the code** from `TransferJournal.persist`/`flushToDrive` into `DurableJSONFile.write`; `persist` encodes and calls it. No behaviour change.

- [ ] **Step 4: Run the new tests plus `JournalStartupPersistenceTests`.** Expected: all PASS.

- [ ] **Step 5: Commit** `"Durable JSON writes live in one place for the journal and the admission store"`.

---

### Task 2: Protocol messages

**Files:**
- Create: `Packages/BitMatchEngine/Sources/BitMatchEngine/Remote/RemoteProtocol.swift`
- Create: `Packages/BitMatchEngine/Sources/BitMatchEngine/Remote/RemoteCommand.swift`
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/RemoteProtocolTests.swift`

**Interfaces:**
- Produces, all `Codable, Hashable, Sendable`:
  - `struct RemoteProtocolVersion { static let current = 1 }` and `enum RemoteProtocolError: Error { case unsupportedProtocolVersion(Int) }`.
  - IDs as `struct HostID`, `SessionID`, `ClientID`, `RequestID` (each wrapping a `UUID`), `struct MediaIncarnation { let volumeIdentity: String; let mountGeneration: Int }`.
  - `struct ResourceRevisions { var selection: Int; var queue: Int; var operation: Int; var settings: Int; var state: Int }`.
  - `struct RemoteCardSummary { id: String; name: String; capacityBytes: Int64?; detectedCamera: String?; hasAccess: Bool; media: MediaIncarnation }`, `struct RemoteBackupSummary { id: String; name: String; freeBytes: Int64?; policyVerdict: String }`.
  - `struct RemoteSafetyClaim { recordID: UUID; media: MediaIncarnation; isSafeToErase: Bool; wording: String; revision: Int }`.
  - `struct RemoteSnapshot { host: HostID; hostName: String; session: SessionID; takenAt: Date; revisions: ResourceRevisions; mode: String; verificationMode: VerificationMode; cards: [RemoteCardSummary]; backups: [RemoteBackupSummary]; selectedCardID: String?; selectedBackupIDs: [String]; readinessWording: String; readinessStatus: String; queue: [RemoteQueueRow]; outcome: RemoteOutcome?; safetyClaim: RemoteSafetyClaim?; appleDoubleReview: RemoteAppleDoubleReview?; settings: RemoteSettings }` with `RemoteQueueRow { recordID: UUID; title: String; stateLabel: String; summary: String }`, `RemoteOutcome { recordID: UUID; title: String; message: String; isSuccess: Bool }`, `RemoteAppleDoubleReview { reviewID: UUID; paths: [String] }`, `RemoteSettings { generateASCMHL: Bool; copyWorkers: Int; verifyWorkers: Int; verifyWhileCopying: Bool; queueNewCardsAutomatically: Bool; autoEjectWhenSafe: Bool; reportSettingsJSON: Data }`.
  - `struct RemoteStateUpdate { baseRevision: Int; newRevision: Int; snapshotPatch: RemoteSnapshotPatch }` where `RemoteSnapshotPatch` has `host`, `session`, `takenAt`, `revisions` required; every non-optional snapshot field as an optional (nil = unchanged); and every optional snapshot field (`selectedCardID`, `outcome`, `safetyClaim`, `appleDoubleReview`) as `RemotePatchValue<T>` (`enum { case unchanged; case set(T?) }`, `.unchanged` omitted on the wire, `.set(nil)` encoded as null) so a cleared field is expressible (amended 2026-11-26 after review).
  - `struct RemoteProgressSample { operationID: UUID; hostTime: Date; progress: OperationProgress }`.
  - `struct RemoteHeartbeat { hostTime: Date; stateRevision: Int }`.
  - `enum RemoteCommandBody` with the cases in the spec's "Commands and admission" list (exact labels: `selectSource(cardID: String)`, `setDestinations(backupIDs: [String])`, `setVerificationMode(VerificationMode)`, `setSettings(RemoteSettingsPatch)`, `start(selectionRevision: Int)`, `enqueue(selectionRevision: Int)`, `startQueue(queueRevision: Int)`, `pause(operationID: UUID)`, `resume(operationID: UUID)`, `cancel(operationID: UUID)`, `retry(recordID: UUID)`, `removeQueued(recordID: UUID, queueRevision: Int)`, `reorderQueue(recordIDs: [UUID], queueRevision: Int)`, `eject(cardID: String, media: MediaIncarnation, recordID: UUID)`, `answerAppleDoubleReview(reviewID: UUID, paths: [String])`, `requestExport(recordID: UUID, format: String)`, `pageHistory(cursor: String?)`).
  - `struct RemoteCommand { client: ClientID; request: RequestID; session: SessionID; contentHash: String; body: RemoteCommandBody }` with `static func contentHash(of body: RemoteCommandBody) -> String` (SHA-256 hex of the sorted-keys JSON). Its `init(from:)` recomputes the hash and throws `RemoteProtocolError.contentHashMismatch` on a forged value (amended 2026-11-26).
  - `enum RemoteCommandOutcome: Codable { case done(RemoteCommandResult), pending, unknown(reason: String), rejected(RemoteRejection) }`, `struct RemoteCommandResult { request: RequestID; revisions: ResourceRevisions; payload: Data? }`, `enum RemoteRejection: Codable { case staleRevision(current: ResourceRevisions), mediaChanged, notSafeToErase(wording: String), unauthorized, unsupported(wording: String), hostRefused(wording: String), contentMismatch }`.
  - `enum RemoteMessage: Codable { case snapshot(RemoteSnapshot), update(RemoteStateUpdate), progress(RemoteProgressSample), heartbeat(RemoteHeartbeat), command(RemoteCommand), outcome(request: RequestID, RemoteCommandOutcome) }` (request ID on every reply; amended 2026-11-26)` wrapped in `struct RemoteEnvelope { version: Int; message: RemoteMessage }` whose `init(from:)` throws `RemoteProtocolError.unsupportedProtocolVersion` when `version != RemoteProtocolVersion.current`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func everyMessageRoundTripsThroughJSON() throws        // one fixture per RemoteMessage case; encode, decode, == original
@Test func aNewerEnvelopeIsRefusedByName() throws            // version 2 envelope JSON → #expect(throws: RemoteProtocolError.self)
@Test func contentHashIsStableAcrossKeyOrder() throws        // same body hashed twice == ; different body !=
```

- [ ] **Step 2: Run to verify they fail.** Expected: FAIL, types not found.

- [ ] **Step 3: Write the types** exactly as listed. `RemoteEnvelope` decodes `version` first and throws before decoding `message`.

- [ ] **Step 4: Run to verify they pass.**

- [ ] **Step 5: Commit** `"Remote protocol: versioned messages, commands and outcomes"`.

---

### Task 3: Client state applier with gap detection

**Files:**
- Create: `Packages/BitMatchEngine/Sources/BitMatchEngine/Remote/RemoteStateApplier.swift`
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/RemoteStateApplierTests.swift`

**Interfaces:**
- Consumes: Task 2 types.
- Produces: `struct RemoteStateApplier: Sendable { private(set) var installed: RemoteSnapshot?; private(set) var needsSnapshot: Bool; mutating func install(_ snapshot: RemoteSnapshot) -> InstallResult; mutating func apply(_ update: RemoteStateUpdate) -> ApplyResult }` with `enum ApplyResult { case applied, ignoredOlder, gap }`. `enum InstallResult { case installed, ignoredOlder }`: a snapshot for the same host and session whose `revisions.state <= installed.revisions.state` is ignored unless `needsSnapshot` is set or nothing is installed (amended 2026-11-26). An update whose `snapshotPatch.revisions.state != newRevision` is a gap. `apply` requires `installed != nil`, `update.baseRevision == installed.revisions.state`; a `RemotePatchValue.set(nil)` clears the field and `.unchanged` leaves it; an update with `newRevision <= installed.revisions.state` is `.ignoredOlder`; any other mismatch sets `needsSnapshot = true`, leaves `installed` unchanged and returns `.gap`. `install` clears `needsSnapshot`. A `host` or `session` that differs from the installed one is a gap.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anInOrderUpdateAppliesItsPatchOnly()          // patch one field; others unchanged; revision advances
 func aPatchCanClearTheSafetyClaim()                // installed has a claim; update with safetyClaim .set(nil) → installed.safetyClaim == nil
@Test func aSkippedRevisionMarksNeedsSnapshotAndChangesNothing()   // Review Focus 2
@Test func anOlderUpdateIsIgnoredNeverRolledBack()
@Test func aDifferentSessionIsAGap()
@Test func installingASnapshotClearsNeedsSnapshot()
```

- [ ] **Step 2: Run to verify they fail.** **Step 3: Implement.** **Step 4: Run to verify they pass.**

- [ ] **Step 5: Commit** `"Remote client applies ordered state and asks for a snapshot on any gap"`.

---

### Task 4: Safety-claim lease

**Files:**
- Create: `Packages/BitMatchEngine/Sources/BitMatchEngine/Remote/RemoteSafetyLease.swift`
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/RemoteSafetyLeaseTests.swift`

**Interfaces:**
- Consumes: `RemoteSafetyClaim`, `RemoteHeartbeat`.
- Produces: `struct RemoteSafetyLease: Sendable { init(leaseLength: TimeInterval = 10); mutating func noteState(revision: Int, claim: RemoteSafetyClaim?, at: Date); mutating func noteHeartbeat(_ h: RemoteHeartbeat, at: Date); mutating func noteDisconnected(); mutating func noteBackgrounded(); mutating func noteMedia(_ media: MediaIncarnation?); func currentClaim(at: Date) -> RemoteSafetyClaim? }`. `currentClaim` returns the claim only when: a claim was noted, the last heartbeat or state is within `leaseLength`, the claim's `revision` equals the latest noted state revision, the last noted media equals the claim's media, and neither disconnected nor backgrounded has been noted since the last `noteState`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aClaimIsCurrentWithinTheLease()
@Test func theClaimExpiresWhenHeartbeatsStop()
@Test func aHeartbeatAloneDoesNotReviveAnOlderClaim()        // Review Focus 3: noteState(rev 5, claim rev 4) then heartbeat → nil
@Test func disconnectAndBackgroundingHideTheClaimUntilAFreshState()
@Test func aChangedMediaIncarnationHidesTheClaim()
```

- [ ] **Steps 2–4:** fail, implement, pass. **Step 5: Commit** `"Remote safety claim is shown only under a live lease at the latest revision"`.

---

### Task 5: Durable admission store

**Files:**
- Create: `Packages/BitMatchEngine/Sources/BitMatchEngine/Remote/RemoteAdmissionStore.swift`
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/RemoteAdmissionStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 `DurableJSONFile`, Task 2 `ClientID`, `RequestID`, `RemoteCommandOutcome`.
- Produces: `final class RemoteAdmissionStore: Sendable` (a `Mutex`-guarded state, matching `TransferJournal`'s style) with `init(fileURL: URL, now: @Sendable () -> Date = Date.init, retention: TimeInterval = 24 * 3600) throws`, `enum Admission { case admitted, duplicatePending, duplicateDone(RemoteCommandOutcome), contentMismatch }`, `func admit(client: ClientID, request: RequestID, contentHash: String) throws -> Admission`, `func complete(client: ClientID, request: RequestID, outcome: RemoteCommandOutcome) throws`, `func pendingAtLoad() -> [(ClientID, RequestID)]`, `func markUnknown(client: ClientID, request: RequestID, reason: String) throws`, `func purgeExpired(keepingClients active: Set<ClientID>) throws` (entries of connected clients are never purged). Every mutation stages a copy, writes the whole store through `DurableJSONFile.write`, and adopts the copy in memory only on success (or on `FlushAfterPublishFailure`, when the file was already replaced); `markUnknown` sets `completedAt` so unknown outcomes are retained for the full retention (amended 2026-11-26). On `init`, entries that were `pending` when the file was written are reported by `pendingAtLoad()` and stay `pending` until the host reconciles them.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aNewRequestIsAdmittedAndADuplicateSeesPending() throws       // Review Focus 1
@Test func aCompletedRequestReturnsItsOriginalOutcomeOnRetry() throws
@Test func aReusedIDWithDifferentContentIsRefused() throws
@Test func pendingEntriesSurviveAReloadAndAreReported() throws           // write, new instance on same file, pendingAtLoad non-empty
@Test func expiredEntriesArePurgedAfterRetention() throws                // now closure advanced 25h
```

- [ ] **Steps 2–4:** fail, implement, pass. **Step 5: Commit** `"Remote admission store: every command is admitted before it acts and remembered after"`.

---

### Task 6: Command executor over `RemoteSurface`

**Files:**
- Create: `Shared/Core/Remote/RemoteCommandExecutor.swift`
- Create: `Shared/Core/Remote/RemoteHostState.swift` (host-side bookkeeping: card and backup catalogues keyed by opaque IDs, media incarnations, current `ResourceRevisions`)
- Test: `BitMatchTests/RemoteCommandExecutorTests.swift` with a `FakeRemoteSurface` (an `ObservableObject` conforming to `RemoteSurface` that records intent calls and lets tests set state)

**Interfaces:**
- Consumes: Task 0 `RemoteSurface`, Task 2 commands and outcomes, Task 5 `RemoteAdmissionStore`.
- Produces: `@MainActor final class RemoteCommandExecutor { init(surface: any RemoteSurface, host: RemoteHostState, admission: RemoteAdmissionStore, safeToErase: @MainActor (UUID, MediaIncarnation) -> Bool); func execute(_ command: RemoteCommand) async -> RemoteCommandOutcome }`. Behaviour pinned by the spec: a decoded command already carries a verified `contentHash` (Task 2), so the executor passes it to `admit`; admission first (`duplicatePending → .pending`, `duplicateDone(o) → o`, `contentMismatch → .rejected(.contentMismatch)`); each body case checks its revision against `host.revisions` in the same main-actor turn before calling the intent and returns `.rejected(.staleRevision(current:))` on mismatch; outcomes come from what the intent itself returns or throws and `.done` carries the revisions read after the await; the void intents (pause, resume, startQueue, retry) verify a target-specific postcondition on the surface in the same turn and report `.rejected(.hostRefused)` when it fails; a Start that enqueued but whose queue did not run is `.unknown("enqueued; the queue did not start")`; resume requires a paused operation; a project-record retry is `.rejected(.unsupported)` before any call; `.unknown` is reserved for partial effects, an outcome the store could not record, and crash reconciliation (amended 2026-11-26); `eject` checks, before touching the surface: `host.media(for: cardID) == media` (else `.rejected(.mediaChanged)`), the record resolved from `transferJournal.records` has its source inside the card folder (else `.rejected(.hostRefused)`), `safeToErase(recordID, media)` (else `.rejected(.notSafeToErase)`), and `ejectingQueueSourceIDs` does not already contain the record (else `.rejected(.hostRefused("eject already in progress"))`); `cancel` uses `cancelOperation(ifCurrentTargetID:origin: .remote)` (add `.remote` to `TransferCancelOrigin` if absent); `requestExport` and `pageHistory` return `.rejected(.unsupported("later slice"))` in this plan; every outcome is written to the admission store before being returned.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func startAtTheCurrentSelectionRevisionCallsTheSurfaceOnce() async throws
@MainActor @Test func startAtAStaleRevisionIsRejectedWithTheCurrentRevisions() async throws
@MainActor @Test func aDuplicateInFlightStartReportsPendingAndRunsOnce() async throws      // Review Focus 1, surface intent suspended on a continuation
@MainActor @Test func ejectWithAChangedMediaIncarnationIsRefusedEvenWhenSafe() async throws  // Review Focus 4
@MainActor @Test func ejectWhenNotSafeIsRefusedWithTheWording() async throws
@MainActor @Test func aRevisionThatMovesDuringAnIntentEndsAsUnknown() async throws
@MainActor @Test func cancelGoesThroughTheTargetCheckedIntent() async throws
```

- [ ] **Steps 2–4:** fail, implement, pass (`./test.sh mac-test` with `-only-testing:BitMatchTests/RemoteCommandExecutorTests`). **Step 5: Commit** `"Remote commands are admitted, revision-checked and revalidated before the coordinator acts"`.

---

### Task 7: Snapshot builder and `RemoteCoordinatorView`

**Files:**
- Create: `Shared/Core/Remote/RemoteSnapshotBuilder.swift`
- Create: `Shared/Core/Remote/RemoteCoordinatorView.swift`
- Create: `Shared/Core/Remote/RemoteCommandSender.swift`
- Test: `BitMatchTests/RemoteSnapshotBuilderTests.swift`, `BitMatchTests/RemoteCoordinatorViewTests.swift`

**Interfaces:**
- Consumes: Task 0 `RemoteSurface`, Task 2 types, Task 3 applier, Task 4 lease, Task 6 `RemoteHostState`.
- Produces:
  - `@MainActor struct RemoteSnapshotBuilder { init(surface: any RemoteSurface, host: RemoteHostState, hostName: String, session: SessionID); func snapshot(now: Date) -> RemoteSnapshot; func patch(from previous: RemoteSnapshot, now: Date) -> RemoteStateUpdate? }` where `patch` returns nil when nothing changed, bumps only the `ResourceRevisions` fields whose content changed, and always bumps `state`.
  - `protocol RemoteCommandSender: Sendable { func send(_ body: RemoteCommandBody) async -> RemoteCommandOutcome }`.
  - Carried forward from Tasks 4 and 6 (2026-11-26): the snapshot builder bumps `revisions.selection` when source preparation finishes, not only when the selection changes; the snapshot publishes the operation ID pause/resume use (`stateService.currentOperationId`) and the ID cancel uses (`activeStartID ?? currentOperationId`) as two fields; `RemoteSettings` is built from `generalSettings` taking only `queueNewCardsAutomatically` and `autoEjectWhenSafe` (notifications, sounds, updates stay Mac-local); `RemoteCoordinatorView` creates a fresh `RemoteSafetyLease` whenever the installed snapshot's `host` or `session` changes, because the lease's highest-seen revision never decreases; it calls `noteMedia` from the installed snapshot's selected card before or together with `noteState`.
  - `@MainActor final class RemoteCoordinatorView: ObservableObject` holding a `RemoteStateApplier`, a `RemoteSafetyLease`, the latest `RemoteProgressSample`, a `connection: RemoteConnectionFreshness` (`enum { case live, stale(since: Date), disconnected }`), and exposing read properties with the names the inventory lists, derived from `applier.installed`; intents named as in `RemoteSurface` but implemented by `sender.send(...)`. It does not conform to `RemoteSurface` in this plan (the views still bind to the concrete coordinator until slice 2); it exposes `func receive(_ message: RemoteMessage, at: Date)`.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func aSnapshotCarriesTheSurfaceSelectionAsOpaqueIDs()
@MainActor @Test func anUnchangedSurfaceProducesNoPatch()
@MainActor @Test func changingOnlySettingsBumpsSettingsAndStateRevisions()
@MainActor @Test func theViewShowsNoSafetyClaimAfterDisconnect()
@MainActor @Test func aStartTapBecomesAStartCommandAtTheInstalledSelectionRevision() async
```

- [ ] **Steps 2–4:** fail, implement, pass. **Step 5: Commit** `"Remote snapshots and the client-side coordinator view"`.

---

### Task 8: Host and client cores over an in-memory link

**Files:**
- Create: `Shared/Core/Remote/RemoteHostCore.swift`
- Create: `Shared/Core/Remote/RemoteClientCore.swift`
- Create: `Shared/Core/Remote/RemoteLink.swift` (`protocol RemoteLink: Sendable { func send(_ envelope: RemoteEnvelope) async throws; var incoming: AsyncStream<RemoteEnvelope> { get } }`)
- Test: `BitMatchTests/RemoteInProcessTests.swift` with `InMemoryRemoteLink` (two ends, optional `dropNextReply`, `delay`)

**Interfaces:**
- Consumes: Tasks 2–7.
- Produces: `@MainActor final class RemoteHostCore { init(surface: any RemoteSurface, host: RemoteHostState, admission: RemoteAdmissionStore, hostName: String, heartbeatInterval: TimeInterval = 2); func attach(_ link: any RemoteLink, session: SessionID); func detach(session: SessionID); func reconcilePendingAtLaunch(using: (ClientID, RequestID) -> RemoteCommandOutcome?) }` which observes the surface's `objectWillChange`, sends a snapshot on attach, patches on change, heartbeats on the interval, and routes commands to `RemoteCommandExecutor`. `@MainActor final class RemoteClientCore { init(view: RemoteCoordinatorView, link: any RemoteLink, client: ClientID, replyTimeout: TimeInterval = 10); func start(); func stop() }` feeding every incoming envelope to `view.receive(_:at:)` and conforming to the transmit-only `RemoteCommandSender` (`send(_ body:, request:) async throws`, amended 2026-11-26): it builds the `RemoteCommand` with the view's request ID and the installed session, sends it on the link, and tracks the request; after `replyTimeout` without a matching `.outcome` it resolves the request through `view.pendingOutcomes` as `.unknown("no reply")`, keeping the `RequestID` so a retry carries the same content hash. `stop()` and a link failure call the view's disconnect handling. The host core calls `admission.purgeExpired(keepingClients:)` with its attached clients on a timer and uses `RemoteHostState.id` as the `HostID`. `reconcilePendingAtLaunch` marks every pending admission `unknown` unless the closure proves an outcome.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func attachingSendsASnapshotAndTheViewMirrorsTheSurface() async throws
@MainActor @Test func aSurfaceChangeArrivesAsAnUpdateNotASnapshot() async throws
@MainActor @Test func aLostReplyThenRetryReturnsTheOriginalOutcomeAndRunsOnce() async throws   // dropNextReply
@MainActor @Test func aDuplicateInFlightCommandOverTheLinkSeesPending() async throws         // Review Focus 1
@MainActor @Test func pendingAdmissionsAtLaunchBecomeUnknownUnlessProved() async throws
@MainActor @Test func aStaleSelectionRevisionIsRejectedWithTheCurrentOne() async throws
@MainActor @Test func heartbeatsKeepTheClaimAndSilenceDropsIt() async throws                  // controllable clock
```

- [ ] **Steps 2–4:** fail, implement, pass. **Step 5: Run the full local validation** (`./test.sh engine-test`, `./test.sh mac-test`, `./test.sh mac-build`, `./test.sh ipad-build`). Expected: all pass. **Step 6: Commit** `"Remote host and client cores round-trip commands and state in one process"`.

---

### Task 9: Documentation

**Files:**
- Modify: `ARCHITECTURE.md` (new "Remote" section: the two streams, admission, lease, where the types live)
- Modify: `docs/REMOTE_PROTOCOL_CONTRACT.md` (status line: "Slices 0–1 implemented; see the design and ARCHITECTURE")
- Modify: `CHANGELOG.md` under Unreleased: "Groundwork for BitMatch Remote (no user-visible change yet)."

- [ ] **Step 1: Write the sections.** **Step 2: Commit** `"Documents the Remote groundwork"`.

---

## Self-review notes

- Spec coverage: slice 0 (Task 0), slice 1 (Tasks 1–8), admission and crash reconciliation (Tasks 5, 6, 8), two streams and gap handling (Tasks 2, 3, 7), safety lease (Tasks 4, 7, 8), media binding on eject (Task 6), no new prompts (Task 2's single review command), durable writes (Task 1). Pairing, TLS, discovery, Local Network privacy, Settings → Remote and the iPad Remote entry are slices 2–4 and get their own plans after the inventory exists.
- Names used across tasks match: `RemoteSurface`, `RemoteHostState`, `RemoteAdmissionStore.Admission`, `RemoteCommandOutcome`, `RemoteStateApplier.ApplyResult`, `RemoteSafetyLease.currentClaim(at:)`, `RemoteCommandSender`, `RemoteLink`.
- Review Focus items 1–5 each have a named test in Tasks 2, 3, 4, 5/8 and 6.
