# Failure Reason Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a backup runs out of space, or an exFAT/FAT backup keeps its own hidden `._` companion so the card's AppleDouble file cannot be copied there, the queue row, Review, History and the journal summary say so instead of only "N files failed".

**Architecture:** The engine already attaches a reason to each failed `FileOperationResult.error`, but `TransferCompletion.row(from:)` drops it. Add a bounded, canonical `failureReason` token (never free text, never a path) carried on `ResultRow` and persisted in the journal, the same way `failedOutputMarking` is. The app's presentation layer turns the token into words at the three places that say "N files failed on X", plus the History row text.

**Tech Stack:** Swift 6, BitMatchEngine package (Swift Testing + XCTest), app target `BitMatch` (Swift Testing).

**Spec:** No separate spec. Decided in chat on October 22, 2026: carry a canonical reason, two values for now (`outOfSpace`, `companionConflict`); no engine behaviour change; refusal to overwrite the companion stays (see `AppleDoubleFilesystemMatrixTests`, "Refusal is required; overwriting it is not a fix").

## Global Constraints

- Swift 6 strict concurrency; `ResultRow` and `FileOperationResult` stay `Sendable`.
- Journal compatibility: `failureReason` is optional, encoded only when present (`encodeIfPresent`), decoded with `decodeIfPresent`. Older journals decode unchanged.
- Reason tokens are canonical strings: `"outOfSpace"` and `"companionConflict"`. No error text, no file names, no paths ever enter a row or a summary from this work.
- Vocabulary: "card" and "backup", never "source"/"destination", in any user-facing string added here. Sentence case.
- No competitor names anywhere.
- Test commands: engine `swift test --package-path Packages/BitMatchEngine --filter <Name>`; app full suite only under the lock: `while ! mkdir /tmp/bitmatch-test-lock 2>/dev/null; do sleep 15; done; trap 'rmdir /tmp/bitmatch-test-lock' EXIT; ./test.sh mac-test`; iPad `./test.sh ipad-build`.

## Review Focus

- A failed row whose error carries no reason key must still produce `failureReason == nil` and the existing "N files failed" wording (Task 1 and Task 2 tests cover this).
- A record with failures on two backups keeps the plain count; the reason sentence only appears for one backup whose failed rows all share one reason (Task 2 test).
- Out-of-space rows where a destination later recovers on a new attempt are a new record; nothing here touches resume.
- Decoding a journal row without the key must not throw (Task 1 round-trip test decodes a JSON object that omits the key).
- The companion suffix must appear only for `._` rows (the writer only tags those).

---

### Task 1: Carry the reason from the engine into the journal row

**Files:**
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/Models/Results.swift` (ResultRow, around lines 37–80 and the Codable block around 205–250)
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/EngineProtocols.swift` (FileOperationResult, around lines 123–180)
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/File/DestinationWriter.swift` (`outOfSpaceError()` near line 1069; `reuseConflict(_:relativePath:)` near line 1626)
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/TransferCompletion.swift` (`row(from:destinationRoots:)` line 12; `fileResultsMessage` else-branch near line 450)
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/FailureReasonTests.swift` (create)
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/FanOutTests.swift` (`outOfSpaceDestinationIsPausedWhileOthersFinish`, add one expectation)
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/AppleDoubleFilesystemMatrixTests.swift` (the `else` branch asserting the `._clip.bin` refusal, add one expectation)

**Interfaces:**
- Produces, in `Results.swift`:
  ```swift
  /// Why a copy or verification failed, bounded to tokens the app can word.
  public enum ResultFailureReason: String, Sendable, CaseIterable {
      case outOfSpace
      case companionConflict
      /// NSError userInfo key the writer sets on the errors it classifies.
      public static let userInfoKey = "BitMatchFailureReason"
  }
  ```
- Produces: `ResultRow.failureReason: String?` (new `let`, init parameter `failureReason: String? = nil` placed after `recopyOutcome`), encoded/decoded under CodingKey `failureReason`.
- Produces: `FileOperationResult.failureReason: String?` as a computed property: `(error as NSError?)?.userInfo[ResultFailureReason.userInfoKey] as? String`.
- Produces: `TransferCompletion.row(from:destinationRoots:)` passes `failureReason: result.failureReason`.
- Produces: the journal summary sentence. In the final `else` of `fileResultsMessage`, after `"N files failed"`, append exactly one of these when every failed row (`!isSuccessStatus`) has the same non-nil `failureReason`:
  - `outOfSpace` → `"; a backup ran out of space"`
  - `companionConflict` → `"; the backup keeps its own hidden companion files, so the card's AppleDouble files could not be copied there. Turn on Ignore AppleDouble metadata files"`
  - Example full string: `"3 files failed; a backup ran out of space"`.

- [ ] **Step 1: Write the failing tests** in `FailureReasonTests.swift` (Swift Testing, `@Suite struct FailureReasonTests`):
  - `rowCarriesOutOfSpaceReason`: build a `FileOperationResult(sourceURL: URL(fileURLWithPath: "/card/a.mov"), destinationURL: URL(fileURLWithPath: "/Volumes/T9/a.mov"), success: false, error: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), userInfo: [ResultFailureReason.userInfoKey: ResultFailureReason.outOfSpace.rawValue]), fileSize: 1, verificationResult: nil, processingTime: 0)`; `#expect(TransferCompletion.row(from: result, destinationRoots: [URL(fileURLWithPath: "/Volumes/T9")]).failureReason == "outOfSpace")`.
  - `rowWithoutReasonStaysNil`: same with `error: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))` → `failureReason == nil`.
  - `journalRoundTripKeepsReasonAndToleratesItsAbsence`: encode a `ResultRow(path: "/card/a.mov", status: ResultOutcome.failed.statusText, size: 1, checksum: nil, destination: "T9", failureReason: "companionConflict")` with `JSONEncoder`, decode, `#expect(decoded.failureReason == "companionConflict")`; then decode the JSON string `{"id":"<any UUID>","path":"/card/a.mov","status":"Failed","size":1}` and `#expect(decoded.failureReason == nil)` (use the exact `status` text `ResultOutcome.failed.statusText` produces; check `Results.swift`).
  - `summaryNamesOutOfSpaceWhenEveryFailureSharesIt` and `summaryStaysPlainWhenReasonsDiffer`: exercise the summary through whatever public `TransferCompletion` entry builds `fileResultsMessage` (read lines 380–470 to find it; if it is only reachable via a full `FileOperation`, build the minimal operation the existing `TransferCompletionVerdictTests` build and assert `completionMessage`/summary contains `"a backup ran out of space"` in the first case and does not in the second).
- [ ] **Step 2: Run** `swift test --package-path Packages/BitMatchEngine --filter FailureReasonTests` → FAIL (no `ResultFailureReason`, no `failureReason`).
- [ ] **Step 3: Implement** the enum, the `ResultRow` field (init, CodingKeys, decode, encode with `encodeIfPresent`), the `FileOperationResult.failureReason` computed property, and `row(from:)`.
- [ ] **Step 4: Tag the writer errors.** In `outOfSpaceError()` add `ResultFailureReason.userInfoKey: ResultFailureReason.outOfSpace.rawValue` to `userInfo`. In `reuseConflict(_:relativePath:)`, for the `._` branch, build the `NSError` with the same description plus `ResultFailureReason.userInfoKey: ResultFailureReason.companionConflict.rawValue` (extend `existingDestinationConflictError` with an optional `reason: ResultFailureReason? = nil` parameter rather than duplicating the domain/code).
- [ ] **Step 5: Add the summary suffix** in `TransferCompletion` per the Interfaces block.
- [ ] **Step 6: Extend the two existing tests.** In `FanOutTests.outOfSpaceDestinationIsPausedWhileOthersFinish` add `#expect(failed.allSatisfy { $0.failureReason == ResultFailureReason.outOfSpace.rawValue })`. In `AppleDoubleFilesystemMatrixTests`, inside the `else` branch that asserts `"hidden companion"`, add `XCTAssertEqual(result.failureReason, ResultFailureReason.companionConflict.rawValue)`.
- [ ] **Step 7: Run** `swift test --package-path Packages/BitMatchEngine --filter "FailureReasonTests|FanOutTests|TransferCompletionVerdictTests"` → PASS. The matrix test needs disk images; run `swift test --package-path Packages/BitMatchEngine --filter AppleDoubleFilesystemMatrixTests` once (it is slow, several minutes) → PASS.
- [ ] **Step 8: Commit** `feat(engine): carry a canonical failure reason on result rows`.

### Task 2: Say the reason in the app

**Files:**
- Modify: `Shared/Core/Models/ResultPresentation.swift` (`DestinationResultSummary`, line ~401)
- Modify: `Shared/Core/Models/TransferLibraryPresentation.swift` (`TransferHistoryResultPresentation.statusText`, lines 7–18)
- Modify: `Shared/Core/Models/TransferOutcomePresentation.swift` (`issueReason`, the `.needsAttention` case near lines 592–603)
- Modify: `Shared/Core/Models/QueueSessionPresentation.swift` (`cause(for:state:)`, lines ~618–634)
- Modify: `Shared/Views/Setup/AppleDoubleSelectionView.swift`
- Test: `BitMatchTests/ResultPresentationTests.swift`, `BitMatchTests/TransferLibraryPresentationTests.swift`, `BitMatchTests/TransferOutcomePresentationTests.swift`, `BitMatchTests/QueueSessionPresentationTests.swift`

**Interfaces:**
- Consumes: `ResultRow.failureReason: String?`, `ResultFailureReason` (Task 1).
- Produces, in `ResultPresentation.swift`:
  ```swift
  extension ResultFailureReason {
      /// Suffix for one row in History/Review.
      var rowNote: String            // outOfSpace: "backup out of space"; companionConflict: "the backup keeps its own hidden companion file"
      /// Lead-in for a backup whose failures all share this reason.
      func backupLead(_ name: String) -> String   // outOfSpace: "\(name) ran out of space"; companionConflict: "\(name) keeps its own hidden companion files"
  }
  extension DestinationResultSummary {
      /// Non-nil only when issueCount > 0 and every failing row carries the same known reason.
      var sharedFailureReason: ResultFailureReason?
  }
  ```
- Produces: `TransferHistoryResultPresentation.statusText` appends `" · " + reason.rowNote` for a non-success row with a known reason, after the existing marking/re-copy notes (order: status, marking note, re-copy note, reason note).
- Produces: the one-backup cause line in both `TransferOutcomePresentation.issueReason` (`.needsAttention`, single summary) and `QueueSessionPresentation.cause` becomes `"\(lead) · \(files)"` when `sharedFailureReason` is non-nil, e.g. `"BMMID ran out of space · 3 files failed"`, `"T9 keeps its own hidden companion files · 26 files failed"`; otherwise unchanged `"\(files) on \(name)"`.
- Produces: in `AppleDoubleSelectionView`, when `review.enabled == false`, a second footnote `Text` under the existing one: `"exFAT and FAT backups keep their own hidden companion files, so the card's ._ files can't be copied there and will be reported as failed."` (`.font(.footnote).foregroundStyle(.secondary)`).

- [ ] **Step 1: Write the failing tests** (Swift Testing, `#expect`), using each file's existing fixtures:
  - `ResultPresentationTests`: `sharedFailureReasonRequiresEveryFailureToAgree` — two failed rows both `outOfSpace` → `.outOfSpace`; one `outOfSpace` + one nil → nil; one `outOfSpace` + one `companionConflict` → nil; no failures → nil.
  - `TransferLibraryPresentationTests`: `failureReasonIsSurfacedInHistoryWords` — failed row with `failureReason: "outOfSpace"` → text ends with `" · backup out of space"`; `._` row with `companionConflict` → ends with `" · the backup keeps its own hidden companion file"`; failed row with nil → unchanged.
  - `TransferOutcomePresentationTests`: `oneBackupOutOfSpaceIsNamedInTheIssueReason` — rows: 3 failed `outOfSpace` on `/Volumes/BMMID/...`, 3 verified on `/Volumes/WheeDrive/...`, destinations both roots → the issue reason equals `"BMMID ran out of space · 3 files failed"`; a second case with failures on both backups → `"6 files failed"` (confirm the exact current wording by reading `issueReason` first). Find the public entry the file's other tests use (`make(...)` helpers at lines 31 and 62).
  - `QueueSessionPresentationTests`: `causeNamesTheBackupThatRanOutOfSpace` — extend `QueuePresentationFixture.record(...)` with a `results: [ResultRow]` overload or a `failureReason:` parameter so the record's `results` carry `destination`/`destinationPath` under one destination root and `failureReason: "outOfSpace"`; `#expect(row.cause == "BMMID ran out of space · 3 files failed")` (confirm the row property name that exposes `cause`).
- [ ] **Step 2: Run** the four suites: `xcodebuild test -scheme BitMatch -destination 'platform=macOS' -only-testing:BitMatchTests/ResultPresentationTests -only-testing:BitMatchTests/TransferLibraryPresentationTests -only-testing:BitMatchTests/TransferOutcomePresentationTests -only-testing:BitMatchTests/QueueSessionPresentationTests` (check `test.sh` for the exact invocation it uses and copy its flags; if `-only-testing` runs 0 tests for Swift Testing suites, run the full suite under the lock instead) → FAIL.
- [ ] **Step 3: Implement** the extensions, the three wording sites and the footnote.
- [ ] **Step 4: Run** the same tests → PASS. Then full `./test.sh mac-test` under the lock and `./test.sh ipad-build` → both green.
- [ ] **Step 5: Commit** `feat: say why a backup's files failed in the row, Review and History`.

### Task 3: Record it

**Files:**
- Modify: `CHANGELOG.md` (new `## [Unreleased]` section above 0.2.11 if absent)
- Modify: `docs/TODO.md` (the "Say why a backup ran out of space" item under Evidence and History → `[x]` with one sentence pointing at this plan; add "exFAT companion conflict is now worded in the row, Review and Settings" to it)

- [ ] **Step 1:** Changelog bullets: "History, Review and the queue row now say when a backup ran out of space, or when an exFAT or FAT backup kept its own hidden companion file so the card's AppleDouble file could not be copied there. The Ignore AppleDouble setting explains this when it is off." Keep to two bullets.
- [ ] **Step 2: Commit** `docs: record the failure reason wording`.
