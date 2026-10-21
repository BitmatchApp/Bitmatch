# Failed-readback output marking — October 21, 2026

Bounded slice of `docs/TODO.md` "Output ownership and recovery": make a
file that fails readback unmistakable on disk. Re-copy/re-verify and
sibling repair stay deferred (they need the same ownership proof plus
recovery provenance design).

Source: worktree `wt-exfat-publication`, branch
`todo/exfat-publication-20261021`. `CHANGELOG.md`/`docs/TODO.md`
consolidated by reviewer on merge. exFAT publication race itself was
already implemented (see `EXFAT_PUBLICATION_DESIGN.md`); this slice is
the downstream marking step.

## Behavior

When destination readback produces a checksum mismatch (never on a read
error — those throw out of verification), and the file was written by
this attempt (not a reused pre-existing file), the engine renames it to
`<name>.bitmatch-failed` in the same directory and reports the marked
path as the result's destination. Bytes are preserved; the verdict was
already unsafe and stays unsafe. Quick mode produces no readback and is
unaffected.

Ownership protocol (`PinnedDestinationDirectory.markFailedReadbackOutput`):

1. Identity (device, inode, size, mtime, ctime) is captured before
   readback and re-checked after; any change skips marking.
2. At rename time the named file must still equal that identity, and the
   marked name must be free, or nothing is touched.
3. After the rename, the moved file must match on the fields a rename
   cannot change (device, inode, size, mtime); a mismatch means a
   concurrent swap raced the rename — the file is put back when the
   original name is free and the swap is reported, never success.
4. The parent directory is synced after a successful mark.

Reused files are tracked per (destination, path) during copy and are
never marked: this attempt does not own them.

## Tests

- `FailedReadbackMarkingTests` (5, new): matching identity marked with
  bytes intact; nested path marked in place; replaced file never marked
  (other writer's bytes survive at the final name); occupied marked
  name leaves the failed file in place; missing file reported.
  The suite caught a real defect during development: a rename bumps
  ctime, so the post-rename check must exclude it.
- `FanOutTests`: the failed-readback coverage case and the Thorough /
  Paranoid copy-stream corruption cases now assert the corrupted bytes
  live at the marked name and the normal name is absent; Standard's
  documented trade-off (corruption not caught, no marking) unchanged.
- Full engine suite: XCTest 342 executed (86 skipped), Swift Testing
  268 tests in 40 suites — all passing.

## Limits

- The swap window between the post-readback identity check and the
  rename is closed by re-verification inside the mark plus rename-back,
  but Darwin has no atomic rename-if-identity primitive; a hostile
  actor racing the exact rename instant is detected and reported, not
  prevented. Same honesty boundary as `EXFAT_PUBLICATION_DESIGN.md`.
- Marking failure (occupied name, identity change, missing file)
  leaves the failed file at its normal name with the unchanged unsafe
  verdict — visible in History via the result path only when marking
  succeeded. Surfacing "marking was attempted but skipped" in reports
  is follow-up work.
- exFAT/FAT physical runs of the direct-final path were validated in
  the publication-race work; this marking rename is filesystem-agnostic
  `renameat` within one directory and was exercised on APFS here.
