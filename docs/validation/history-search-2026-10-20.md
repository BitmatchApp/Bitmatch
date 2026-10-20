# History search on demand — October 20, 2026

Opening History used to build a clip index synchronously over every saved result, including when the search field was empty. Journal publications repeated that work. Search now builds its index and finds matches in a background worker only for a nonempty query. An empty query lists terminal records without inspecting result rows for search.

The view owns the search model. It retains one worker and one latest pending request; replacement work waits for its cancelled predecessor to settle. Indexing, ordering and matching check cancellation inside their loops. Request IDs, journal generations and normalized queries prevent old completions from replacing current results. Clearing the query or dismissing History releases the cached index; nonempty query edits can reuse it within the same journal snapshot.

Pending searches show “Searching…”, rather than old matches or a false empty History. A finished search with no matches and a search that could not finish have separate states. Duplicate journal record IDs fail the search rather than mixing one record's clip snippets with another's. This does not repair the journal.

Legacy Quick results retain their original saved statuses, but successful clip-search snippets now say “not verified.” Failure and intentional-exclusion qualifiers take precedence. Other verification modes keep their existing labels. Search never creates verification evidence or changes a transfer verdict.

## Focused evidence

The focused Mac app-host run passed 52 logical tests, including the opt-in 20,000-row probe; the parameterized cases expanded to 63 executions. There were no failures or skips. Tests cover index reuse, same-ID/count amendments, query replacement, dismissal/resume, explicit search failure/recovery, duplicate IDs, synchronous observer reentry, Quick-mode labels and real indexing/matching cancellation checkpoints.

The actual shared model, index and matcher also processed 200 synthetic records containing 20,000 metadata result rows in the Mac app-test process. It built one index and ran two completed matching passes across the requested query changes, then cleared the search. No indexing or matching callback ran on the main thread, and saved row IDs/statuses were unchanged.

In that single focused run, sampled process footprint rose from 71 MiB to a 91 MiB observed peak over 53 samples. Index construction took approximately 0.378 seconds; the fixture/probe reached its first complete result at 0.544 seconds and query clearing at 0.575 seconds from its initial checkpoint. These are observations on a shared host, not performance thresholds or isolated allocations attributable only to search. The fixture contains saved metadata, not 20,000 media files.

Ten mutation scenarios in private source copies produced actual assertion failures, followed by a restored green focused run. They cover Quick labels, empty-query indexing, snapshot/cache invalidation, cancellation inside both real loops, stale results, observer reentry, duplicate identities and main-thread indexing. The stale-result mutation removed overlapping cancellation and identity guards together; it does not prove each guard fails independently. The off-main mutation explicitly isolated the index-builder closure to MainActor; merely replacing `Task.detached` with `Task` did not establish a behavioral failure.

## Local regression checks

All checks used Xcode 27.1 and an owned DerivedData folder outside Desktop. Counts below are logical tests; parameterized cases can execute more than once.

| Check | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Full Mac app suite (`BitMatchTests`) | 1,328 | 25 | 0 |
| Full iPad Air 11-inch (M4), iPadOS 27.0 simulator suite | 75 | 11 | 0 |
| Full iPhone 18 Pro, iOS 27.0 simulator suite | 75 | 11 | 0 |
| Opt-in Mac search-state renders | 1 | 0 | 0 |
| Existing Mac workflow renders, including actual empty/expanded History | 1 | 0 | 0 |
| Opt-in iPad search-state and actual History renders | 2 | 0 | 0 |
| Opt-in iPhone search-state and actual History renders | 2 | 0 | 0 |

The full runs build the Mac and shared iPhone/iPad apps. The opt-in probe and snapshot checks are skipped by default and were run separately. No engine source changed. Existing compiler/toolchain warnings remain; the builds are not claimed warning-free. An initial focused compile caught an isolated `ObservableObject` conformance and a test-fixture initialization error; both were corrected before the passing runs.

Search loading, retry, no-match and empty-History states were rendered at Mac widths 580/1,100 pt and mobile widths 375/760 pt. The mobile checks also instantiate the actual History view with an interrupted saved transfer at 393/820 pt. The existing Mac workflow check renders actual empty and expanded completed History at 680 pt. Automated rendering and model tests do not constitute an interactive picker, keyboard, VoiceOver or physical-device walkthrough.

## Limits

This change does not bound total History bytes or solve journal startup/persistence. The journal still loads and rewrites its whole array, and collapsed row presentation still derives counts and safety summaries from saved results. Search indexes can grow with the supplied history; their lifetime and concurrent worker count are controlled, not their total byte size. Cancellation checks cannot bound a synchronous filesystem call already in progress.

The [earlier engine-only History probe](history-memory-2026-10-20.md) and this app-host search probe measure different paths. Neither reproduces issue #23 or diagnoses either open transfer report. Journal formats, retention, retries, exports, legacy UUID migration and transfer-engine behavior remain unchanged.
