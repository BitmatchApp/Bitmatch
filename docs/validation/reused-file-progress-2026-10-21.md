# Reused-file progress — October 21, 2026

This unmerged candidate fixes a progress gap during extra source checks on reused files. It changes presentation accounting, not verification, media reads or safety verdicts.

## Scope

An existing backup passes a reuse proof and then independent verification. When no fan-out source evidence is available, that later check hashes the source again. Standard had no budget for that source pass; Thorough could consume its shared reserve before both digest passes finished. Paranoid also compares source and destination bytes during the initial proof.

Proof hashes, later hashes and Paranoid proof comparisons now have separate, capped per-destination work budgets. Initial-present and raced `EEXIST` reuse use the same routing. Destination comparison reads remain real readback in the I/O counters; source work never becomes destination bytes.

Finished read bytes do not establish a successful verdict. A fresh-publication callback arrives after fan-out source evidence is recorded, so it can settle only that destination's known-unused hash and reuse-comparison reserves. Reused or unresolved destinations retain their possible work. Other unused reserves settle only after every destination actually verifies. The denominator stays fixed, and the existing authoritative completion path alone publishes 100%.

The weights estimate possible work; they are not literal I/O totals. Actual read/write byte and rate counters stay separate. Hash algorithms, cache policy, read order, assurance, concurrency, publication and terminal rules are unchanged.

## Local validation

- Focused progress/I/O gate: **22 reported Swift Testing tests, 2 suites, 0 skips/failures, 1.968 seconds**. It covers held initial and later hashes, both reuse entry paths, mixed fresh/reused backups, per-destination Paranoid budgets, exact I/O, pending verdicts, cancellation and failure.
- Five deliberate regressions each failed the intended assertion: omitted fresh-only reserve settlement, premature verdict settlement, fabricated fresh-source credit on reuse, collapsed proof/later hash budgets, and omitted destination comparison bytes. Every mutated source file was restored byte-for-byte; the checkout was clean afterward.
- Restored full engine Swift Testing: **267 reported tests, 41 suites, 6 opt-in skips, 0 failures, 26.130 seconds**.
- Full engine XCTest: **321 total, 83 opt-in skips, 0 failures, 180.257 seconds**. Mounted filesystem cases used normal detach; no force or retry was added.
- Mac app suite: **1,424 passed, 34 skipped, 0 failed** (1,458 total), verified from the result bundle.
- iPhone/iPad generic simulator build: **BUILD SUCCEEDED**, arm64 and x86_64. No runtime or physical-device walkthrough is implied.

The prototype first exposed a missing explicit closure capture and a hook type-inference diagnostic. Test execution then corrected two invalid assumptions: raced publication already has fan-out evidence for later verification, and an initial reuse-proof gate can precede the first I/O snapshot. The corrected tests retain strict final byte assertions. These were test/build corrections, not newly reproduced media defects.

## Remaining checks

A final combined physical matrix and additional opt-in app report/preview probes are pending. The retained SD source-stability rejection is a separate unresolved observation; four later Thorough operations passed without reproducing it. A physical pass cannot replace deterministic progress gates or explain field reports #10/#23. Actual-app hardware testing remains TCC-blocked; no unattended privacy retry is planned.

The last Mac gate predates a test-only private-diagnostics wrapper; the opt-in app probe compiles that wrapper, and the ordinary Mac suite will be repeated afterward. No release, signing, updater, Homebrew or CI change is included.
