# Step 5: setup hierarchy and vocabulary — plan

Spec: `docs/superpowers/specs/2026-10-21-visual-polish-design.md` §5, plus the
handoff's Step 5 paragraph (binding). Branch `feat/setup-hierarchy` from main
after #86 and #87 merged (b12e5a92). Inline execution in Muse; one PR.

## Decisions already made (do not reopen)

- Vocabulary is card/backups everywhere on Setup, Check, Master Report and
  History; never source/destination in user-visible strings. Internal type and
  property names (`sourceURL`, `destinationURLs`) do not change.
- No page titles: the tab strip is the title. In-screen "Check" / "Master
  report" headings go; `navigationTitle` (window/tab title) stays.
- Mode chooser is a labelled row under the prompt: label "Mode", a segmented
  One-time / Project control, and the selected mode's one line —
  "Each card stands alone." / "Cards go to <project> / <day>." using the
  current project name and day when Project is set up, placeholders otherwise.
  Last-used mode is already remembered by the workflow state; the lock hint
  ("Available when this card finishes") survives under the row.
- Two equal wells on one surface, labelled outside the well: "Card" and
  "Backups". Dashed border = drop here; solid accent border = the next step
  (existing `nextStepHighlight` glow becomes the solid accent border). Prompts:
  "Choose a card…" / "A card or folder, or drop it here" and
  "Add a backup…" / "A folder on each backup drive, or drop them here".
  On iPhone (no drops) the drop copy reads "from Files": the locations view
  already knows this via `drops == nil`.
- Verify control unchanged; its two-line caption under the connector moves
  into the menu as a disabled explanation item. The accessibility label keeps
  the explanation.
- Check: wells "Folder or drive to check" / "Compare with", second well hint
  "The original, or another copy."
- Master Report: prompt "Choose a backup drive with the day's reports." and
  the existing Day date field stays.
- History: counts read "2 backups"; search placeholder
  "Search cards, clips, or backups"; footer
  "Diagnostics stay on this Mac until you export them."
- Readiness strings (bar and start): "Choose a card to start.",
  "Add a backup to start.", and once ready the bar button reads
  "Start · 2 backups" (count from the plan). `QueueTally.text` adopts the row
  labels ("keep the card", "didn't verify", "queued") so the bottom
  accessory, summary line and finish notice stop saying "needs attention".
- Sentence case everywhere on these surfaces ("Skip and continue",
  "Remove from queue").

## Tasks

1. Presentation strings: `TransferPlanPresentation`, `StartButtonPresentation`,
   `WorkflowActionBarPresentation` (incl. "Start · N backups"),
   `TransferPlanStatusDisplay`, `QueueTally.text`. Update the focused tests
   that assert the old strings; add a tally-label test.
2. Setup: prompt wording, mode row (segmented + description, lock hint),
   wells (labels, equal widths, one surface, dashed/solid border, prompts),
   verify caption into the menu. `SetupLocationsView`, `SetupScreen`.
3. Check and Master Report: remove in-screen titles, prompts, well labels.
   `CompareScreen`, `MasterReportScreen` and their presentations.
4. History: backup counts, search placeholder, diagnostics footer.
5. Sentence-case sweep on the touched surfaces; grep the diff for competitor
   names (none allowed) and for leftover "source"/"destination" UI strings.
6. Validate under the test lock: `./test.sh mac-test`, `./test.sh ipad-build`.
   Live-check the three tabs on the real build; screenshots for the PR.

Out of scope: motion (Step 6), tokens (Step 7), History row internals.
