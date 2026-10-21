# History app-host scale probe — October 20, 2026

The focused macOS app-host probe passed on the branch based at `main0a50ee5c`. It exercised the actual `LocalTransferJournal`, History search model, `TransferLibraryView`, and `TransferQueueSection` using an owned synthetic journal. No production History, app container, user bookmarks, connected drives, media, or physical device was accessed. The probe and its fixtures are opt-in and bounded; they do not change retention or journal behavior.

## Fixture and coverage

The fixture contained 500 attempts with 100 result rows each (50,000 result rows, 26,345,851 journal bytes). One `.running` attempt was recovered as `.interrupted`; one result missing its legacy ID received a durable ID on reload. The test searched a saved clip, verified 100 JSON and CSV export rows, retried an `.issues` attempt while preserving its old rows and retry linkage, checked search snapshot invalidation after journal publication, and verified repeated completed-queue presentation reused its eight built summaries. It hosted and rendered the actual History view with one expanded record and the queue section at 580 × 760 points.

## One passing Mac app-host run

The probe ran as `BitMatchTests/HistoryAppHostScaleTests/testActualHistoryAppHostScaleProbe` through `Scripts/test-history-app-host-probe.sh`. The wrapper forwarded opt-in variables through Xcode's `TEST_RUNNER_` environment convention, disabled parallel testing, used two build jobs, and required the actual test to pass without a skip plus a complete receipt.

| Measurement | Observation |
| --- | ---: |
| Journal startup including recovery/migration | 0.328 s |
| Second journal open | 0.160 s |
| Search index builder callback | 2.491 s |
| Search matcher callback | 0.052 s |
| History host layout and PNG render | 2.015 s |
| Queue host layout and PNG render | 0.345 s |
| History render output | 282,559 bytes |
| Queue render output | 168,510 bytes |
| App-test process physical footprint, initial / peak / last | 47 / 286 / 175 MiB |
| Main-actor pulse maximum over the whole probe | 6,451.8 ms |
| Process footprint samples | 1,426, sampled every 10 ms |

These are single-run observations on a shared Mac, not performance thresholds. The app-test process footprint includes XCTest, AppKit/SwiftUI, fixture encoding, model work, and allocator caches; sampling can miss shorter peaks. The recorded search callback breadcrumbs give the index-builder and matcher intervals, while the `searchFinished` checkpoint precedes those callbacks in the receipt. Therefore they do not establish an end-to-end user-visible search latency.

The 6.45-second main-actor pulse delay covers the entire test process. It is not evidence of a production History stall or a cause of issue #23. The run's original phase tags could cross phase boundaries while a pulse waited for the main actor, so no phase-level attribution is claimed. The follow-up instrumentation assigns a delayed pulse to the phase interval with the greatest overlap; this is an attribution heuristic for the wait interval, not proof that the named phase caused the delay. That instrumentation was made after the first passing run. The earlier run does not validate it; the revised-harness result below does.

The current harness stops the responsiveness timer and drains its one queued main-actor pulse before taking the final timing snapshot. It writes a `.pending` diagnostic snapshot before the final assertion gate, then removes the owned fixture and writes the `complete: true` JSON receipt only after cleanup succeeds. The runner matches only the final `.json` receipt. A cleanup failure therefore cannot leave a success-shaped final receipt, and a failed assertion can retain its pending measurements and fixture for review. These timing-drain and receipt-ordering corrections are newer than the first recorded pass; their subsequent passing run is recorded below.

## Failed and incomplete attempts

The first attempt stopped at compile time because two async view-settlement calls lacked `try`; the correction was made before the passing run. A later test attempt failed a raw JSON substring assertion. A subsequent structured JSON and CSV row/path check passed; the mismatch was in the test's raw-text assumption, not missing export rows. That failed attempt emitted a receipt and deleted its fixture because the harness did not yet gate successful receipt/cleanup on XCTest's failure count. Its run remains preserved and is classified as failed. The harness now throws before writing a successful receipt or deleting an owned fixture if any XCTest assertion failed.

One actual XCTest pass was also rejected by the wrapper because the phase receipt lacked a required fixture-preparation phase. The later passing run satisfied the stricter wrapper, but its phase labels remain qualified as described above. Logs, result bundles, and receipts remain under the task's private temporary evidence root; failed runs were not overwritten.

## Scope and limits

This measures a macOS app-test host and actual SwiftUI view rendering, not interactive user input, simulator memory, or a physical Mac/iPad/iPhone transfer session. Queue presentation covered eight completed rows and cache reuse, not an active transfer beside a long History list. Search used one targeted synthetic query. No reproducible product inefficiency was established, so this task makes no production persistence or retention change. The earlier [engine-only journal probe](history-memory-2026-10-20.md) is a separate measurement and must not be combined with this app-host footprint.

## Revised harness rerun

The final 500-attempt / 50,000-row app-host run passed with the overlap-based pulse attribution, pending/final receipt ordering and pulse drain. Its actual focused XCTest passed without a skip; the complete JSON receipt records `cleanupComplete: true`, and the owned fixture was removed. The combined Mac suite separately passed 1,411 tests, skipped 34 and failed none; the iPhone/iPad simulator build succeeded. This does not provide mobile History runtime evidence.

The revised run serialized 26,675,351 journal bytes and recorded 1,460 process-footprint samples: initial 45 MiB, peak 344 MiB, last 332 MiB. Journal load took 0.341 s and reload 0.164 s. Hosted History layout/render took 2.088 s after its layout-start checkpoint, and queue layout/render took 0.346 s; PNG outputs were 284,704 and 168,510 bytes. The run retained the same recovery, migration, retry, export and queue-cache assertions.

Its longest main-actor pulse was 6,296.8 ms, heuristically assigned to the broad History-view phase. That phase begins before host-view/window construction, while the narrower layout checkpoint begins later. There was a roughly 6.24-second interval between the export/retry checkpoint and the layout-start checkpoint. This warrants profiling of setup/view construction, not attribution to one production function or issue #23. Search callback keys are reused after the retry-triggered index rebuild, so their saved intervals cannot be combined with the first search's completion checkpoint to invent an end-to-end duration. The earlier 286 MiB result remains a distinct run; the higher final peak is not evidence of a leak by itself.
