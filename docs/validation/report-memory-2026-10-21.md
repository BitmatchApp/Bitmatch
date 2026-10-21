# Report memory validation — October 21, 2026

## Status and evidence boundary

The local PDF candidate is `1f73beba5d17bc1ce5b259ac67ab9243dd8b9c1c`, following the layout/status tests in `296663ef`. It fixes memory growth reproduced in synthetic reports. It does **not** reproduce or resolve field issue #23. Issues #10 and #23 remain open; PRs #79–81 and the PDF work remain held for review. No merge or release is authorized.

These results were observed before the Mac reboot. The first documentation update used source and the recorded conversation only. The reboot removed temporary progress records, private runners and host-side artifacts. A later authorized read-only T9 recovery recovered nine saved app-test records, as detailed below. Do not assume every raw PDF, memory sample, visual-review receipt or failure fixture survived. Gate names identify original runs; the recovery does not count as another test execution.

## Implementation

Rows are constructed lazily. SwiftUI still measures and paginates the report. Eligible single-line and wrapped cells draw through Core Text with shared fonts; wrapping retains the two-line, middle-truncation policy. Prepared native rows live for one page. Headers, actual previews, control-character text and other ineligible rows keep the SwiftUI path.

One PDF context writes through a private file-backed sink with a reusable 64 KiB buffer. The file is created exclusively, unlinked before writing and mapped after finalization, synchronization and byte-count/identity checks. Write, mapping, cancellation and cleanup errors do not return partial PDF data. Measurement and rendering yield and check cancellation in batches; synchronous OS/drawing calls have no hard deadline. Source media, verification rules and recorded results are unchanged.

## Recorded results

Memory probes used the unchanged **1,024 MiB cooperative process guard**. A pass describes that workload, not a universal bound. Bulk full-manifest extraction ran outside the measured generator process.

| Gate | Observed result and limits |
| --- | --- |
| Actual coordinator/live views, `mac-app-report-memory-20261021T114327Z`, `5eb7ac09` | **Passed:** 1 test, 0 skips/failures, 716.515 s. 20,000 synthetic 1 KiB files, two host-filesystem destinations, reports off/on; both passes verified 40,000 rows and source/backup hashes. Off: 252.489 s; on: 451.136 s; peak 682 MiB. MHL/previews off, abstract disk identities. This precedes the wrapped-row change; no final-commit rerun occurred. |
| Plain 40,000-row PDF, `mac-pdf-scale-20261021T114104Z`, `5eb7ac09` | **Passed:** 1 test, 0 skips/failures, 19.865 s; peak 164 MiB, final 90 MiB; 1,430 pages, 8,000,651 bytes. Independent extraction checked every source/backup pair; pages 1, 715 and 1,430 received visual review. |
| Mixed 10%-wrapped PDF, `mac-pdf-complex-20261021T124801Z`, `296663ef` | **Passed:** 1 test, 0 skips/failures, 30.665 s; peak 305 MiB; 1,513 pages, 19,933,788 bytes. All 40,000 rows and 20,000 Backup 1/2 pairs passed independent content checks, including statuses and expected Unicode. Representative manifest/issue pages received visual review. |
| All-wrapped baseline, `mac-pdf-complex-20261021T124947Z`, `296663ef` | **Failed the guard:** 1 test, 0 skips, 1 failure, 71.110 s; peak 1,624 MiB. The completed 2,224-page, 124,446,870-byte artifact passed independent full-manifest validation. Controlled memory failure, not an OS crash. |
| All-wrapped fix, `mac-pdf-complex-20261021T125700Z`, source content committed as `1f73beba` | **Passed:** 1 test, 0 skips/failures, 37.726 s; peak 191 MiB; same 2,224 pages, 13,247,854 bytes. Independent validation covered all 40,000 rows and 20,000 Backup 1/2 pairs, with no omissions, duplicates, unexpected rows, wrong statuses, expected-Unicode omissions, blank pages or extraction warnings. Pages 1, 1,112, 2,223 and 2,224 received visual review. |
| Final mixed PDF, `mac-pdf-complex-20261021T130514Z`, `1f73beba` | **Memory probe passed:** 1 test, 0 skips/failures, 23.572 s; peak 157 MiB; 1,513 pages, 8,902,128 bytes. Independent full-manifest and visual validation of this particular artifact had **not** occurred before reboot. Earlier mixed-artifact validation is separate. |
| Real-encoded 4K previews, `mac-preview-20261021T130011Z`, source content committed as `1f73beba` | **Passed:** 1 test, 0 skips/failures, 5.313 s; 20 synthetic 3840×2160 H.264 clips, 20/20 previews, stable source/backup hashes, 2-page PDF. Peak 104 MiB; decoder 81 MiB, PDF phase 83 MiB. Both pages received independent visual review. |
| Focused PDF checks, `mac-pdf-focused-20261021T125455Z` | **Passed:** 27 tests, 3 suites, 0 skips/failures, 3.758 s. Later full Mac coverage includes the added ESC/DEL/NUL native-eligibility assertions. |
| Full Mac suite, `mac-test-20261021T130059Z`, `1f73beba` | **Passed:** 1,435 passed, 35 skipped, 0 failed, 1,470 total; result-bundle summary verified. Framework/parameterized subtotals are not additional tests. Skipped opt-in workloads are not covered by this run. |
| Generic iPhone/iPad simulator build, `ios-build-20261021T130239Z`, `1f73beba` | **BUILD SUCCEEDED:** arm64 and x86_64. App build only; not current iOS test-target compilation, simulator execution or physical-device proof. |

The all-wrapped peak fell from 1,624 to 191 MiB under these conditions. Complex manifests deliberately mix verified, failed and copied-but-unverified rows; successful PDF generation is not a successful transfer verdict.

The earlier actual-app PDF also passed an independent complete-manifest check, with each source-relative name paired once with each correctly mapped Backup 1/2 destination. Its initial validator incorrectly expected raw paths instead of backup labels. The corrected check required the full Locations mapping and exact pairs; production code was unchanged.

The 4K clips contain identical synthetic color frames. All 20 JPEGs were 256×144 and byte-identical; the PDF had two image resources through reuse. This exercises decoding/collection/embedding, not diverse footage or 20 distinct PDF image objects. Layout tests with 200 generated preview tiles are separate from real-video decoding.

## Regression coverage and review

Mac tests compare native/SwiftUI row positions, place wrapped filename head/tail inside the measured height, keep following rows and footers clear, exercise native fallback eligibility and preview exclusion, and retain Quick/failed status behavior. Equivalent iPad tests exist, but current runtime behavior remains untested.

Four deliberate regressions each caused the expected focused assertion failure: a left shift, bypassed width/control eligibility, gray in-progress text and bypassed preview fallback. Exact source restoration and a restored green run were checked before the wrapping fix. Sink tests cover partial writes, EINTR, zero writes, ENOSPC and cancellation without returning partial PDF data.

Source-only review found no evident row-data or status-mapping defect. Remaining limits:

- Wrapped-row assertions check head/tail and geometry, but not the native row's ellipsis or wrapped Unicode directly. A private proposed patch was not applied and disappeared with temporary files.
- Native helpers reject control characters; this does not verify how the SwiftUI fallback prints those names. Large control-heavy manifests lack equivalent scale coverage.
- Native fixed colors and fallback SwiftUI colors have not received a resolved-color parity check across platforms. A visible mismatch is not established.
- The buffer is bounded, but results, layout and PDF resources still grow with report size. No constant-memory claim is made.

## Physical checks

`physical-matrix-prebuilt-20261021T122853Z` passed one actual XCTest, zero skips/failures, in **810.211 seconds**. Nine SD-to-two-SSD operations covered four modes with pipelining off/on plus Standard reuse. The unchanged source inventory contained 272 files including metadata companions and 2,152,353,149 bytes. Prior histories survived reuse; worker peak was 31 MiB. The engine package matched validated `de673b81`. This is separate from app/PDF testing and does not explain the earlier Thorough rejection.

The app-host check `physical-app-prebuilt-once-20261021T130643Z-f4028a1d` used existing `1f73beba` products with `test-without-building`. **The XCTest passed:** 1 test, 0 skips/failures, 4.153 s. One approximately 32 MiB SD-to-two-exFAT-SSD Standard transfer checked independent hashes, ASC MHL, Saved Check, the real journal, automatic/History PDF/CSV/JSON, Master Report and an embedded preview. The trial recorded 9 source files, 5 selected files, 33,555,613 bytes and a 61 MiB app peak. All 11 expected nonempty artifacts, including the trial record, were present; the test reported cleanup of its own three fixture children.

The private wrapper nevertheless wrote `failed-retained`: it expected `** TEST SUCCEEDED **`, while this action emits `** TEST EXECUTE SUCCEEDED **`. The reviewed result bundle reported exactly one passing test; trial/artifact checks passed too. This bookkeeping defect was identified but **not corrected before reboot**. Preserve the rejection, recover the bundle and correct/re-run receipt validation without repeating the transfer just to change the wrapper status. This is not a signed-app manual walkthrough or the planned 119.6 GB actual-app test.

## Read-only recovery after reboot

After Mike reconnected T9, the known build image was mounted read-only, its volume identity checked, and nine named result bundles read at low process priority. The owned image was then detached normally; the physical T9 remained connected. No build, test, transfer, PDF render, writable image mount or user-media scan ran. About 1.3 MB of small records were saved outside temporary storage. The [compact recovery record](report-result-recovery-2026-10-21.json) retains counts and raw-record hashes without private mount paths.

Recovered results confirm the full Mac suite (1,435 passed, 35 skipped), 27 focused PDF tests, passing fixed/mixed PDF probes, the passing 20-clip preview probe, and the earlier coordinator stress pass. The failed all-wrapped baseline and original coordinator memory failure remain failed. The PDF logs retain their 20,000-file/40,000-row pass/fail markers; the baseline retains its `guardTriggered` error. This does not independently recover the detailed memory samples or the original full-manifest/visual validation receipts.

The small physical app result was independently read again: exactly one named test passed, zero skipped/failed, with its 4.153-second duration. Its saved log retains one distinct trial and the full completion marker for two backups, real journal, independent hashes, embedded previews and cleanup. Aggregate log sections repeat these lines, so they were deduplicated; test identity and counts establish the single execution. A separate recovery receipt records that test pass without rewriting the lost private wrapper's original false rejection.

The modern summary command tried to create a SQLite cache for some bundles and refused the read-only volume. Raw result-object reads recovered their status/counts/logs without modifying the image or copying large bundles. Full-suite raw counts include parameterized runs; the modern summary's 1,470 definitions remains authoritative for that total.

The final raw PDFs, preview JPEGs, detailed memory JSON and eleven physical app artifacts were **not recovered** by this pass. The saved archive inventory covers seven older PDF experiments, not those final artifacts; its compressed payload was not decompressed or rehashed. The physical engine matrix used a separate direct-test log and is not revalidated by these app bundles. Recover any other available evidence before deciding which missing artifacts require a new bounded probe.

## Earlier failures and cleanup

The original app-host gate `mac-manyfiles-20261021T053629Z` failed its guard during reporting: copy/verification drained at 392 MiB, reporting started at 421 MiB, the guard latched at 1,099 MiB and diagnostics later reached 1,309 MiB. MHL/previews were off. It was not an OS crash or #23 reproduction; that run did not isolate the allocation cause.

Earlier renderer experiments are historical: eager baseline 1,097 MiB; lazy synchronous generation 996 MiB, rising to 1,535 MiB during in-process PDFKit extraction; async buffered 1,030 MiB; text-status cells 1,000 MiB; streamed sink 985 MiB; 8-page composition 1,012 MiB; 64-page composition 1,034 MiB; PDFKit composition 1,614 MiB. The current design uses one context and separate-process bulk extraction.

A private recorder-error marker appeared during the first report-off app pass, before PDF generation. Its writer discards the underlying error. Contention is an unproven hypothesis; deterministic writer tests and privacy-safe failure stage/code reporting remain separate work.

The earlier physical matrix stopped after five successful operations with two generic Thorough source-stability rejections. Four retained-source Thorough operations and the later nine-operation matrix passed; neither explains the original rejection. Recover available failed-run evidence before changing a guard.

Before reboot, seven closed PDF gates were archived and verified on the SSD. Removing ten archived PDF/PNG files recovered 521,621,504 allocated host bytes. Two passed large synthetic drive children were removed after evidence/identity checks: 239,200,093,336 logical bytes across the SSDs. Their allocated bytes were not recorded and are not estimated. Unresolved physical fixtures and the current matrix children were preserved at cleanup; post-reboot availability has not been checked.

Today remains limited to low-impact work: small source reads, documentation and the authorized read-only result recovery above. Finish the remaining artifact and platform gaps before merging; see the [review and PR draft](report-memory-review-2026-10-21.md). No post-reboot build, test, rendering, user-media scan, large cleanup, signing change or Actions run was performed for these updates.
