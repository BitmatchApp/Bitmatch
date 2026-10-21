# Queue Polish Implementation Plan (spec steps 0, 1, 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the two queue bugs, finish the safe-to-erase loop in the expanded row hero, and rebuild the queue row so a DIT can tell cards apart and act from the collapsed row.

**Architecture:** All wording and state decisions live in the presentation models (`QueueSessionPresentation`, `QueueSessionRow`, `TransferOutcomePresentation`) so they are unit-tested without views. `TransferQueueSection` reads those strings and lays them out; it gains no logic. Journal records are never deleted or merged. Eject carry-through is Mac-only (existing exception) and flows coordinator → presentation → view like eject does today.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`, `#expect`), Xcode project `BitMatch.xcodeproj`, scheme `BitMatch`, tests in `BitMatchTests`. Shared views compile for Mac, iPad and iPhone.

**Spec:** `docs/superpowers/specs/2026-10-21-visual-polish-design.md` (sections "Constraints from the code", steps 0–2, "Calls made after the builder check", "Decided by Mike").

## Global Constraints

- Green (`CardSafetyTint.green`) only for `.safeToErase`. Never add green to any other state.
- "Copied, not verified" stays amber and is the Quick-mode verdict only.
- Vocabulary: card and backup(s) in UI text; never "source" or "destination" in new strings. Sentence case for all new labels.
- Journal records are never deleted or merged by this work.
- No new platform branch except where the spec names an existing Mac-only capability (eject, Dock badge).
- No sound. Attention notice is a normal notification banner.
- No competitor names anywhere in the diff.
- Three PRs, one per spec step, each with before and after screenshots from the real build (Mac dark; iPad and iPhone light and dark) attached to the PR, not committed.
- Run before every commit: `./test.sh mac-test` (full) or the single-suite command in each task. Before each PR: `./test.sh mac-test && ./test.sh ipad-build`.

Single suite: `xcodebuild test -project BitMatch.xcodeproj -scheme BitMatch -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:BitMatchTests/<SuiteName> 2>&1 | grep -E "Test Suite|passed|failed|error:" | tail -20`

## Review Focus

1. A card restarted three times shows one row; earlier attempts remain in the journal and History. Test in Task 1.
2. "Remove from queue" on a paused card whose record is still `.running` in the journal removes the row or shows an alert naming the reason; it never does nothing. Test in Task 2.
3. A record with `.failed` state and a `checksumMismatch` row reads "Didn't verify"; one with a `❌ Failed` row and no mismatch reads "Didn't copy". Test in Task 6.
4. A row whose `endedAt` is nil (legacy record) still renders a meta line without "Verified " and a blank time. Test in Task 7.
5. Eject on a card whose volume has already gone shows "Removed", never a dead "Eject" button. Test in Task 4.

---

## PR A · Spec step 0: two bugs

Branch: `fix/queue-attempts-and-remove`

### Task 1: Collapse repeated attempts of one card into one row

**Files:**
- Modify: `Shared/Core/Models/QueueSessionPresentation.swift` (`QueueSessionRow`, `QueueSessionPresentation.make`, `makeRow`)
- Test: `BitMatchTests/QueueSessionPresentationTests.swift`

**Interfaces:**
- Produces on `QueueSessionRow`: `let endedAt: Date?`, `let earlierAttemptIDs: [UUID]` (oldest first, empty when none).
- Produces: `static func attemptKey(for record: LocalTransferRecord) -> String` on `QueueSessionPresentation`, returning `record.source.volumeID ?? record.source.url.path`.
- Later tasks read `endedAt` (Task 7) and `earlierAttemptIDs` (Task 9).

- [ ] **Step 1: Write the failing test**

```swift
@Test func repeatedAttemptsOfOneCardCollapseToLatestRow() throws {
    let fixture = try QueuePresentationFixture()
    defer { fixture.cleanup() }
    // Three finished-with-problem attempts of the same source, then nothing else.
    let first = try fixture.record(name: "A7IV_CARD1", state: .failed)
    let second = try fixture.record(name: "A7IV_CARD1", state: .failed)
    let third = try fixture.record(name: "A7IV_CARD1", state: .issues)
    let queue = QueueSessionPresentation.make(
        records: [third, second, first], sessionIDs: [first.id, second.id, third.id],
        sessionRecordIDsInOrder: [first.id, second.id, third.id],
        progress: nil, mountedSourceIDs: [])
    #expect(queue.rows.count == 1)
    #expect(queue.rows[0].id == third.id)
    #expect(queue.rows[0].earlierAttemptIDs == [first.id, second.id])
    #expect(queue.rows[0].endedAt == third.endedAt)
}

@Test func differentCardsNeverCollapse() throws {
    let fixture = try QueuePresentationFixture()
    defer { fixture.cleanup() }
    let a = try fixture.record(name: "CardA", state: .failed)
    let b = try fixture.record(name: "CardB", state: .failed)
    let queue = QueueSessionPresentation.make(records: [b, a], sessionIDs: [a.id, b.id],
        sessionRecordIDsInOrder: [a.id, b.id], progress: nil, mountedSourceIDs: [])
    #expect(queue.rows.map(\.id) == [a.id, b.id])
}
```

If `QueuePresentationFixture.record(...)` (line ~725 of the test file) has no `name:`/`state:` parameters, extend it so two records can share a source path and carry a `LocalTransferState`.

- [ ] **Step 2: Run the suite; expect both tests to fail to compile on `earlierAttemptIDs`**

- [ ] **Step 3: Implement**

In `QueueSessionRow` add `let endedAt: Date?` and `let earlierAttemptIDs: [UUID]`; `makeRow` passes `record.endedAt` and `[]`.

In `make`, after `session` is built and before rows: walk `session` in order; for each record whose `attemptKey` matches an earlier record in the session where the earlier record's state is `.failed`, `.interrupted`, `.cancelled`, or `.issues`, drop the earlier record from the row list and append its id to the later record's attempt list. A later attempt never collapses into an earlier one; a `.queued` or `.running` earlier record is never collapsed. Build the row from the surviving record with `earlierAttemptIDs` set (add an `earlierAttemptIDs` parameter to `makeRow`; for `completedRows` cache hits, copy the ids onto the cached row with a `private(set) var` and a `fileprivate func withEarlierAttempts(_:)`).

`tally`, `ejectableCardIDs`, `pausedCardID` and `copySummary` all derive from `rows`, so they follow.

- [ ] **Step 4: Run the suite; expect PASS, and the whole suite still green**

- [ ] **Step 5: Commit**

```bash
git add Shared/Core/Models/QueueSessionPresentation.swift BitMatchTests/QueueSessionPresentationTests.swift
git commit -m "Collapse repeated attempts of one card into one queue row"
```

### Task 2: Remove from queue always does something visible

**Files:**
- Modify: `Shared/Core/Services/SharedAppCoordinator.swift:1907-1925` (`removePausedCardFromQueue`)
- Modify: `Shared/Views/TransferQueueSection.swift:898-902` (`perform`) and the `errorMessage` caption near line 74
- Test: `BitMatchTests/MainScreenQueueTests.swift` (coordinator-level queue tests live here; add alongside)

**Interfaces:**
- `removePausedCardFromQueue(_ expectedID: UUID) throws` keeps its signature. It now succeeds whenever `queuePausedRecordID == expectedID` and the record exists, regardless of journal state. Its only error is `FileOperationError.unsafeOperation("Only the card pausing this queue can be removed.")` when the id is not the paused card.
- `TransferQueueSection.perform` presents thrown errors in an `.alert("Couldn't do that", isPresented:presenting:)` with the error text as the message, instead of the caption.

- [ ] **Step 1: Write the failing test**

```swift
@Test func removingPausedCardWorksWhileItsRecordIsStillRunning() async throws {
    // Use the existing MainScreenQueueTests helpers to make a coordinator with one
    // session record whose journal state is .running, then set it as the paused card.
    let (coordinator, record) = try await makeCoordinatorWithPausedRunningCard()
    try coordinator.removePausedCardFromQueue(record.id)
    #expect(!coordinator.queueSessionRecordIDs.contains(record.id))
    #expect(coordinator.queuePausedRecordID == nil)
}

@Test func removingANonPausedCardThrowsNamedReason() async throws {
    let (coordinator, _) = try await makeCoordinatorWithPausedRunningCard()
    #expect(throws: FileOperationError.self) { try coordinator.removePausedCardFromQueue(UUID()) }
}
```

Write `makeCoordinatorWithPausedRunningCard()` next to the suite's existing coordinator factory; it enqueues one record, marks it running, and sets `queuePausedRecordID` through whichever existing path the suite already uses to pause a queue (search the file for `queuePausedRecordID`).

- [ ] **Step 2: Run `MainScreenQueueTests`; expect the first test to FAIL with "Only the card pausing this queue can be removed."**

- [ ] **Step 3: Implement**

Drop `Self.isQueueProblem(record)` from the guard at line 1910. Keep the rest of the function.

In `TransferQueueSection`, add `@State private var alertError: String?`, have `perform` set it instead of `errorMessage`, and attach `.alert("Couldn't do that", isPresented: Binding(get: { alertError != nil }, set: { if !$0 { alertError = nil } }), presenting: alertError) { _ in Button("OK") {} } message: { Text($0) }` to the section body. Leave `errorMessage` for the non-action errors that already use it.

- [ ] **Step 4: Run the suite; expect PASS**

- [ ] **Step 5: Reproduce on the live queue state, then commit**

Launch the Debug build with the current stuck queue, click Remove from queue on the paused banner, confirm the row leaves or an alert names the reason. Then:

```bash
git add Shared/Core/Services/SharedAppCoordinator.swift Shared/Views/TransferQueueSection.swift BitMatchTests/MainScreenQueueTests.swift
git commit -m "Let the paused card be removed and surface refusals as an alert"
```

- [ ] **Step 6: Open PR A** with before/after screenshots of the queue on the stuck state. Title: "Queue: collapse repeated attempts; make Remove from queue visible".

---

## PR B · Spec step 1: the safe-to-erase loop

Branch: `feat/safe-to-erase-loop`

### Task 3: Hero wording, backups by volume and folder, Next card

**Files:**
- Modify: `Shared/Core/Models/TransferOutcomePresentation.swift` (`make`, `OutcomeDestinationLine`, `finishTitle` neighbourhood ~126-160, `showsNewTransfer` ~260)
- Modify: `Shared/Views/TransferQueueSection.swift:995-1096` (`SafeTransferHero`), `:678-724` (`finishedActions`, `finishedActionButtons`)
- Test: `BitMatchTests/TransferOutcomePresentationTests.swift`

**Interfaces:**
- Produces on `TransferOutcomePresentation`: `let heroSubtitle: String` and `let nextCardLabel: String` (always "Next card").
- `OutcomeDestinationLine.title` becomes "<VOLUME> › <folder path under the volume root>", e.g. "SHUTTLE A › Day_04/A_CAM"; `detail` unchanged.
- `canRetry` semantics unchanged; the view moves Retry into the overflow menu when `safetyState == .safeToErase`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func heroSubtitleIsExactForStandardVerify() {
    let outcome = make(state: .completed, mode: .standard, files: 486, destinations: 2, seconds: 95)  // suite helper
    #expect(outcome.heroSubtitle == "486 files read back from both backups and matched to the card. 1m 35s.")
    #expect(outcome.nextCardLabel == "Next card")
}
@Test func heroSubtitleNamesThreeBackupsAndParanoid() {
    let outcome = make(state: .completed, mode: .paranoid, files: 12, destinations: 3, seconds: 61)
    #expect(outcome.heroSubtitle == "12 files compared byte for byte and matched to the card on 3 backups. 1m 1s.")
}
@Test func destinationLineIsVolumeThenFolder() {
    let outcome = make(state: .completed, mode: .standard, files: 1, destinations: 1, seconds: 2,
                       destinationURL: URL(fileURLWithPath: "/Volumes/SHUTTLE A/Day_04/A_CAM"))
    #expect(outcome.destinations[0].title == "SHUTTLE A › Day_04/A_CAM")
}
```

Extend the suite's private `make(...)` helper (line 31) with `destinations:` count and an optional `destinationURL:` if it lacks them.

- [ ] **Step 2: Run `TransferOutcomePresentationTests`; expect compile failure on `heroSubtitle`**

- [ ] **Step 3: Implement**

`heroSubtitle`: "<N> files" + verb by mode (`.standard`: "read back from <both backups|all N backups|the backup> and matched to the card"; `.paranoid`: "compared byte for byte and matched to the card on <N backups|the backup>"; `.quick`: "copied to <N backups|the backup>; sizes checked, not verified") + ". " + `durationText(seconds)` + "." ; for two backups use "both backups". Reuse `durationText`, which already yields "1m 35s".

`OutcomeDestinationLine.title`: volume from `destinationDriveName(url)` uppercased as the volume is named; folder is the path components after `/Volumes/<name>/` joined with "/"; if the URL is not under `/Volumes`, use the last two path components.

View: replace the "New transfer" button label with `outcome.nextCardLabel`; drop the footnote under the buttons; when `outcome.safetyState == .safeToErase` show Retry only inside the existing overflow `Menu`; give all non-Eject buttons `.controlSize(.large)` on iOS and default on Mac so heights match; Eject keeps `.borderedProminent` green and is listed first.

- [ ] **Step 4: Run the suite; expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Shared/Core/Models/TransferOutcomePresentation.swift Shared/Views/TransferQueueSection.swift BitMatchTests/TransferOutcomePresentationTests.swift
git commit -m "Hero: exact subtitle, backups by volume and folder, Next card"
```

### Task 4: Eject carries through to the card leaving the reader (Mac)

**Files:**
- Modify: `Shared/Core/Models/QueueSessionPresentation.swift` (`QueueRowAction`, `showingSource`)
- Modify: `Shared/Core/Services/SharedAppCoordinator.swift` (~2840-2890: `markQueueSourceEjected`, `ejectQueueSource`; add `ejectingQueueSourceIDs`, `removedQueueSourceIDs`, `markQueueSourceRemoved(volumeID:)`) and the call site that builds `queuePresentation` (~575-580) to pass the new sets
- Modify: `BitMatch/Core/Services/VolumeMonitorService.swift` where volume disappearance is observed (search `DADiskDisappeared` or the unmount handler) to call `coordinator.markQueueSourceRemoved(volumeID:)`
- Modify: `Shared/Views/TransferQueueSection.swift:512-541` (`compactAction`), `:1031-1041` (hero Eject)
- Test: `BitMatchTests/QueueSessionPresentationTests.swift`, `BitMatchTests/MainScreenQueueTests.swift`

**Interfaces:**
- `QueueRowAction` gains `case ejecting` and `case removed`.
- `QueueSessionPresentation.make` gains `ejectingSourceIDs: Set<UUID> = []` and `removedSourceIDs: Set<UUID> = []`.
- Row action precedence in `showingSource`: removed → `.removed`; ejecting → `.ejecting`; ejected → `.ejected`; mounted and safe → `.eject`; problem states → `.review`; else nil.
- Labels (view): `.ejecting` shows "Ejecting…" in place of the button at the button's width; `.ejected` shows "Ejected · safe to remove"; `.removed` shows "Removed".
- Coordinator: `ejectQueueSource` inserts the id into `ejectingQueueSourceIDs` before awaiting the ejector and removes it after; `markQueueSourceRemoved(volumeID: String)` moves every ejected row whose record's `source.volumeID` matches into `removedQueueSourceIDs`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func ejectedRowBecomesRemovedWhenItsVolumeGoes() throws {
    let fixture = try QueuePresentationFixture()
    defer { fixture.cleanup() }
    let record = try fixture.record(name: "Card", state: .completed, outcome: .safe)
    let ejected = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
        progress: nil, mountedSourceIDs: [], ejectedSourceIDs: [record.id])
    #expect(ejected.rows[0].action == .ejected)
    let removed = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
        progress: nil, mountedSourceIDs: [], ejectedSourceIDs: [record.id], removedSourceIDs: [record.id])
    #expect(removed.rows[0].action == .removed)
    let ejecting = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id],
        progress: nil, mountedSourceIDs: [record.id], ejectingSourceIDs: [record.id])
    #expect(ejecting.rows[0].action == .ejecting)
}
```

And in `MainScreenQueueTests`:

```swift
@Test func ejectMarksEjectingThenEjectedThenRemoved() async throws {
    let (coordinator, record) = try await makeCoordinatorWithSafeMountedCard()
    let error = await coordinator.ejectQueueSource(record.id, using: { _ in nil })
    #expect(error == nil)
    #expect(coordinator.ejectedQueueSourceIDs.contains(record.id))
    #expect(!coordinator.ejectingQueueSourceIDs.contains(record.id))
    coordinator.markQueueSourceRemoved(volumeID: record.source.volumeID ?? "")
    #expect(coordinator.removedQueueSourceIDs.contains(record.id))
}
```

- [ ] **Step 2: Run both suites; expect compile failures on the new cases and parameters**

- [ ] **Step 3: Implement** per the Interfaces block. In `compactAction` and the hero, render the three labels as `Text` in `.secondary`, the ejecting one with a `ProgressView().controlSize(.small)` beside it, inside a `.frame(minWidth:)` equal to the Eject button's measured width so the row does not reflow. The volume monitor hook is Mac-only inside the existing `#if os(macOS)` file.

- [ ] **Step 4: Run both suites; expect PASS**

- [ ] **Step 5: Commit**

```bash
git add Shared Core BitMatch/Core/Services/VolumeMonitorService.swift BitMatchTests
git commit -m "Eject carries through: Ejecting, Ejected · safe to remove, Removed"
```

### Task 5: Unsafe-eject confirmation, attention variant copy, notification text pinned

**Files:**
- Modify: `Shared/Views/TransferQueueSection.swift` (`eject(_:)` ~930, hero attention lines ~1061-1072)
- Modify: `Shared/Core/Models/TransferFinishNotice.swift:44-70`
- Test: `BitMatchTests/TransferFinishNoticeTests.swift`

**Interfaces:**
- `TransferFinishNotice.make` for `.safeToErase` yields body "<card> is safe to erase. <N> backups verified." (singular "1 backup verified.").
- For attention states the title is "<card>: keep the card" and the body is the existing cause.
- View: the hero's Eject on a non-safe outcome is never offered (today's rule); an unsafe `ejectAll` path shows `.confirmationDialog("Not safe to erase. Eject anyway?")` with "Eject anyway" (destructive) and "Cancel".

- [ ] **Step 1: Write the failing tests**

```swift
@Test func safeNoticeNamesCardAndBackupCount() {
    let notice = TransferFinishNotice.make(sourceName: "SD_CARD_042", state: .completed, issueCount: 0,
        destinations: [URL(fileURLWithPath: "/Volumes/A"), URL(fileURLWithPath: "/Volumes/B")], kind: .cardFinished)
    #expect(notice?.body == "SD_CARD_042 is safe to erase. 2 backups verified.")
}
@Test func attentionNoticeSaysKeepTheCard() {
    let notice = TransferFinishNotice.make(sourceName: "SD_CARD_042", state: .completed, issueCount: 1,
        destinations: [URL(fileURLWithPath: "/Volumes/A")], kind: .cardFinished)
    #expect(notice?.title == "SD_CARD_042: keep the card")
}
```

Match the real `make(...)` parameter list at line 44; adjust names, not intent.

- [ ] **Step 2: Run; expect FAIL on the strings**

- [ ] **Step 3: Implement** the two strings; add the confirmation dialog on the eject-all path only.

- [ ] **Step 4: Run; expect PASS. Then `./test.sh mac-test && ./test.sh ipad-build`.**

- [ ] **Step 5: Commit and open PR B** with hero screenshots (Mac dark, iPad light/dark) and the eject sequence as three frames.

```bash
git commit -am "Notifications say safe to erase or keep the card; confirm unsafe eject"
```

---

## PR C · Spec step 2: the transfer row

Branch: `feat/transfer-row`

### Task 6: Queue state vocabulary and the failure split

**Files:**
- Modify: `Shared/Core/Models/QueueSessionPresentation.swift` (`QueueSessionRow`, `makeRow`, `QueueTally`)
- Test: `BitMatchTests/QueueSessionPresentationTests.swift`

**Interfaces:**
- Produces on `QueueSessionRow`: `enum FailureStage: Equatable, Sendable { case copy, verify }`, `let failureStage: FailureStage?` (non-nil only when `safetyState == .failed`), `var queueLabel: String`, `var queueSymbol: String`.
- `queueLabel` by state: waiting "Queued"; preparing/copying/finishing "Copying"; verifying "Verifying"; safeToErase "Safe to erase"; copiedNotVerified "Copied, not verified"; needsAttention and interrupted "Keep the card"; failed "Didn't verify" (stage verify) or "Didn't copy" (stage copy); selected-files-verified rows "Selected files verified".
- `queueSymbol`: waiting "clock"; running states "arrow.triangle.2.circlepath"; safeToErase "checkmark.circle.fill"; copiedNotVerified "circle.lefthalf.filled"; needsAttention/interrupted "exclamationmark.triangle.fill"; failed "xmark.octagon.fill".
- `failureStage`: `.verify` when any result row's `ResultOutcome(statusText:)` is `.checksumMismatch`; otherwise `.copy`.
- `QueueTally` gains `var queueHeaderText: String` using the same words: "1 safe to erase · 1 keep the card · 1 didn't verify · 1 copied, not verified · 2 queued", omitting zero counts; `interrupted` counts under "keep the card"; `failed` under "didn't verify". `title`, `symbol`, `tint` on `CardSafetyState` are unchanged (History keeps its words).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func queueLabelsSayWhatToDo() throws {
    let fixture = try QueuePresentationFixture()
    defer { fixture.cleanup() }
    let attention = try fixture.record(name: "A", state: .issues)
    let mismatch = try fixture.record(name: "B", state: .failed, results: [.checksumMismatch])
    let copyFail = try fixture.record(name: "C", state: .failed, results: [.failed])
    let interrupted = try fixture.record(name: "D", state: .interrupted)
    let queue = QueueSessionPresentation.make(records: [interrupted, copyFail, mismatch, attention],
        sessionIDs: [attention.id, mismatch.id, copyFail.id, interrupted.id],
        sessionRecordIDsInOrder: [attention.id, mismatch.id, copyFail.id, interrupted.id],
        progress: nil, mountedSourceIDs: [])
    #expect(queue.rows.map(\.queueLabel) == ["Keep the card", "Didn't verify", "Didn't copy", "Keep the card"])
    #expect(queue.rows[1].failureStage == .verify && queue.rows[2].failureStage == .copy)
    #expect(queue.rows.map(\.queueSymbol) == ["exclamationmark.triangle.fill", "xmark.octagon.fill", "xmark.octagon.fill", "exclamationmark.triangle.fill"])
    #expect(queue.tally.queueHeaderText == "2 keep the card · 2 didn't verify")
}
```

Extend the fixture's `record(...)` with `results: [ResultOutcome] = []` producing one `ResultRow` per outcome with `status: outcome.statusText`.

- [ ] **Step 2: Run; expect compile failure**
- [ ] **Step 3: Implement** per Interfaces.
- [ ] **Step 4: Run; expect PASS**
- [ ] **Step 5: Commit** `git commit -am "Queue rows: labels that say what to do; split copy and verify failures"`

### Task 7: The meta line and plain-language causes

**Files:**
- Modify: `Shared/Core/Models/QueueSessionPresentation.swift`
- Test: `BitMatchTests/QueueSessionPresentationTests.swift`

**Interfaces:**
- Produces: `func metaLine(now: Date = Date(), calendar: Calendar = .current) -> String` on `QueueSessionRow`.
- Grammar: `<state word> <time> · <reason or backups> · <size>`, segments joined by " · ", at most three, empty segments dropped. State word by state: safeToErase "Verified", copiedNotVerified "Copied", needsAttention/interrupted "Paused", failed "Stopped", waiting "Queued" (no time), running states handled by Task 8. Time is `endedAt` formatted `h:mm a` in the given calendar's locale; omitted when nil. Middle segment: for needsAttention/failed/interrupted the plain cause; otherwise `destinationNames.joined(", ")`. Size is the byte part of `evidence` (after " · ") when present.
- Produces: `static func plainCause(_ cause: String) -> String` on `QueueSessionPresentation`: applies, in order, these replacements on the deduplicated cause, case-insensitive, and returns the first clause only: "selected-file plan was not saved" → "can't confirm every file was copied"; "whole-card coverage cannot be confirmed" → "can't confirm every file was copied"; "Keep the source." → "" ; "destination" → "backup"; "source" → "card". Trailing period removed.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func metaLineFollowsTheGrammar() throws {
    let fixture = try QueuePresentationFixture()
    defer { fixture.cleanup() }
    var record = try fixture.record(name: "A7IV_CARD2", state: .completed, outcome: .safe, files: 486, bytes: 48_100_000_000,
                                    destinationNames: ["Shuttle A", "Shuttle B"])
    record.endedAt = Date(timeIntervalSince1970: 1_761_000_060)   // 4:41 PM in the test calendar below
    let queue = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: nil, mountedSourceIDs: [])
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/New_York")!; cal.locale = Locale(identifier: "en_US")
    #expect(queue.rows[0].metaLine(calendar: cal) == "Verified 4:41 PM · Shuttle A, Shuttle B · 48.1 GB")
}
@Test func metaLineWithoutEndDateOmitsTime() throws { /* same record, endedAt = nil */ 
    #expect(line == "Verified · Shuttle A, Shuttle B · 48.1 GB") }
@Test func plainCauseReplacesEngineWords() {
    #expect(QueueSessionPresentation.plainCause("Original selected-file plan was not saved; whole-card coverage cannot be confirmed. Keep the source.")
            == "can't confirm every file was copied")
}
```

Pick the `timeIntervalSince1970` value so it reads 4:41 PM in New York; adjust the constant, not the expectation.

- [ ] **Step 2: Run; expect compile failure**
- [ ] **Step 3: Implement**; `cause` on the row keeps the raw text (History and banners still use it); `metaLine` calls `plainCause`.
- [ ] **Step 4: Run; expect PASS**
- [ ] **Step 5: Commit** `git commit -am "Queue rows: fixed meta-line grammar and plain-language causes"`

### Task 8: Running-row detail: phase, backup index, current file, time and rate

**Files:**
- Modify: `Shared/Core/Models/QueueSessionPresentation.swift`
- Modify: `Shared/Core/Models/TransferProgressPresentation.swift` (reuse `speedText` and the time-left formatting; make them `static` and internal if they are private)
- Test: `BitMatchTests/QueueSessionPresentationTests.swift`

**Interfaces:**
- Produces: `struct RunningRowDetail: Equatable, Sendable { let metaLine: String; let currentFile: String?; let timeAndRate: String? }` and `func runningDetail(progress: OperationProgress?, timeRemaining: String?) -> RunningRowDetail?` on `QueueSessionRow` (nil unless `isRunning`).
- `metaLine`: copying → "Copying to <names joined ", ">" + " · <size>"; verifying → "Verifying <name of first destination whose perDestinationProgress < 1, else last> · <k> of <n> backups · <size>" where k is that index + 1; finishing → "Finishing · <size>"; preparing → "Preparing".
- `currentFile`: last path component of `progress.currentFile`, nil when empty.
- `timeAndRate`: "About <timeRemaining> · <speed>" using `TransferProgressPresentation.speedText` for the rate ("557 MB/s"); when `timeRemaining` equals `TransferProgressPresentation.estimatingTimeLeft` use "Estimating…" alone; nil when neither is known.

- [ ] **Step 1: Write the failing test**

```swift
@Test func runningDetailNamesPhaseBackupFileAndRate() throws {
    let fixture = try QueuePresentationFixture()
    defer { fixture.cleanup() }
    let record = try fixture.record(name: "B_CAM", state: .running, destinationNames: ["Shuttle A", "Shuttle B", "Shuttle C"])
    let progress = OperationProgress(overallProgress: 0.61, currentFile: "/Volumes/B_CAM/CLIP/B007C012.mov",
        filesProcessed: 10, totalFiles: 20, currentStage: .verifying, speed: 557_000_000, perDestinationProgress: [1, 0.4, 0], totalBytes: 218_000_000_000)
    let queue = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: progress, mountedSourceIDs: [record.id])
    let detail = try #require(queue.rows[0].runningDetail(progress: progress, timeRemaining: "12 min"))
    #expect(detail.metaLine == "Verifying Shuttle B · 2 of 3 backups · 218 GB")
    #expect(detail.currentFile == "B007C012.mov")
    #expect(detail.timeAndRate == "About 12 min · 557 MB/s")
}
```

Use `OperationProgress`'s real initializer (file `Packages/BitMatchEngine/Sources/BitMatchEngine/Models/OperationProgress.swift`); pass nil for fields not named.

- [ ] **Step 2: Run; expect compile failure**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run; expect PASS**
- [ ] **Step 5: Commit** `git commit -am "Queue rows: running detail with phase, backup index, file and rate"`

### Task 9: The row view, the strip, the header, Remove in the menu

**Files:**
- Modify: `Shared/Views/TransferQueueSection.swift`: `macCollapsedRow` (303-332), `mobileFinishedRow`/`mobileActiveRow` (342-398), `collapsedSummary` (483-510), `compactAction` (512-541), `headerTitle` (158-167), `QueuePauseBanner` (1098-1141), `baseColor`/`borderColor` (785-793), `removeFromList` (881-884)
- Modify: `Shared/Core/Models/QueueSessionPresentation.swift` (`pausedTitle` text, add `removeConfirmation(for:)`)
- Test: `BitMatchTests/QueueSessionPresentationTests.swift` for the strings

**Interfaces:**
- Produces: `QueueSessionPresentation.pausedStripText: String?` = "Paused at <card>. Keep that card until you review it." (replaces `pausedTitle` + `pausedCause` in the banner; keep the old properties for History/menu bar callers).
- Produces: `struct RemoveConfirmation: Equatable { let title: String; let message: String }` and `static func removeConfirmation(for row: QueueSessionRow) -> RemoveConfirmation?`: nil when `row.safetyState.isSafe`; otherwise title "Remove <card> from the queue?", message "It isn't safe to erase yet. Files already copied stay on the backups."
- View layout (both platforms, one `QueueRowContent` view with `ViewThatFits`): line 1 card name `.headline` (Mac: `.system(size: 15, weight: .semibold)` until Tokens lands) with the state label (`Label(row.queueLabel, systemImage: row.queueSymbol)` in `row.statusTint.color`; `.safeToErase` renders as a filled green capsule with dark text) trailing; line 2 `metaLine()` (or `runningDetail.metaLine`) `.callout` secondary, `monospacedDigit`; running rows add line 3 with `currentFile` leading and `timeAndRate` trailing. One trailing button: Review (`.borderedProminent`) for `.review`; Eject (`.bordered`) for `.eject`; Pause for running (existing pause action); then a `Menu("⋯")` holding Skip and continue (paused row only), Remove from queue (destructive, with the confirmation alert), Edit (waiting), Export. Context menu mirrors the Menu.
- Attention edge: `.overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 4) }` only for needsAttention/interrupted; 6 pt red for failed. No green tint on finished rows (`baseColor` returns the plain surface for `.safeToErase`; keep amber/red tints at 0.08 as today).
- Header: `headerTitle` shows "Transfers" and `presentation.tally.queueHeaderText` beside it in `.callout` secondary, with the "safe to erase" count in green and "keep the card" in orange via `Text` concatenation.
- `QueuePauseBanner` becomes a single `Text(pausedStripText)` on `amber.opacity(0.12)` with no buttons; Review/Skip/Remove live on the paused row.
- Accessibility: each row `.accessibilityElement(children: .combine)` with label "<queueLabel>. <card>. <metaLine>" and `.accessibilityAction(named:)` for each menu item and the primary button.

- [ ] **Step 1: Write the failing tests for the two strings**

```swift
@Test func pausedStripAndRemoveConfirmationWording() throws {
    let fixture = try QueuePresentationFixture(); defer { fixture.cleanup() }
    let record = try fixture.record(name: "A7IV_CARD1", state: .issues)
    let queue = QueueSessionPresentation.make(records: [record], sessionIDs: [record.id], progress: nil,
        mountedSourceIDs: [], pausedRecordID: record.id)
    #expect(queue.pausedStripText == "Paused at A7IV_CARD1. Keep that card until you review it.")
    let confirm = try #require(QueueSessionPresentation.removeConfirmation(for: queue.rows[0]))
    #expect(confirm.title == "Remove A7IV_CARD1 from the queue?")
    #expect(confirm.message == "It isn't safe to erase yet. Files already copied stay on the backups.")
}
```

- [ ] **Step 2: Run; expect compile failure**
- [ ] **Step 3: Implement the strings, run, PASS, commit** `git commit -am "Queue: paused strip and remove confirmation wording"`
- [ ] **Step 4: Rebuild the row view** per the Interfaces block. Keep `transferTransitionContext`'s `matchedGeometryEffect` on the card-name `Text` so the composer flight still lands. Keep `FinishedQueueRowExpansion` and `expandedContent` untouched.
- [ ] **Step 5: Verify on all three platforms**

Run: `./test.sh mac-test && ./test.sh ipad-build`. Launch the Mac Debug build with the stress test (Developer › Stress Test (Medium)) and capture a running row, a safe row, and an attention row. Run the iPad scheme in a simulator at iPhone 16 and iPad 13" and capture the same three rows in light and dark. Check VoiceOver reads one element per row on Mac.

- [ ] **Step 6: Commit and open PR C**

```bash
git add Shared/Views/TransferQueueSection.swift Shared/Core/Models/QueueSessionPresentation.swift BitMatchTests
git commit -m "Transfer row: headline, state label, meta grammar, one action plus menu"
```

PR title: "Transfer row: tell cards apart and act from the row". Attach the screenshots.

---

## Not in this plan

Spec steps 3 (native tab strip), 4 (Mac bottom bar), 5 (setup hierarchy and vocabulary on Setup/Check/Master Report/History), 6 (Motion: row-as-progress-bar fill, commit choreography, Motion tokens, responsive delight) and 7 (Tokens) get their own plans once PR C has merged, so they build on the shipped row. The green commit flash and the row fill are step 6, not PR B or C.
