# Fan-out cancellation test readiness — October 20, 2026

The fan-out cancellation regression now waits for the second destination's first write hook before requesting cancellation. The change is confined to `Packages/BitMatchEngine/Tests/BitMatchEngineTests/FanOutTests.swift`.

The hook sends a buffered readiness event, then waits in its existing cancellation-aware test sleep. A structured task group owns the transfer, readiness waiter and caller watchdog. The test requires actual write entry before explicit cancellation and a `CancellationError` outcome afterward. Failed requirements, early errors and caller cancellation cancel and join the children before fixture cleanup. The test also checks zero successful results, no published destination files and unchanged source bytes.

The 10-second watchdog reports a liveness failure. It bounds this cooperative injected sleep; it cannot impose a hard deadline on arbitrary uninterruptible filesystem I/O.

## Local checks

Both engine frameworks ran sequentially on arm64 with four build jobs, `--no-parallel` and an owned scratch directory. Each command disabled the other test framework.

| Gate | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| Full engine XCTest | 205 | 43 | 0 |
| Full engine Swift Testing | 217 | 6 | 0 |
| Focused FanOut suite | 25 | 0 | 0 |

The full gates cover 422 passing cases and 49 skips; the focused cases also appear in the full Swift Testing run. Skipped physical-media, large-memory and other opt-in checks remain unrun. Swift Testing produced native XML. SwiftPM accepted `--xunit-output` for XCTest but created no XML; its preserved log contains all 248 per-case outcomes and the final summary. A clearly labeled XML summary derived from that log accompanies the private receipts.

## Isolated regression proofs

Each variant ran in an owned package copy, leaving the real source unchanged.

| Variant | Observed result |
| --- | --- |
| Original test, with a controlled 3-second delay before its stall signal | One expected failure at the old 2-second readiness assertion, after 2.021 seconds. |
| New test, with the same pre-entry delay | One pass after 3.128 seconds. |
| New test, with only explicit cancellation forwarding removed from the production copy | One expected failure after 10.546 seconds: the terminal event was `watchdogExpired`. |
| New test, with its post-entry requirement forced to fail | One expected failure after 0.117 seconds. An independent hook-defer flag confirmed that the blocked hook exited before fixture cleanup. |

The final real-source FanOut run passed all 25 cases after the private variants. All 125 engine/test Swift file hashes matched their frozen pre-proof values. Owned proof copies and build caches were removed; logs, XML, source variants and hash receipts were retained.

The controlled delay demonstrates the old readiness assumption. It does not reproduce or establish the cause of the earlier sporadic full-suite timeout, and it establishes no field-issue fix. This test-only change received no app UI or physical-device walkthrough.
