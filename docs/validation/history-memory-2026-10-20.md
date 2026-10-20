# Local History scaling check — October 20, 2026

A bounded, host-only probe preserved synthetic histories containing up to 100,000 saved result rows through journal startup, a status update and reload. It did not reproduce runaway memory. The code audit still found whole-file work with no explicit history size limit; this is a scalability follow-up, not evidence of a leak or the cause of issue #23.

## What ran

An isolated Release CLI used a private copy of the engine sources from integration commit `953c779f51fef0277f6f2462e750e73964f6ef01`. No production code or retention policy changed. Fixture generation ran in a separate process from measurement. Each case had its own measurement worker; within that worker, initial load, mutation, reload and validation shared the same process.

Each record contained 1,000 distinct synthetic paths with two destination rows per path. Records began as `.issues` or `.interrupted`, and every row had a failed outcome. Resources referenced three tiny owned host folders, with empty bookmark bytes and no volume/file identities. No media transfer, bookmark resolution, selected-drive access, app host or Xcode test ran.

The measured operations called the actual `TransferJournal`:

1. Initialize from the saved journal, including its whole-file recovery rewrite.
2. Cancel one synthetic `.issues` record through the supported journal mutation, preserving its rows.
3. Release the journal and initialize a new instance from the same file.

Fixture construction, hashing and record validation had separate timing breadcrumbs. Canonical journal bytes had to remain unchanged across terminal-only startup and reload. After each of the three operations, every record and row ID and encoded field had to match deterministic expectations, except the one deliberately changed state, summary and end time. Every outcome remained unsafe. The probe completed 510,000 row-metadata validations across the three cases; all nine host-sentinel hash comparisons matched. All 43 copied engine source hashes remained unchanged.

## Observed results

These are single runs on a shared Mac while a separate physical-media validation was active, not controlled performance benchmarks. “Peak” is the external observer's sampled physical footprint of the entire measurement worker, including hashing, validation, Foundation and allocator overhead.

| Saved records | Result rows | Input JSON bytes | Initial load + rewrite | Status update | Reload + rewrite | Observed worker peak |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 20,000 | 7,131,876 | 0.090 s | 0.045 s | 0.083 s | 50.08 MiB |
| 25 | 50,000 | 17,829,701 | 0.218 s | 0.117 s | 0.202 s | 115.42 MiB |
| 50 | 100,000 | 35,759,566 | 0.434 s | 0.223 s | 0.427 s | 226.34 MiB |

All three cases passed. No memory guard or timeout fired. The parent sampled the exact owned worker's `proc_pid_rusage` physical footprint every requested 20 ms, with a 1 GiB threshold and a 120-second timeout per process. Inputs were capped at 64 MiB. The observer could interrupt only its own verified child with SIGINT; it did not use SIGKILL. Sampling can miss short peaks, and neither sampling nor SIGINT provides a hard ceiling on transient memory or synchronous filesystem calls.

After journal release and a 0.2-second wait, the workers measured approximately 38, 98 and 196 MiB. Those figures include earlier validation and Foundation/allocator caches; they are not steady-state leak measurements. Swift arrays use copy-on-write, so these results do not establish a count of independent deep copies.

The first measurement attempt was refused before journal access by an overly strict harness path comparison: Foundation standardized an existing temporary path differently from the expected raw path. The guard was corrected to compare the exact private paths while retaining ownership, device and no-symlink checks. The failed receipt was preserved, and the already successful 20,000-row fixture was reused only after its SHA-256 matched. That harness false negative was not a product failure.

## Separate static audit

The following findings come from code inspection, not the CLI memory measurements:

- `TransferJournal.init` reads and decodes the entire history file, then encodes and atomically writes every record, even if no running record needed recovery. Every subsequent mutation also encodes the complete array under the journal lock. There is no explicit record, result-row or history-file byte limit in this path.
- `LocalTransferJournal` invokes startup synchronously on the main actor. The CLI did not measure its effect on app responsiveness.
- History builds a clip-name/path/destination search index over all saved result rows when the view is initialized and when records are published. The CLI did not instantiate or measure this index or the app's views.
- The first-100-result limit in expanded History and `recent(limit:)` are presentation limits. Clearing finished queue cards removes their visible session membership while preserving their saved History evidence.
- Completed queue presentation still groups each selected record's rows to derive summaries. A separate TODO covers avoiding that repeated work. Report preferences and results contain metadata and settings, not embedded PDF or thumbnail bytes.

The next step is to measure larger saved-history use in the actual app, including search and completed cards beside active work, then design bounded loading and persistence. Any paging, summary cache, archive or explicit retention control must preserve durable evidence, retries and fail-closed verdicts across Mac, iPad and iPhone. This check does not justify silently pruning old results.

Private receipts retain input sizes and hashes, per-stage times, memory samples, canonical-data checks, the harness source and binary hash, and the initial harness failure. Synthetic CLI coverage does not replace real bookmarks, app layouts, mobile-device testing or investigation of the reporter's workload.
