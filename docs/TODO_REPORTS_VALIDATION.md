# Reports and History quick-win batch

Implemented on `feature/todo-reports`, based on released 0.2.6 (`a78ca98d`). This is review work, not another published release.

## Changes

- PDF reports lead with the recorded verdict and a compact summary. Repeated performance statistics, worker counts, file-type breakdowns and empty environment fields are removed. Notes, source/backup locations, per-file results, project evidence and job ID remain. Preview and filename share a row; pagination uses the same sizing for measurement and rendering.
- **Settings → Reports → Include clip thumbnails in PDFs** is optional and off by default on Mac, iPad and iPhone. **History → Export report** offers PDF with or without previews. History export uses saved evidence, not a new verification, and does not require the original card.
- Expanded History shows dates, deduplicated recorded source counts/sizes, measured phase durations and measured aggregate copy speed. Missing old measurements show a dash. Intentional exclusions are not described as failed clips in History search.
- [The guide](GUIDE.md) explains verification modes, destination readback, scope and card-safety limits.
- Mac source-preservation snapshots now include creation dates, ownership and all extended attributes, alongside paths, contents, size, modification dates and permissions.

## Preview limits and safety

Extraction is sequential: at most 200 attempted clips, with a 30-second collection budget and a two-second wait per clip. AVFoundation frames are limited to 256 × 144; retained JPEGs are capped at 64 KB each. Timeout and cancellation settle the caller independently of the decoder queue and request native cancellation. This bounds caller waiting; it does not guarantee that a wedged OS decoder has exited.

Only verified MOV/MP4/M4V backup rows are eligible. Missing, changed-size, symlinked or unsupported media is skipped, with no source fallback. History additionally resolves saved destination bookmarks and validates original folder/volume identity. A preview reflects backup contents at report time and is explicitly not verification evidence. It never updates the saved result, checksum or safety verdict. There is no persistent cache and images are not serialized into JSON or diagnostic exports.

## Validation scope

Synthetic solid-colour H.264 media exercises real AVFoundation extraction on Mac and the iPad simulator. Shared regression tests cover default-off/Quick exclusions, unavailable and changed-size backups, symlink rejection, another available backup, corrupt media, cancellation before and during collection, attempt/time budgets, PDF regeneration with the original source deleted, unchanged unsafe verdicts, unsupported files retained in reports, automatic exporter wiring, JSON without images, History measurements, destination identity rejection and 75-preview pagination with every filename present exactly once.

Mac source snapshots pass through the real app executor in all four verification modes, with requested reports and MHL. Separate Standard cases cancel after readback and cause a real report-publication conflict; both compare the complete source snapshot afterwards. These do not establish metadata preservation on every filesystem or during every possible disconnect. Unsupported xattr fixtures explicitly skip instead of passing.

The generated PDF and six-page preview report were rendered with Poppler and visually inspected. Seeded History layouts were rendered at 320, 500 and 820 points. This is synthetic and simulator coverage; physical iPhone/iPad picker/export walkthroughs and proprietary-camera footage checks remain release gates.

One concurrent validation run failed existing timing-based waits: five Mac tests and two engine tests (three assertions). Failures and logs are retained under `dist/validation/todo-reports`; no production transfer or verification code was changed to accommodate them. Separate reruns are recorded below. The first new report-conflict test also incorrectly expected an exception; it was corrected to assert the existing retained, unsafe completion outcome.

## Final local results

- Mac app suite: **1,084 passed, 9 skipped, 0 failed** (1,093 tests in the Xcode summary).
- iPad Air (M4), iOS 26.5 simulator: **60 passed, 4 skipped, 0 failed** (64 tests). The four optional capture tests were also run with capture enabled earlier in this batch; final skips do not represent missing assertions in the feature tests.
- Engine: **121 XCTest cases, 15 skipped, 0 failures**, plus **132 Swift Testing tests passed**. The two timing-based engine tests that failed under concurrent validation passed in the separate full rerun.
- Mac and iPhone/iPad Release builds: **BUILD SUCCEEDED** for both targets (unsigned local validation).
- `git diff --check`: clean.

All 14 new shared report/History tests pass on both Mac and the iPad simulator. Native extraction uses real synthetic video; deliberately wedged OS decoders and physical mobile share-sheet/picker workflows were not simulated. Preview failures and caller cancellation do not constitute evidence of successful media verification.
