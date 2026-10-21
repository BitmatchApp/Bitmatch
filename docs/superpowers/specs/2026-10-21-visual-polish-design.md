# Visual polish: design

Date: 2026-10-21. Owner: Mike. Status: approved direction, awaiting plan.

Companion proposal with mockups, live motion demo and review history: private artifact, link held by Mike. This document is the buildable version. Field research and comparisons stay out of the repo.

## Intent

BitMatch promises one thing: tell a DIT when a card is safe to erase. The app already does the right things (one job per tab, plain words, green reserved for verified). The gap between it and an Apple Design Award shortlist is hierarchy, consistency and the moment of verification landing. This work changes weights, words and motion. It adds no features, so it sits inside the feature freeze.

## Goals

- The safe-to-erase moment is unmistakable, honest (green only after the result commits) and carries through to the card leaving the reader.
- Queue rows can be told apart at a glance from across a cart: which card, how long ago, what is wrong, what to do.
- One surface and one vocabulary on Setup, Check and Master Report: card and backups, never source and destination.
- One motion system: five named tokens, every existing animation routed through them, delight only in answer to the user's own action.
- Works on Mac, iPad and iPhone from one view tree, per AGENTS.md.

## Non-goals

- No new workflow, no auto-queue changes, no card-inserted auto-fill (noted as the next big win; out of scope under the freeze).
- No sound by default. The existing "Play sounds" setting stays off.
- No App Store or Liquid Glass-specific work beyond what a native control gives for free.
- No change to engine, verification or report behaviour.

## Anti-goals (what would make this a failure even if it ships)

- Green appearing before a result is committed, anywhere.
- A row that cannot be distinguished from its neighbour.
- Motion that starts on its own, or moves layout under a pointer that is mid-click or mid-drop.
- A state label that does not tell the DIT what to do.
- A Mac-only or iPhone-only branch for anything on this list except the keyboard hint.

## Constraints from the code and the thesis

- `ResultPresentation` already has distinct states: waiting, preparing, copying, verifying, finishing, safeToErase, copiedNotVerified, needsAttention, failed, interrupted. Reuse them; do not add states.
- "Copied, not verified" is the Quick-mode verdict and stays amber (THESIS decisions, P2).
- The Mac is forced dark. Light-theme values matter only on iPad and iPhone.
- The finish is `SafeTransferHero` inside the expanded queue row, not a separate screen. It already draws a ring, bounces a checkmark, handles Reduce Motion and shows a green Eject.
- The Mac tab strip is already a native segmented `Picker` in the principal toolbar slot. Segments are drawn by AppKit and stay text-only.
- iPad and iPhone already have a bottom action bar via `safeAreaInset`; `SetupStartControl(usesBottomBar:)` exists.
- The verify-mode control is already a full-hit-area `Menu` on the connector that goes vertical when the wells stack. The thesis keeps verification modes off the default path; do not promote them.
- History already uses `.searchable`.
- The queue section observes live progress at the top (`TransferQueueSection` holds the live feed as an observed object), so any per-row fill must live in a leaf view that observes only its own fraction, or every row redraws on every tick.
- The composer-to-queue flight is a preference-key overlay (`QueueFlight`), not `matchedGeometryEffect`; keep it. Rows are a custom stack, not a `List`, because drag-to-reorder and the flight depend on it.
- Deployment targets: macOS 15.5, iOS 18.5.

## Build order

Each step is its own PR with before and after screenshots from the real build (Mac dark; iPad and iPhone light and dark). Steps 1, 2 and 6 are the ones a jury notices. Effort is from a read of the code.

### 0. Two bugs (about 1 day)

- Three identical "A7IV_CARD1 needs attention" rows on today's build are most likely three attempts at the same card. Every direct start adds a session record and nothing retires the earlier failed attempt of the same card; the row has no timestamp, so attempts look identical. Fix: when a card restarts, retire or merge the earlier attempt's row; deduplicate session record IDs when building the presentation; add `endedAt` to the row model.
- "Remove from Queue" on the paused banner does nothing visible. `removePausedCardFromQueue` throws unless the record passes `isQueueProblem`, and the thrown error renders only as a small caption under the list. Fix: make the guard accept the paused record whatever its journal state, or surface the refusal as an alert that names the reason.
- Verify with a reproduction on the current data, then with a unit test for each.

### 1. Safe-to-erase loop (about 1.5 days)

Hero (expanded row):
- Title stays "<card> is safe to erase" in green, `.title2` semibold.
- Subtitle is exact: "486 files read back from both backups and matched to the card. 1m 35s." Never "byte for byte" unless the mode was paranoid.
- One line per backup, named by volume and folder from `outcome.destinations`: "SHUTTLE A › Day_04/A_CAM", with files verified. No hardware model names (no iOS equivalent).
- Eject is the only green control and the largest. "New transfer" becomes "Next card". "Retry" and "Export report" are bordered, same height; Retry goes into the overflow menu on a success.
- Any "Notify me" checkbox that still exists is removed; the setting lives in Settings.

Collapsed row after commit:
- Row flashes green for 600 ms then settles to the plain surface. The solid green "Safe to erase" pill is the only persistent green. Eject on the collapsed row is bordered.

Eject carry-through:
- Press: label crossfades to "Ejecting…" at fixed width. Success: glyph becomes a checkmark, label "Ejected · safe to remove", button fades from green to bordered. That label stays until the volume is physically gone; then the row marks "Removed" and drops to secondary text. A row never disappears by itself.
- Unsafe eject asks once: "Not safe to erase. Eject anyway?"
- Failure (volume busy): inline text naming the app holding the volume; no modal.

Attention variant:
- No sweep. Fill stops, desaturates to grey over 150 ms; orange 4 pt edge grows in over 150 ms; triangle appears at once. No wiggle. First failed file scrolls into view. Normal notification banner.

Out-of-screen cues (no sound):
- Notification "SD_CARD_042 is safe to erase. 2 backups verified." Dock badge until eject. Menu bar companion status. Haptic success on iPhone and iPad.

### 2. Transfer row (3–4 days)

One row component shared by the queue; History adopts its internals in a later pass.

- Headline: card name, `.headline` at 15 pt on Mac, middle-truncated so the card number survives.
- State: SF Symbol plus coloured text, the pattern History uses. Glyphs differ in silhouette: checkmark.circle.fill (safe), exclamationmark.triangle.fill (keep the card), xmark.octagon.fill (didn't verify), a half-filled circle (copied, not verified, amber), arrow.triangle.2.circlepath (copying/verifying), clock (queued). "Safe to erase" is the only solid-filled pill.
- Labels: "Keep the card" (was Needs attention; History may keep the old word since the card may be gone), "Didn't verify" (was Failed), "Copied, not verified" (Quick verdict only, amber), "Verifying" while verifying, "Queued", "Copying".
- Meta line, at most three segments: state and time · reason or backups by drive name · size. Tabular numerals. Engine phrasing is replaced: "can't confirm every file was copied".
- Running row only: a current-file line on the left and "About 12 minutes · 557 MB/s" on the right. Filename updates throttled to 2 s; numbers to 1 Hz. iPhone drops the filename.
- Orange 4 pt left edge only on rows needing a decision; 6 pt red for a failed verify.
- Actions: one primary button (Review on attention, Eject bordered on safe, Pause on running), everything else in ⋯ and context menu; on iOS also swipe where the container allows. Remove lives in the menu and confirms: title "Remove <card> from the queue?", body "It isn't safe to erase yet. Files already copied stay on the backups.", buttons Remove / Cancel.
- Header: "Transfers · 1 safe to erase · 1 keep the card · 1 copying", counts using the row labels verbatim.
- The paused banner becomes a one-sentence strip with no buttons: "Paused at <card>. Keep that card until you review it."
- Accessibility: each row is one element, state first ("Safe to erase. A7IV_CARD2. Verified 4:41 PM, Shuttle A, Shuttle B, 48.1 GB"); Review, Eject, Remove as accessibility actions; glyph and edge hidden from VoiceOver. Under Increase Contrast, tints become opaque fills with a 1 pt border and the edge widens to 6 pt.
- Model work: copy `endedAt` into the row; expose per-destination verify progress to the row for "2 of 3".

### 3. Native tab strip (0.5–1 day)

- Remove the custom capsule styling around the existing segmented Picker so the system draws the thumb and inactive-window state. Text-only segments.
- Set `navigationTitle` to the tab name so Mission Control and VoiceOver have it. No visible page titles on any tab.
- The strip stays visible in History (History becomes a destination or sheet, not a pushed view that replaces the toolbar).
- ⌘1/2/3 already exist.

### 4. Mac bottom bar (1.5–2 days)

- `safeAreaInset(edge: .bottom)` on the Mac main scroll view, reusing `SetupStartControl(usesBottomBar: true)`. Material background, hairline top, 56 pt.
- Left: one sentence naming the one missing thing: "Choose a card to start." then "Add a backup to start." Once ready: "Ready. 1 card to Shuttle A and Shuttle B." Right: the primary button. Return triggers it. Button label states the plan once ready: "Start · 2 backups".
- Remove the manual grey tint on the disabled button so the system disabled look applies.
- Rework the queue-flight origin (the bar sits outside the flight coordinate space) and add the bar height to the launch-window fit.
- Check and Master Report use the same bar with "Check" and "Scan" as verbs.

### 5. Setup hierarchy (2–3 days)

- No page title. One-line prompt under the toolbar: "Choose a card, then a folder on each backup drive."
- Mode row under the prompt: segmented One-time / Project plus the selected mode's one-line description. One-time: "Each card stands alone." Project: "Cards go to <project> / <day>." Last-used mode remembered. The existing lock-while-running hint survives.
- Two equal wells on one surface, labelled outside the well: "Card" and "Backups". Dashed border means drop here; solid blue means next. No card inside a card. Prompts: "Choose a card…" / "A card or folder, or drop it here" and "Add a backup…" / "A folder on each backup drive, or drop them here". On iPhone the drop copy becomes "from Files".
- Verify control: unchanged; move the two-line caption under the connector into the menu's explanation.
- Check: well labels "Folder or drive to check" and "Compare with"; second well hint "The original, or another copy." Master Report: "Choose a backup drive with the day's reports." and a date field for the day.
- History: "2 backups" not "2 destinations"; search placeholder "Search cards, clips, or backups"; footer "Diagnostics stay on this Mac until you export them." with Export in the toolbar. Sentence case everywhere: "Skip and continue", "Remove from queue".

### 6. Motion (2–3 days)

Motion file, five tokens, routed through the six existing call sites (list spring, three expand/collapse durations, hero ring, flight):

- `Motion.settle` = spring(duration 0.42, bounce 0.14): layout changes.
- `Motion.quick` = easeOut 200 ms: appearance changes.
- `Motion.commit`: the one named choreography, 560 ms total (below).
- `Motion.data` = linear 300 ms: progress fractions and counters; nil under Reduce Motion.
- Native: segmented picker thumb, disclosure groups, sheets, Dock bounce, notifications.

Row as progress bar (running rows):
- A leaf `RowProgressFill` view observing only its own fraction draws a translucent accent fill (22 percent alpha on Mac; 12 percent with a 1 pt border on iOS light) growing from the leading edge, a 1.5 pt solid leading edge with no glow, and a 2 pt track along the row bottom at the same fraction in a stronger blue. `drawingGroup` on the fill layer only. While verifying, one continuous lighter layer rises over the copy fill and the track restarts in a paler blue. No per-backup sweeps.
- The new row is created at zero fill before the first tick lands. On retry or resume the fill animates backwards with `quick`.
- Expanded: the fill stays on the header strip and becomes the hero background; no second fill.

Commit (560 ms, only when the row is on screen and the app is frontmost; otherwise the row takes its final state):
- 0–200 ms fill crossfades to a green flash; ring draws over 240 ms from 80 ms; check and Eject at 280 ms; label crossfades to "Safe to erase". The flash settles to the plain surface over 600 ms and the ring fades as the pill lands. Eject enables the instant the result commits; no lockout timer. Several cards finishing together stagger by 120 ms, capped at three. Reduce Motion: 200 ms crossfade with the ring pre-drawn (as the hero does today).

Responsive delight (answers an action; never idles; never moves layout under a mid-click or mid-drop pointer):
- Hover a row (Mac): surface brightens 3 percent, no lift.
- Drag over a well: dashed to solid accent border; well grows to 1.01; prompt crossfades to "Drop to use as card".
- Choose a card or backup: prompt becomes the name; readiness sentence crossfades; Start tints to accent without moving.
- Switch mode: native thumb; description crossfades; Project row unfolds from zero height.
- Open Advanced: chevron turns; controls unfold; summary fades as controls fade in.
- Expand a row: height springs in place; hero fades up 6 pt. No matched geometry.
- Reorder: rows part with settle; dragged row lifts with shadow at 1.02; drop settles without bounce.
- Switch tab: native thumb; page crossfades 120 ms out, 200 ms in with a 4 pt rise.
- Open History: first six rows stagger 20 ms, 120 ms total; the rest at once.
- Plug in a drive: row slides in from the top with a 1 s highlight; deferred while a drag or press is in flight on that list.
- Resize the window: wells move between side-by-side and stacked through settle during a live resize only.

Never: pulsing or breathing edges, shimmer, looping spinners on paused rows, confetti, motion that starts on its own, layout moving under the pointer, row re-sorting under the pointer, celebrating a row that is not the finish, a lockout timer on Eject, sound by default.

### 7. Tokens (2–3 days)

- Type: text styles only, two weights. Row and well titles `.headline`; body and buttons `.body`; meta and hints `.callout`, never smaller; state labels `.subheadline` semibold; numbers `monospacedDigit`. One semibold line per container. Replace hand-picked `.system(size:)` calls.
- Colour: `.primary` / `.secondary` / `.tertiary` for text. Semantic tones extend `CardSafetyTint` and `TransferPlanStatusTone`: blue next, green verified, amber copied-not-verified, orange keep the card, red didn't verify, each with iOS light values that clear 4.5:1 on white (e.g. pill #1b7f37 with white text) and Increase Contrast variants. Filled buttons use the system prominent style.
- Spacing: 4 / 8 / 12 / 16 / 24 / 32. Gutter 24, between sections 24, inside containers 16, row padding 12, controls 28 and 32, bar 56.
- Radius: 12 containers, 8 controls, capsule for pills and tabs; nested radius = outer minus padding, floored at 4. Apply only to custom surfaces, never to system Forms or sheets.

## Calls made after the builder check (Claude's, overridable)

- **Eject on iPad and iPhone.** Eject is an existing Mac-only capability (`ejectQueueSource` is `#if os(macOS)`), which AGENTS.md allows as an exception. On iOS the hero's primary control is "Next card"; the row shows "Safe to erase" and the DIT removes the card. The "Ejecting… / Ejected · safe to remove / Removed" carry-through, the Dock badge and the commit choreography's Eject beat are Mac-only; on iOS the choreography ends at the label and haptic.
- **States the label table omitted.** `.interrupted` (and cancelled, which maps to it) is "Keep the card" with the reason "Interrupted" in the meta line, orange, counted with attention. `.failed` splits by stage: "Didn't copy" when the copy stage failed (full disk, pulled drive), "Didn't verify" when verification failed; both red, both counted as "didn't verify" in the header for brevity. `.preparing` and `.finishing` use the copying glyph with the phase word in the meta line and no separate label.
- **Duplicate attempts, step 0.** Fix at the presentation layer only. Journal records are never deleted or merged; History and report scans keep every attempt. In the queue, "same card" means the same source identity within one queue session (the identity the coordinator already uses to refuse repeats); the latest attempt is the row, earlier attempts are listed inside the expanded row. If reproduction shows a different cause, fix that cause, but still never touch journal records.
- **Motion scope.** Token routing covers the six named call sites in the queue section, flight, hero and Mac shell, plus all new work in this spec. No sweep of Photographer, InterfaceLab, Preferences or the iPad content views; those keep their animations until a later pass.

## Decided by Mike, 2026-10-21

- **Attention notification** ships as a normal `.active` banner. No Time Sensitive entitlement; not worth the signing and release-flow churn.

## Left to the builder

- Exact glyph for "copied, not verified" (a half-filled circle variant or `circle.lefthalf.filled`).
- Whether History becomes a sheet or a fourth destination, as long as the tab strip stays visible.
- How to expose per-destination verify progress to the row (feed extension vs. derived from existing results).
- The throttle implementation for filename and rate text.
- Whether the Increase Contrast variants live in the tint enum or a view modifier.

## Validation

- Mac tests and the iOS build per AGENTS.md for every step; unit tests for the two bugs in step 0 and for the row label/count mapping in step 2.
- Screenshots before and after from the real build for each PR, Mac dark and iPad/iPhone light and dark, added to the PR, not to docs.
- A Reduce Motion and Increase Contrast pass on each motion step.
- No competitor names or comparisons anywhere in the diff.
