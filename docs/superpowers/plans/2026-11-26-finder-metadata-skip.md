# Skip Finder `.DS_Store` files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A card whose only non-copied entries are proven Finder `.DS_Store` files is still marked safe to erase; every skip is visible; nothing real can hide behind the name.

**Architecture:** A header-checking classifier in the engine (mirroring `AppleDoubleSelection`) proves each `.DS_Store` at Start and again at the final gate; the pipeline writes one `skippedFinderMetadata` row per destination and copies nothing; one engine predicate in `TransferCompletion` decides whether skipped rows are proven and complete, and every verdict, journal, queue and manifest site routes through it. The Shared layer adds the setting, wording and report lines.

**Tech Stack:** Swift 6, Swift Testing (engine), XCTest where the neighbouring suite uses it, `./test.sh` jobs.

**Spec:** `docs/superpowers/specs/2026-11-26-finder-metadata-skip-design.md`

## Global Constraints

- Never a false "safe to erase": a skipped row counts toward coverage only when its path is in the operation's engine-proven set, there is exactly one such row per path per destination, and selected plus skipped paths equal the complete manifest.
- The AppleDouble rule is unchanged: any `excludedAppleDouble` row means never safe to erase, even alongside skips.
- Status text for the new outcome is exactly `⏭ Skipped Finder view file (.DS_Store)` and never contains `✅`.
- Setting off (`skipFinderViewFiles == false`) is byte-for-byte today's behaviour.
- The word "excluded" stays reserved for AppleDouble ("the whole card is not backed up"); skips use "skipped".
- No `<ignore>` element is written into ASC MHL manifests.
- Engine code cannot import Shared. Every exhaustive `switch` over `ResultOutcome` and `ResultFailureReason` must compile on Mac and iPad.
- Commit attribution lines: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01L5km8zcV6hJ3EyrgtjK6eh`.

## Review Focus

1. A hand-edited History row given the skipped status text, with no proven path, must not make a record safe (Task 4, Task 5 tests).
2. A `.DS_Store` on the card replaced mid-run by a non-Finder file must fail closed as `sourceUnstable` at the final gate (Task 3 test).
3. A record written by this version read by the 0.2.14 code path must not be safe: pin that `isSuccessStatus` is false and `isInSelectedPlan` is true for the new status under the old rule (Task 2 test documents the downgrade reading).
4. Finder writing a `.DS_Store` on a destination before or after the copy must not fail the run (Task 3 test, the issue-93 regression).
5. A run with both an AppleDouble exclusion and skips must never be safe but must still let the expected-exclusion queue advance (Task 5 test).

---

### Task 1: The classifier

**Files:**
- Create: `Packages/BitMatchEngine/Sources/BitMatchEngine/File/FinderMetadataSelection.swift`
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/FinderMetadataSelectionTests.swift`

**Interfaces:**
- Consumes: `FileEntry` (`relativePath`, `url`, `size`), `CardSource.enumerateRegularFiles(base:checkCancellation:)`, `FileOperationError.unsafeOperation`.
- Produces:
  - `public enum FinderMetadataSelection`
  - `public static func skipped(in manifest: [FileEntry], checkCancellation: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> [FileEntry]` — entries named exactly `.DS_Store` that pass `isFinderViewFile`, sorted by `relativePath`.
  - `static func isFinderViewFile(fd: Int32, size: Int64, checkCancellation: ...) throws -> Bool` — the bounded parser; the caller owns the descriptor.
  - `public static let maximumSize: Int64 = 64 * 1024 * 1024`, `public static let minimumSize: Int64 = 36`.

- [ ] **Step 1: Write the failing classifier tests**

```swift
@Suite struct FinderMetadataSelectionTests {
    // helpers: makeTree() -> URL temp dir; bud1(size:) -> Data: 00 00 00 01, "Bud1",
    //   offset=0x800 (big-endian UInt32), size=0x800, offset again, 16 zero bytes, zero-padded to `size`.
    @Test func aFinderViewFileAtTheRootAndNestedIsSkipped()        // two Bud1 files at root and in "A/B/"; skipped == both relative paths, sorted
    @Test func randomBytesEmptyAndShortFilesAreOrdinary()           // random 6148 B; 0 B; 20 B -> skipped is empty
    @Test func inconsistentOffsetsOrOversizeAreOrdinary()           // offset1 != offset2; 4+offset+size > fileSize; size2 == 0; file of maximumSize+1 with valid header
    @Test func otherSpellingsAreOrdinary()                          // ".ds_store", ".DS_Store " (trailing space), NFD-decomposed name
    @Test func aDirectoryNamedDSStoreIsNotClassifiedAndItsFileIsOrdinary() // dir ".DS_Store" with "x.txt" inside: skipped is empty
    @Test func anAppleDoubleFileIsUntouched()                       // "._clip.mov" valid AppleDouble -> skipped is empty
    @Test func aFileThatChangesWhileReadingThrows()                 // truncate between fstat and read via the checkCancellation hook -> throws FileOperationError
}
```

- [ ] **Step 2: Run to verify they fail** — `cd Packages/BitMatchEngine && arch -arm64 swift test --build-system native --no-parallel --filter FinderMetadataSelectionTests` — expected: compile error, type not found.

- [ ] **Step 3: Implement `FinderMetadataSelection`** mirroring `AppleDoubleSelection.companions` and `isMetadataOnlyCompanion` (fstat before/after guard with the same "changed while reviewing" error, `pread` loop with EINTR retry). Header rule: bytes 0–3 == `00 00 00 01`; bytes 4–7 == `Bud1`; `offset1` (8–11) == `offset2` (16–19); `rootSize` (12–15) > 0; `4 + offset1 + rootSize <= size`; `minimumSize <= size <= maximumSize`. Name check is byte-exact on `lastPathComponent` (`== ".DS_Store"`, no normalisation). Only regular files (`lstat` `S_IFREG`).

- [ ] **Step 4: Run to verify they pass.**

- [ ] **Step 5: Commit** — `feat: classify Finder view files by their Bud1 header`.

---

### Task 2: The status, the row flag, the setting and the record field

**Files:**
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/Models/Results.swift` (`ResultOutcome`, `FileOperationResult`, `ResultRow.isInSelectedPlan`)
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/Models/CameraLabelSettings.swift`
- Modify: the type that holds `reviewedAppleDoubleExclusionPaths` (grep; `CompletedFileOperation` or similar) and `LocalTransferRecord` in `TransferJournal.swift` (grep `reviewedAppleDoubleExclusionPaths` for the persisted twin)
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/TransferCompletion.swift` `row(from:)` so the flag maps to the new status
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/FinderMetadataRowTests.swift`

**Interfaces:**
- Produces:
  - `ResultOutcome.skippedFinderMetadata`, status text `⏭ Skipped Finder view file (.DS_Store)`; `ResultOutcome(statusText:)` round-trips it.
  - `FileOperationResult.skippedFinderMetadata: Bool = false`.
  - `ResultRow.isSkippedFinderMetadata: Bool` (`ResultOutcome(statusText: status) == .skippedFinderMetadata`); `isInSelectedPlan` is false for it; `isSuccessStatus` and `isVerifiedStatus` stay false.
  - `CameraLabelSettings.skipFinderViewFiles: Bool = true`, decoded with `decodeIfPresent ?? true` (match the file's existing Codable style).
  - `skippedFinderMetadataPaths: [String]?` on the completed-operation type and on `LocalTransferRecord` (optional Codable, nil in old records).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func theSkippedStatusRoundTripsAndIsNeverASuccess()   // text exact; !isSuccessStatus; !isVerifiedStatus; !isInSelectedPlan; isSkippedFinderMetadata
@Test func aResultFlaggedSkippedBecomesTheSkippedRow()       // FileOperationResult(skippedFinderMetadata: true) -> row(from:) status == text, checksum nil
@Test func theSettingDefaultsOnAndDecodesWhenAbsent()        // JSON without the key -> true; with false -> false
@Test func oldRecordsDecodeWithNilSkippedPaths()             // a LocalTransferRecord JSON fixture without the key decodes; new encode includes the key
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** Every exhaustive `switch` over `ResultOutcome` in the engine gets the new case (grep `case .excludedAppleDouble` under `Packages/`); wording follows the neighbouring case and uses "skipped", never "excluded".
- [ ] **Step 4: Run the engine suites that touch Results and Journal:** `--filter "FinderMetadataRow|Results|TransferJournal|ResultRow"`; expected pass.
- [ ] **Step 5: Commit** — `feat: skipped Finder view file status, row flag, setting and record field`.

---

### Task 3: The pipeline skips, records and rechecks

**Files:**
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/TransferPipeline.swift` (Start classification next to `AppleDoubleSelection.excluded` ~:732; exclusion rows loop ~:779; final gate ~:1640–1690 and the source-identity gate that produces `sourceUnstable`)
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/FinderMetadataPipelineTests.swift`

**Interfaces:**
- Consumes: Task 1 `FinderMetadataSelection.skipped(in:)`; Task 2 flag, setting and `skippedFinderMetadataPaths`.
- Produces: operations whose `results` contain one `skippedFinderMetadata` row per destination per proven path, whose `sourceManifest` still lists the complete card, and whose `skippedFinderMetadataPaths` is the proven set (nil when the setting is off).

- [ ] **Step 1: Write the failing pipeline tests** (use the `TransferConcurrencyPipelineTests` tree helpers as a model; `bud1(size:)` from Task 1 tests moved to a shared test helper)

```swift
@Test func aFinderViewFileIsSkippedListedPerDestinationAndNotWritten()   // 2 clips + Bud1 .DS_Store, 2 destinations, standard: 2 skipped rows (one per dest), file absent on both destinations, selected rows all verified, skippedFinderMetadataPaths == [".DS_Store"]
@Test func settingOffCopiesAndVerifiesTheFileAsToday()                   // skipFinderViewFiles=false: row verified, file present, skippedFinderMetadataPaths == nil
@Test func aNonFinderDSStoreIsCopiedAndVerified()                        // random bytes named .DS_Store: verified row, present on destinations
@Test func aFinderToFinderRewriteOnTheCardMidRunIsNotAFailure()          // onFileResult after first clip: overwrite the card's .DS_Store with another valid Bud1 of different size -> run completes, no sourceUnstable
@Test func aFinderFileReplacedByAnOrdinaryFileMidRunFailsClosed()        // overwrite with random bytes -> final gate records sourceUnstable; verdict not safe (assert via TransferCompletion.verdict or the gate row)
@Test func finderWritingDSStoreOnADestinationBeforeOrAfterCopyIsNotAFailure() // FanOutHooks.beforePublish for clip 1: write a Bud1 .DS_Store into the destination folder; and onFileResult after verification: rewrite it -> run completes, all selected rows verified (issue 93 regression)
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** At Start, after `excluded`: `let skipped = operation.settings.skipFinderViewFiles ? try FinderMetadataSelection.skipped(in: completeSourceManifest) : []`; remove skipped paths from `sourceManifest` (same pattern as excluded) and from `manifestBytes`; log a new `SharedLogger.transferEvent(.finderMetadataSkipped, code: skipped.count)` (add the event case). In the per-destination pre-copy loop, write a `FileOperationResult` per skipped entry with `skippedFinderMetadata = true`, `success: false`, `error: nil`, `fileSize: entry.size`. The `selectedResults` filter at the final gate excludes skipped rows like excluded ones; `totalFiles` already counts only `sourceManifest`. At the final source gate (where the completion re-scan compares the card to the manifest), for each skipped path still present re-run `isFinderViewFile`; a path that no longer passes becomes a `sourceUnstable` gate failure for every destination's skipped row; a path that is absent or a new Bud1 `.DS_Store` is not a failure. Set `completed.skippedFinderMetadataPaths = skipped.map(\.relativePath)` (nil when the setting is off).
- [ ] **Step 4: Run** `--filter "FinderMetadata|TransferConcurrencyPipeline|FanOutTests"`; expected pass.
- [ ] **Step 5: Commit** — `feat: the pipeline skips proven Finder view files, records a row per backup and rechecks them at the final gate`.

---

### Task 4: One predicate decides; verdict, coverage and the manifest use it

**Files:**
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/TransferCompletion.swift` (`verdict`, `coverageIssues`, `ascmhlPlan`, messages)
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/FinderMetadataVerdictTests.swift`

**Interfaces:**
- Produces:
  - `public static func finderMetadataSkipsProven(rows: [ResultRow], provenPaths: [String]?, destinations: [URL], source: URL, settings: CameraLabelSettings) -> Bool` — true only when: every `isSkippedFinderMetadata` row's path is in `provenPaths` (relative to `source`), each proven path has exactly one skipped row per destination (matched by `destinationPath` under each resolved root, as `ExpectedExclusionQueuePolicy` does), and there are no skipped rows outside `provenPaths`. When `provenPaths` is nil and there are no skipped rows, true.
  - `verdict(...)` gains `skippedFinderMetadataPaths: [String]?` and applies rules 1–5 of the spec: skipped rows are neither issues nor selected; selected coverage is computed with skipped paths removed from `sourceFiles`; the result is safe only if the predicate is true and the remaining rules hold; `excludedAppleDouble` still forces not safe. Messages: "All files copied and verified; N Finder view files (.DS_Store) skipped" on success; an unproven or duplicated skipped row reads "Skipped-file records do not match this run; keep the card".
  - `ascmhlPlan` filters skipped rows out of `results` and skipped paths out of `sourceFiles` (same shape as AppleDouble); the plan gains `skippedFinderMetadataPaths: [String]?`.

- [ ] **Step 1: Write the failing tests** (build `ResultRow`s directly, as the existing TransferCompletion tests do)

```swift
@Test func provenSkipsWithEverythingElseVerifiedAreSafe()          // 2 dests, 2 clips verified each, 1 skipped row each, proven [".DS_Store"] -> safe; message contains "1 Finder view file (.DS_Store) skipped"
@Test func aSkippedRowOutsideTheProvenSetIsNeverSafe()             // provenPaths [] or nil with a skipped row -> not safe; message "Skipped-file records do not match this run"
@Test func aMissingOrDuplicateSkippedRowIsNeverSafe()              // one destination lacks the row; or has two -> not safe
@Test func aFailedClipElsewhereStillBlocksSafety()                 // skipped proven but clip failed on dest B -> not safe
@Test func appleDoubleExclusionStillWinsOverSkips()                // excludedAppleDouble row + proven skips -> not safe; message keeps "Keep the source: the whole card is not backed up"
@Test func theManifestPlanLeavesSkippedFilesOutOfHashesAndWritesNoIgnore() // ascmhlPlan jobs' files exclude .DS_Store; generated manifest XML has no "<ignore"
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** Keep the single predicate as the only place the rules live; `coverageIssues` wording: skipped rows are reported as "N Finder view files (.DS_Store) skipped: not card content; Finder recreates them".
- [ ] **Step 4: Run** `--filter "FinderMetadataVerdict|TransferCompletion|ASCMHL"`; expected pass.
- [ ] **Step 5: Commit** — `feat: one predicate proves Finder skips; verdict, coverage and the ASC MHL plan use it`.

---

### Task 5: Journal, queue policy and scope evidence

**Files:**
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/TransferJournal.swift` (`hasCompleteVerifiedResults`, `hasCompletePlannedResults`, `matchingVerifiedRecord`)
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/ExpectedExclusionQueuePolicy.swift`
- Modify: `Packages/BitMatchEngine/Sources/BitMatchEngine/Evidence/VerificationScopeEvidence.swift`
- Test: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/FinderMetadataJournalTests.swift`

**Interfaces:**
- Consumes: Task 4 predicate; `LocalTransferRecord.skippedFinderMetadataPaths`.
- Produces: `hasCompleteVerifiedResults` treats skipped rows as complete only when the predicate holds for the record (rows, `skippedFinderMetadataPaths`, `destinations`, `source`, `settings`); `hasCompletePlannedResults` ignores skipped rows (they are not in the plan); `ExpectedExclusionQueuePolicy` accepts skipped rows under the same proof so a mixed run can still advance the queue; `VerificationScopeEvidence` gains `recordedSkippedFinderMetadata: Int` and a line "N Finder view files skipped (not card content)".

- [ ] **Step 1: Write the failing tests**

```swift
@Test func aRecordWithProvenSkipsMatchesAsVerified()                 // matchingVerifiedRecord finds it
@Test func aRecordWithAnUnprovenSkippedRowDoesNotMatch()             // hand-edited status text, nil proven paths -> nil
@Test func aZeroPointTwoFixtureKeepsItsVerdict()                     // existing fixture JSON (no key) still matches as before
@Test func mixedAppleDoubleAndSkipsStillQualifiesTheQueue()          // ExpectedExclusionQueuePolicy qualification non-nil
@Test func scopeEvidenceCountsSkips()                                // recordedSkippedFinderMetadata == 2, line present, "whole card" wording absent
```

- [ ] **Step 2: Run to verify they fail.**  - [ ] **Step 3: Implement.**  - [ ] **Step 4: Run** `--filter "FinderMetadataJournal|TransferJournal|ExpectedExclusion|VerificationScope"`.
- [ ] **Step 5: Commit** — `feat: journal, queue policy and scope evidence accept proven Finder skips`.

---

### Task 6: Settings, wording and reports in the apps

**Files:**
- Modify: `Shared/Core/Models/GeneralSettings.swift` (UserDefaults key `BitMatchSkipFinderViewFiles`, default true, label `Skip Finder view files (.DS_Store)`, footnote "Finder writes .DS_Store when a folder is browsed; it holds view settings, not footage. Skipped files are listed in the report and do not block the safe-to-erase verdict."), `Shared/Core/Models/PortableTransferSettings.swift` (key `skipFinderViewFiles`, `decodeIfPresent ?? true`, `schemaVersion` + 1, diff line "Skip Finder view files"), `Shared/Core/Services/TransferSettingsImport.swift`, `Shared/Core/Services/CopyVerifyExecutor.swift` (pass the setting into `CameraLabelSettings` and `skippedFinderMetadataPaths` into verdict/plan calls), `Shared/Core/Models/ResultStatusPresentation.swift`, `ResultPresentation.swift`, `TransferOutcomePresentation.swift`, `ReportSummary.swift`, `QueueSessionPresentation.swift`, `TransferLibraryPresentation.swift`, `PhotographerJobModels.swift`, `Shared/Core/Services/ReportExporter.swift` (CSV/JSON/PDF row + summary line), `Shared/Core/Remote/RemoteCommandExecutor.swift` and `RemoteSnapshotBuilder.swift` (status mapping and the settings patch), the Settings view that hosts the AppleDouble control (grep `ignoreAppleDouble` in `Shared/Views`), iOS equivalent.
- Test: `BitMatchTests/FinderMetadataPresentationTests.swift`, additions to `GeneralSettingsTests.swift` and the portable-settings tests.

**Interfaces:**
- Consumes: Tasks 2, 4, 5.
- Produces: every `switch` over `ResultOutcome` in Shared handles `.skippedFinderMetadata` (icon `forward.end`, tint secondary, label "Skipped Finder view file"); the setting round-trips; reports show the row and one summary line; no "excluded"/"whole card" wording for skips.

- [ ] **Step 1: Write the failing tests** (status presentation; outcome text; CSV/JSON/PDF contain the row and summary line; portable settings with and without the key; GeneralSettings default and persistence; a RemoteSnapshot carries the setting).
- [ ] **Step 2: Run** `./test.sh mac-build` to see the exhaustive-switch errors, then the tests to see them fail.
- [ ] **Step 3: Implement.**  - [ ] **Step 4: Run** `./test.sh mac-test` and `./test.sh ipad-build`; expected pass.
- [ ] **Step 5: Commit** — `feat: Skip Finder view files setting, wording and report lines`.

---

### Task 7: Notes and the reference check

**Files:**
- Modify: `CHANGELOG.md` (Unreleased bullet), `docs/THESIS.md` (promise notes: what a skip is and is not), `ARCHITECTURE.md` (one paragraph beside the AppleDouble exclusion), `docs/TRANSFER_MATRIX.md` (if a matrix job gains a `.DS_Store` fixture)
- Verify: the pinned ASC MHL reference verifier passes on a history generated for a run with a skipped `.DS_Store` (grep `validate_reference` under `Scripts/`; run it against a temp destination that has a real `.DS_Store` left behind by Finder, which the manifest does not list).

- [ ] **Step 1: Run the reference check and record the command and result in the ledger.**
- [ ] **Step 2: Write the notes.**
- [ ] **Step 3: Commit** — `docs: Finder view files are skipped and listed; the reference verifier passes`.
