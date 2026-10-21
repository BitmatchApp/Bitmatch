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

A later combined physical engine matrix passed nine operations across all four modes, both pipeline settings and Standard reuse. The final Mac suite on PDF candidate `1f73beba` passed 1,435 tests with 35 skips and no failures, and its generic iPhone/iPad build passed. The 20-clip 4K preview probe and small app-host SD-to-two-SSD workflow also passed within their scopes. The app-host wrapper misread Xcode's success wording; its result bundle reported one passing test, and receipt correction remains pending. See [exact results and post-reboot evidence limits](report-memory-2026-10-21.md).

The 682 MiB coordinator/report stress pass predates the final wrapped-row PDF change. Final-source stress, remaining platform checks and evidence recovery are listed in the [merge checklist](report-memory-review-2026-10-21.md). The separate SD source-stability rejection remains unexplained despite later passes. The planned 119.6 GB actual-app workload did not run; the small passing app-host check does not replace it. No physical pass replaces deterministic progress gates or explains #10/#23. No release, signing, updater, Homebrew or CI change is included.
