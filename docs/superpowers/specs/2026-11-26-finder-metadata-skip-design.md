# Skip Finder's `.DS_Store` files: design

Status: approved by Mike on 2026-11-26 after opinions from Codex (gpt-6.1-terra), a competitive research pass (primary vendor sources) and a safety review against the codebase. Reports: `.superpowers` scratch, summarised here.

## Intent and why

A DIT (GitHub issue 93) lost a clean verdict because Finder rewrote a `.DS_Store` on a backup drive while the folder was open there. BitMatch had copied and verified the file, then correctly refused the changed copy at the final gate. The file is Finder view state, never camera content. Every other offload tool skips `.DS_Store` by default (OffShoot, ShotPut Pro, Silverstack, YoYotta, the ASC MHL reference tool, SD-Offload); ShotPut Pro's manual ignores it "regardless of the option selection as copying these files can cause issues with verification". The ASC MHL specification's default ignore set is `.DS_Store` plus the `ascmhl` folder, nothing else.

## Goals

- A card whose only non-copied entries are proven Finder `.DS_Store` files can still be marked safe to erase.
- Every skipped file is visible: one row per backup in results, History, CSV, JSON and PDF, and a summary line.
- Nothing real can hide behind the name: a file named `.DS_Store` that is not a Finder file is copied and verified like any other.
- The skip is a setting, on by default; off restores today's behaviour exactly.

## Non-goals and anti-goals

- No change to the AppleDouble `._*` exclusion: it stays opt-in and still means never safe to erase (those files can carry resource forks, tags and comments on Mac-written media).
- No new root-folder skipping. `.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems` and `.DocumentRevisions-V100` are already skipped silently at the root when they are directories; surfacing them is a separate item (`.Trashes` can hold deleted clips).
- No `<ignore>` element in ASC MHL manifests for this change: without one the reference verifier already ignores `.DS_Store`; writing one replaces the spec defaults and, being name-only, would hide a non-Finder `.DS_Store` that BitMatch did copy and list.
- No rewriting of existing History. Issue-93 records stay "Needs attention", explained by the separate reason-token fix.
- Anti-goal: any path by which a skipped row counts as coverage without the engine's proof.

## Constraints

- Promise 1: never a false "safe to erase". Promise 3: evidence matches what happened.
- Engine (`Packages/BitMatchEngine`) cannot import Shared; the classifier, statuses and the verdict predicate live in the engine so Mac and iPad agree.
- Older app versions must read new records as not safe (fail closed on downgrade).
- Portable settings must round-trip the new key and tolerate its absence.

## Approaches considered

1. **Status quo plus the reason fix (A).** Honest, but every Finder-browsed backup risks the issue-93 verdict. Interim only.
2. **Opt-in exclusion mirroring AppleDouble, never safe to erase (B).** Consistent with today's rule but pointless: nobody would use an option that forfeits the verdict for a junk file. Rejected by all three reviews.
3. **Skip proven `.DS_Store` by default, report it, do not block (C, chosen).** Matches the spec and the market; BitMatch goes further by checking each file's contents and listing every skip. Cost if wrong: Finder view state for a folder, never footage.

## Design

### What is skipped

A source entry is a Finder view file when all hold: its name is byte-exactly `.DS_Store` (any depth); it is a regular file; its size is within the Finder format's plausible range; its first bytes are the alignment word `00 00 00 01` followed by the magic `Bud1`; and the header's offsets are consistent with its size. Anything else with that name is ordinary: copied, verified, listed. A directory named `.DS_Store` is never classified; a symlink named `.DS_Store` is an unsupported entry as today; `.ds_store` or an NFD spelling is ordinary.

### Where it is decided

Classified once at Start from the pinned complete manifest, in the same place and manner as `AppleDoubleSelection.excluded`, and recorded on the operation as the engine-proven set `skippedFinderMetadataPaths`. One row per destination is written before copying, status `skippedFinderMetadata`, text `⏭ Skipped Finder view file (.DS_Store)` with the note "Finder view settings; not card content; Finder recreates it". The text never contains "✅", so `isSuccessStatus` is false and older builds fail closed. No copy and no destination write happen for a skipped file.

### The verdict rule, in one engine predicate

Safe to erase only when every one of these holds, evaluated in one place (`TransferCompletion`) that every site routes through:

1. every selected row on every destination is verified (Quick never qualifies), as today;
2. every `skippedFinderMetadata` row's path is in the operation's proven set (status text is never trusted on its own);
3. exactly one skipped row per proven path per destination, none extra;
4. selected paths plus skipped paths equal the complete source manifest; unsupported entries stay failures;
5. the run has no `excludedAppleDouble` rows (that rule wins, unchanged);
6. at the final source gate the classifier re-runs on each skipped path still present: one that no longer passes fails closed as `sourceUnstable`; a Finder-to-Finder rewrite or a newly appeared Finder file is not a failure; any new ordinary file still is.

Sites that today compare against `excludedAppleDouble` (issue counting and messages, `hasCompleteVerifiedResults`, `matchingVerifiedRecord`, `hasCompletePlannedResults`, `isInSelectedPlan`, `VerificationScopeEvidence`, `ExpectedExclusionQueuePolicy`, `ascmhlPlan`, `FolderInfoService` and Setup counts, the Remote status mapping) are updated to the predicate; a missed site fails closed because the row is not a success.

### Evidence

- Results, History, CSV, JSON, PDF: the skipped row appears in the per-file table; the summary says "N Finder view files (.DS_Store) skipped: not card content; Finder recreates them". The word "excluded" is reserved for AppleDouble, where it means "the whole card is not backed up".
- ASC MHL: skipped files are left out of `<hashes>` (filtered like AppleDouble in `ascmhlPlan`), so the manifest matches the destination; no `<ignore>` element.
- Card fingerprint: unchanged (it already drops `.DS_Store` by name).
- Reports state the setting that applied to the run.

### Setting

"Skip Finder view files (.DS_Store)", on by default, in Settings beside the AppleDouble control, on Mac and iPad. Portable settings carry it as a new optional key decoded with `decodeIfPresent` (older importers reject or ignore unknown keys as they do today); `schemaVersion` bumps.

### Migration

History is not rewritten. New records read by 0.2.14 and earlier are not safe (no ✅, plan count mismatch). Records with verified `.DS_Store` rows keep their verdict. The AppleDouble rule is unchanged, including runs that also skipped `.DS_Store`.

## Validation

Classifier table (root and nested Finder files skipped; random bytes, empty, short, inconsistent offsets, oversize, other case, NFD, trailing space all ordinary; directory and symlink cases); happy path on two destinations with the file absent from both and from the manifest, and the pinned reference `ascmhl verify` passing; no masking when a clip fails elsewhere; provenance tampering (unproven path, missing row, duplicate row, hand-edited status text) never safe; combined with AppleDouble never safe but the queue still advances; mid-run changes on the card and Finder writes on a destination before and after copy (the issue-93 regression); compatibility (status text, a 0.2.x fixture keeps its verdict, `matchingVerifiedRecord`, portable settings with and without the key); setting off is byte-for-byte today's behaviour; CSV, JSON and PDF wording.

## Left to the builder

- The exact header consistency check and size bounds, from the `.DS_Store` format (Bud1 header: offsets to the allocator and its size, repeated).
- Names of the new status, token and setting keys, following the AppleDouble ones.
- Where the summary line sits in each report format.
