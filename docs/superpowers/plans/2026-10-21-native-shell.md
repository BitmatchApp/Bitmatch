# Native Shell Implementation Plan (spec steps 3 and 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the Mac tab strip visible everywhere and give the Mac the same bottom action bar the iPad and iPhone already have, with one readiness sentence and one primary button per tab.

**Architecture:** A new presentation struct, `WorkflowActionBarPresentation`, maps the three existing readiness models (Setup start, Compare, Master Report) to one shape: sentence, button title, symbol, enabled. A Mac-only `MacWorkflowActionBar` view renders it in a `safeAreaInset(edge: .bottom)` on the main scroll view. The inline primary buttons on the three screens are hidden on Mac through the existing `showsInlineStart` pattern. The composer-to-queue flight and the launch-height fit are adjusted because the bar sits outside the scroll content.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, scheme `BitMatch`, tests in `BitMatchTests`.

**Spec:** `docs/superpowers/specs/2026-10-21-visual-polish-design.md`, steps 3 and 4, and "Constraints from the code" (the tab strip is already a native segmented Picker; iPad and iPhone already have the bar via `safeAreaInset`; `SetupStartControl(usesBottomBar:)` exists; the Mac is forced dark).

## Global Constraints

- The Mac tab strip stays a native segmented `Picker` in the principal toolbar slot, text-only segments, width `HeaderPresentationPolicy.modePickerWidth` (390). No custom styling added.
- No visible page titles. The window title (for Mission Control and VoiceOver) is the tab name, or "History".
- Vocabulary in new strings: card and backup, never source and destination. Sentence case. Existing readiness strings are reused verbatim in this plan; rewording them is spec step 5, not this plan.
- Green only for `.safeToErase`. Blue is "next".
- No new platform branch beyond `#if os(macOS)` for the Mac bar view and shell; shared screens take a flag, not a platform check.
- iPad and iPhone behaviour unchanged. Their `MobileTransferActionBar` stays.
- No competitor names anywhere in the diff.
- Before every commit: `./test.sh mac-test`. Before the PR: `./test.sh mac-test && ./test.sh ipad-build`.

Single suite: `xcodebuild test -project BitMatch.xcodeproj -scheme BitMatch -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:BitMatchTests/<SuiteName> 2>&1 | grep -E "Test Suite|passed|failed|error:" | tail -20`

## Review Focus

1. Switching tabs while History is showing closes History and shows that tab; the strip never disappears. Test in Task 1.
2. The bar's button is disabled, not grey-tinted, when the screen is not ready; Return does nothing then. Test in Task 2 (presentation) and Task 3 (view wiring).
3. The composer flight still lands on the new queue row with the bar present. Verified by the live check in Task 3.
4. The window's launch fit includes the bar height so the Start button is never clipped at first launch. Test in Task 3.
5. iPad and iPhone show no second bar. Verified by `ipad-build` plus a simulator screenshot in Task 3.

---

Branch: `feat/native-shell` (from main).

### Task 1: The tab strip stays visible in History; window title names the tab

**Files:**
- Modify: `BitMatch/App/ContentView.swift:370-416` (`mainToolbar`), `:639-642` (`closeHistory`), `:722-726` (`updateWindowTitle`)
- Modify: `BitMatch/Views/HeaderPresentationPolicy.swift`
- Test: `BitMatchTests/HeaderPresentationPolicyTests.swift`

**Interfaces:**
- Produces: `static func windowTitle(mode: AppMode, showingHistory: Bool) -> String` on `HeaderPresentationPolicy`, returning "History" when showing history, else `mode.rawValue`.
- Produces: `static func modeSelectionClosesHistory(showingHistory: Bool) -> Bool` returning `showingHistory` (a documented rule, so the toolbar's picker setter calls `closeHistory()` before `switchMode`).
- The principal picker is rendered in both branches of `mainToolbar`; the back button stays in `.navigation` placement only while showing history.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func windowTitleNamesTheTabOrHistory() {
    #expect(HeaderPresentationPolicy.windowTitle(mode: .copyAndVerify, showingHistory: false) == "Copy & Verify")
    #expect(HeaderPresentationPolicy.windowTitle(mode: .compareFolders, showingHistory: false) == "Check")
    #expect(HeaderPresentationPolicy.windowTitle(mode: .masterReport, showingHistory: true) == "History")
}
@Test func pickingATabWhileInHistoryLeavesHistory() {
    #expect(HeaderPresentationPolicy.modeSelectionClosesHistory(showingHistory: true))
    #expect(!HeaderPresentationPolicy.modeSelectionClosesHistory(showingHistory: false))
}
```

- [ ] **Step 2: Run `HeaderPresentationPolicyTests`; expect compile failure**
- [ ] **Step 3: Implement.** Add the two statics. In `mainToolbar`, hoist the principal `ToolbarItem` out of the `else` so it renders always; keep the back button `ToolbarItem(placement: .navigation)` inside `if showingTransfers`. In the picker's `set:` closure call `if HeaderPresentationPolicy.modeSelectionClosesHistory(showingHistory: showingTransfers) { closeHistory() }` before `coordinator.switchMode(to:)`. In `updateWindowTitle`, set `hostingWindow.title = HeaderPresentationPolicy.windowTitle(mode: coordinator.currentMode, showingHistory: showingTransfers)`; keep `titleVisibility` as today (visible only for History). Add `.onChange(of: coordinator.currentMode)` to call `updateWindowTitle()` where `showingTransfers` already triggers it (~line 746).
- [ ] **Step 4: Run the suite and `./test.sh mac-test`; expect PASS**
- [ ] **Step 5: Commit** `git commit -am "Mac: tab strip stays visible in History; window title names the tab"`

### Task 2: One action-bar presentation for the three tabs

**Files:**
- Create: `Shared/Core/Models/WorkflowActionBarPresentation.swift`
- Test: `BitMatchTests/WorkflowActionBarPresentationTests.swift`

**Interfaces:**
- Produces:
```swift
struct WorkflowActionBarPresentation: Equatable, Sendable {
    let sentence: String?      // what is missing, or the ready line; nil when nothing to say
    let buttonTitle: String    // "Start", "Start 3 transfers", "Start project transfer", "Check", "Scan"
    let symbol: String         // start.symbol / "arrow.left.arrow.right" / "doc.richtext"
    let isEnabled: Bool
    static func make(start: StartButtonPresentation) -> Self
    static func make(compare: ComparePresentation) -> Self
    static func make(master: MasterReportPresentation) -> Self
}
```
- Mapping rules:
  - start: `sentence = start.blocker ?? start.readyLine`; `buttonTitle = start.title`; `symbol = start.symbol`; `isEnabled = start.canStart`.
  - compare: when `compare.readiness.canStart`, `sentence = compare.blockMessage` (nil when none), `buttonTitle = compare.actionTitle` ("Compare folders", "Check saved checksums", "Compare again", "Check again" as today); otherwise `sentence = compare.blockMessage ?? (compare.actionTitle + ".")` (so "Choose a folder or drive." reads as a sentence), `buttonTitle = "Check"`, `isEnabled = false`. `symbol` = "arrow.left.arrow.right" when enabled, "arrow.up" when the next step is choosing a folder.
  - master: when `canGenerate`, `sentence = nil`, `buttonTitle = master.actionTitle` ("Create Master Report"); otherwise `sentence = master.actionTitle + "."` ("Choose a drive to scan.", "Scanning…" stays without a period when it ends in "…"), `buttonTitle = "Scan"`, `isEnabled = false`. `symbol` = "doc.richtext" when enabled, "arrow.up" when the next step is choosing a location.
  - A sentence never ends in two periods; a title ending in "…" gets none added.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func startMapsBlockerThenReadyLine() {
    let blocked = StartButtonPresentation(/* use the SetupPresentationTests helper that builds a start with blocker "Choose a source to start" */)
    let bar = WorkflowActionBarPresentation.make(start: blocked)
    #expect(bar.sentence == blocked.blocker && bar.buttonTitle == blocked.title && !bar.isEnabled)
}
@Test func compareBlockedUsesActionTitleAsSentenceAndCheckAsButton() {
    let p = /* ComparePresentationTests helper for readiness .needsLeft */
    let bar = WorkflowActionBarPresentation.make(compare: p)
    #expect(bar.sentence == "Choose a folder or drive." && bar.buttonTitle == "Check" && !bar.isEnabled && bar.symbol == "arrow.up")
}
@Test func masterBlockedAndReady() {
    let blocked = MasterReportPresentation.make(/* hasLocation false */)
    #expect(WorkflowActionBarPresentation.make(master: blocked).sentence == "Choose a drive to scan.")
    #expect(WorkflowActionBarPresentation.make(master: blocked).buttonTitle == "Scan")
    let scanning = MasterReportPresentation.make(/* isScanning true */)
    #expect(WorkflowActionBarPresentation.make(master: scanning).sentence == "Scanning…")
    let ready = MasterReportPresentation.make(/* ready */)
    #expect(WorkflowActionBarPresentation.make(master: ready).buttonTitle == "Create Master Report" && WorkflowActionBarPresentation.make(master: ready).isEnabled)
}
```
Build the inputs with the factories the existing `SetupPresentationTests`, `ComparePresentationTests` and `MasterReportModelTests` already use; do not add new fixtures.

- [ ] **Step 2: Run; expect compile failure**
- [ ] **Step 3: Implement per the mapping rules**
- [ ] **Step 4: Run the suite; PASS; `./test.sh mac-test`**
- [ ] **Step 5: Commit** `git commit -am "Add WorkflowActionBarPresentation for the three tabs"`

### Task 3: The Mac bottom bar

**Files:**
- Create: `BitMatch/Views/MacWorkflowActionBar.swift`
- Modify: `BitMatch/App/ContentView.swift` (`mainScrollView` ~239-270, the height fit ~660-670 and the preference handlers ~730-740)
- Modify: `Shared/Views/Setup/SetupScreen.swift:343-375` (`SetupStartControl`: remove the `.tint(start.canStart ? Color.accentColor : Color.gray)` line), `:295` neighbourhood (`showsInlineStart` already exists; the Mac shell passes `false`)
- Modify: `Shared/Views/Compare/CompareScreen.swift:217-232` and `Shared/Views/MasterReport/MasterReportScreen.swift:396-412` (add a `showsInlineAction: Bool = true` init parameter; when false the inline button is not rendered; remove the `.tint(... Color.gray)` lines)
- Modify: `BitMatch/Views/WindowPresentationPolicy.swift` or the height policy file: add `MacMeasuredContentHeight.combined(scrollable:notice:actionBar:) -> CGFloat` (pure sum, floored at 0 per part)
- Test: `BitMatchTests/MacWindowHeightPolicyTests.swift`

**Interfaces:**
- `MacWorkflowActionBar(presentation: WorkflowActionBarPresentation, action: @escaping () -> Void)`: `HStack` with the sentence on the left (`.callout`, `.secondary`, up to two lines) and a `Button(action:)` with `Label(buttonTitle, systemImage: symbol)` on the right, `.buttonStyle(.borderedProminent)`, `.controlSize(.large)`, `.disabled(!presentation.isEnabled)`, `.keyboardShortcut(.defaultAction)`; height 56; `.background(.bar)` with a top `Divider()`; horizontal padding 24. No grey tint anywhere.
- `ContentView` attaches `.safeAreaInset(edge: .bottom, spacing: 0) { if !showingTransfers { MacWorkflowActionBar(...) } }` to `mainScrollView`, choosing the presentation by `coordinator.currentMode` (`SetupPresentation.make(coordinator:).start`, `ComparePresentation.make(coordinator:)`, the master-report model's presentation) and the action by the same existing action the inline buttons call today (`setupActions.start` equivalent, `actions.compare`, `generate`).
- The bar measures its height into a new `MacActionBarHeightKey` preference; the launch fit uses `MacMeasuredContentHeight.combined(scrollable: measuredScrollableContentHeight, notice: measuredNoticeHeight, actionBar: measuredActionBarHeight)` in place of the sum at ~line 668.
- The flight: `QueueFlightSpace` and the frame preferences stay on the scroll content; the bar is outside them, so the flight card's coordinate space is unchanged. The `.overlay(alignment: .topLeading) { queueFlightCard }` stays on the scroll content, not on the inset.

- [ ] **Step 1: Write the failing test**

```swift
@Test func launchFitIncludesTheActionBar() {
    #expect(MacMeasuredContentHeight.combined(scrollable: 612, notice: 0, actionBar: 56) == 668)
    #expect(MacMeasuredContentHeight.combined(scrollable: 612, notice: 40, actionBar: 0) == 652)
    #expect(MacMeasuredContentHeight.combined(scrollable: -5, notice: 0, actionBar: 56) == 56)
}
```
- [ ] **Step 2: Run `MacWindowHeightPolicyTests`; expect compile failure**
- [ ] **Step 3: Implement** per the Interfaces block. Remove the three grey tints. On Mac pass `showsInlineStart: false` to `SetupScreen` and `showsInlineAction: false` to the Check and Master Report screens from the Mac shell only; iPad and iPhone call sites keep their defaults.
- [ ] **Step 4: Run the suite; `./test.sh mac-test && ./test.sh ipad-build`; expect PASS and BUILD SUCCEEDED**
- [ ] **Step 5: Live check.** Build Debug, launch, confirm: bar visible on all three tabs with the right sentence and button; the button is disabled (system disabled look) until ready; Return does nothing while disabled; choose a card and backup, press Return, the composer flies into the queue row and lands; resize the window to its minimum and confirm the bar is never clipped; open History, confirm the bar is gone and the tab strip remains. Screenshot each tab for the PR.
- [ ] **Step 6: Commit and open the PR**

```bash
git commit -am "Mac: bottom action bar with the readiness sentence; tab strip visible in History"
```
PR title: "Mac shell: bottom action bar and persistent tab strip". Base: main. Note in the body that readiness wording is unchanged and is spec step 5.

---

## Not in this plan

Spec step 5 (setup hierarchy and vocabulary on Setup, Check, Master Report and History), step 6 (motion), step 7 (tokens). The bar's "Start · 2 backups" plan-stating label and "Choose a card to start." wording land with step 5, which owns the readiness strings.
