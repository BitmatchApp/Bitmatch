# PDF identity pagination regression

The synthetic 4K preview probe exposed a report ending with a page containing
only Job ID/version text. A new normal regression reproduced this before the
fix: 13 tests executed, one failed. The PDF renderer had treated identity as a
final content block after the manifest.

PDF identity now shares the page footer with the page number. The renderer
measures wrapped Job ID, version, OS and company text and reserves its space
before packing content. The screen footer is unchanged. Unusually large identity
text falls back to ordinary pagination, preserving the full text rather than
clipping it or consuming most of every page.

Local Mac validation:

- Of 34 focused tests discovered, 33 passed and one existing codec-fixture
  opt-in was skipped: 14 layout, 16 thumbnail and three Master Report passes.
  No new test was skipped; there were zero failures or xcresult runtime warnings.
- Normal regressions rendered 20 and 200 preview reports, long company/version
  text, and oversized metadata. Assertions retain every filename and identity
  token, check footer/text bounds and preserve the verification verdict.
- The cancelled seven-file History report still fits one page and retains its
  unsafe verdict. Existing long Master Report names still wrap within the page.
- Real Standard copy/readback plus 4K preview collection was rerun at 20 and 200
  paths. Both runs passed all three probe tests; source/destination SHA-256
  snapshots matched. Independent Poppler inspection counted 20/200 image
  placements across 2/14 pages, down from 3/15. Every page contains file rows
  and identity; the empty final page is gone.
- Sampled process peaks in those reruns were 102/103 MiB, decoder peaks 79/82 MiB
  and PDF peaks 82/98 MiB. Production preview limits stayed unchanged. These are
  repeated-path synthetic H.264 probes, not proof of issue #23's cause or of
  bounded memory for every codec. See the separate memory-probe note.

All generated PDFs were rendered privately. Representative final pages,
wrapped metadata, the oversized-text fallback, cancelled report and long Master
Report were visually inspected. This is headless PDF evidence, not interactive
app or hardware validation. Shared iOS build and PDF regression gates remain
part of integration validation.
