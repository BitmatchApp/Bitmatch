# Path comparison and missing-tail overlap — October 20–21, 2026

`PathContainment` and `ResultPathMatch` promise text-only comparisons, including for saved records whose files are no longer connected. The old implementation delegated to Foundation URL standardization, which can inspect existing symlinks. A test created a symlink after the first comparison and observed the same string produce a different normalized path. The new normalizer handles separators, dot segments and fixed macOS private-directory aliases lexically. It preserves filename bytes/case and does not decode percent sequences. Relative inputs remain anchored to the process working directory. Callers needing filesystem identity must resolve it first.

The safety regression also found a separate, pre-existing gap: whole-URL resolution left an existing source alias unresolved when the requested destination's final child folders did not exist. `folderOverlap` and `destinationSafetyIssue` returned no overlap. Safety validation now reuses its existing prefix resolver to resolve known symlink components before appending missing tails.

These are preflight comparisons, not write authorization. Selected destination folders must still exist, source/destination symlink guards remain active, and the pinned destination opener still walks with no-follow semantics. No file was copied into its source during reproduction; these tests do not establish that the earlier gap bypassed those later safeguards. Filesystem resolution may block and a path can change afterward; the pinned checks remain necessary.

## Focused results

- Original source plus eight new/existing tests: **failed, five assertion issues**. Two showed filesystem-dependent text comparison; one distinguished lexical from resolved text in the live-safety fixture; two reproduced the missing-tail overlap gap.
- Lexical normalizer alone: **failed, two issues** in the still-unfixed missing-tail overlap test. The text and existing symlink/parent-traversal checks passed.
- Prefix-resolution correction plus expanded controls: **13 tests passed, zero failures, 0.041 seconds**. Coverage includes both overlap directions, nonexistent descendants, an outside target, fixed temporary aliases, a 16-link chain, cycle rejection without writes, component-prefix boundaries, private aliases and duplicate backups.

All fixtures are exclusively owned temporary directories. No user media or mounted test drive was used for these focused reproductions. Full engine, Mac, iPhone/iPad build and updated physical-drive gates remain pending in the [overnight record](overnight-reliability-2026-10-20.md). No production History performance improvement or resolution of #10/#23 is inferred from these focused passes.
