# Reused-file progress — October 21, 2026

This is an isolated, unmerged candidate. Its implementation and tests have been reviewed statically; compilation and execution are pending the physical-drive test slot. Do not treat it as a passing release gate.

## Problem and scope

An existing destination must pass its reuse proof and then independent verification. Without fan-out source evidence, the later check hashes the source again. Standard had no progress budget for that source pass; Thorough could spend its shared reserve before finishing both digest passes. Paranoid also performs source and destination byte comparisons during its initial reuse proof.

The candidate gives proof hashes, later hashes and Paranoid proof comparisons separate, capped work budgets per destination. Initial-present and raced `EEXIST` reuse use the same phase routing. Destination comparisons remain real readback in the I/O counters; source work never becomes destination bytes.

Finished read bytes are not a successful verification result. Unused reserves settle only after every selected destination actually verifies. Reuse also avoids crediting a fresh source read that did not occur. Progress stays below 100% until the existing authoritative completion path.

These are conservative estimated-work weights, not literal I/O totals. Fresh transfers can settle unused reuse reserves near a successful verdict. Actual byte/rate counters remain separate. Hashes, cache policy, media reads, assurance, concurrency, publication and verdict rules are unchanged.

## Validation to run

- Focused engine tests: bounded initial-proof and later-hash gates; early and raced reuse; multi-destination Paranoid budgets; pending-verdict settlement; exact I/O counters; mixed fresh/reused destinations; failure/cancellation and terminal progress.
- Deliberate regressions: premature settlement, fabricated fresh-source credit on reuse, collapsed proof/later hash budgets and omitted destination comparison bytes. A compilation failure or zero selected tests does not establish red.
- Full engine Swift Testing and XCTest, the Mac app suite and iPhone/iPad build, with exact counts and skips retained.
- A physical repeat exercises the production path but does not replace deterministic progress gates. Keep any source-stability rejection separate from a progress regression.

No release, signing, updater or public-catalog change is part of this slice.
