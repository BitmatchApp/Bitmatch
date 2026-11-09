# Source faults and retry: proposed contract

Status: partially implemented November 9 (unvalidated — no builds or tests run). `SourceFaultLineage` in the engine walks explicit `retryOf` links (bounded, cycle-safe) and returns an explicit assessment — `noFaultObserved`, `priorFaultFound`, or `lineageIncomplete` — so a broken chain is never presented as proof of a healthy card; only `noFaultObserved` may support a safe-to-erase claim. A pending settings-import failure now surfaces as a visible Settings warning instead of a silent retry or discard. The finish screen, finish notification, queue rows, History detail, and the eject guard downgrade an otherwise safe-to-erase verdict when a prior fault is found, while still reporting the new backup as verified. Automatic source retry and a cross-attempt card-health verdict remain unimplemented, as do project-card retries. Single-record exports (CSV/JSON/PDF regenerated from one record) cannot see lineage yet and still use the record's own verdict.

## Separate facts

Record a card identity change, inconsistent source content, and a source read error as distinct bounded reasons where the engine can establish them. Do not turn cancellation, a destination error, or an unclassified failure into a card diagnosis. A mismatch between repeated source reads establishes inconsistency within the observed scope; it does not identify the physical cause. A repeatably wrong source can still pass a comparison.

## Continuity across attempts

A failed attempt remains immutable. A retry is a new attempt linked to its predecessor, with a newly checked source identity and inventory. Traverse only explicit, same-source retry links with a bounded cycle check; a missing predecessor, ambiguous legacy identity, changed source, or broken chain is unknown, never proof that no warning exists. Project-card retries need their own durable linkage rather than borrowing ordinary-transfer assumptions.

Persist source-health observations independently of the new attempt's file verdict. If any applicable earlier attempt recorded instability or a source read fault, the retry's completion, queue, History, and exported evidence must retain a warning against erasing or reusing the card, even when the new backup reads match. This warning and the safe-to-erase decision must derive from the same durable facts. A successful backup may be reported accurately without calling the card safe. Do not silently clear a warning because the app restarted, evidence was truncated, or a later attempt passed.

## Bounded retry

No chunk or byte-offset retry is authorized by this design. Before implementing one, define the precise retryable errors, maximum attempts and delay, per-read identity and digest continuity, and cancellation behavior. Preserve each observed fault and attempt count. A changed source, inconsistent bytes, exhausted budget, or inability to prove continuity ends the attempt as an issue. Retries must not overwrite destination files or convert an incomplete result to verified.

## Evidence handoff

Media readback and requested manifest/report publication are separate facts. A failed evidence handoff after successful media verification must retain those media results and disclose the missing evidence. A later handoff-only action requires fresh backing-media validation, a new linked attempt, and exclusive publication; it cannot overwrite a prior report or manifest.

## Required checks

Cover ordinary and project retries, repeated faults, different and replaced cards, missing or cyclic lineage, stale and malformed records, app restart at each boundary, cancellation, incomplete result rows, report and manifest failures, and independent failures on different destinations. Verify warning and verdict agreement across Mac, iPhone, iPad, History, CSV, JSON, and PDF. Exercise real disconnected and unstable media only with disposable data, and keep those results distinct from synthetic fault injection.
