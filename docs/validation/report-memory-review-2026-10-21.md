# PDF review and merge checklist — October 21, 2026

## Working agreement

Mike needs this Mac on set. Work is limited to small source reads, documentation and a local PR draft until he authorizes more. Reconnecting T9 subsequently authorized read-only recovery of its known result image; that image was closed afterward. No builds, tests, rendering, simulators, user-media scans, writable image mounts, large cleanup or background test jobs. No merge, release, tag, signing, updater or GitHub Actions changes.

Production candidate: `1f73beba5d17bc1ce5b259ac67ab9243dd8b9c1c` on `fix/pdf-report-memory-20261021`. The documentation update changes no app or test source. [Exact observed results and evidence limits](report-memory-2026-10-21.md) are recorded separately.

## Source review

The review covered `ReportPDFRenderer.swift`, the report's native/fallback row factories and the Mac/iPad PDF tests. It found no evident row-data or status-mapping defect. Source inspection is not a new runtime or visual pass.

- Native and fallback rows obtain the same filename, backup label, formatted size and status presentation. Preview-bearing rows remain on the SwiftUI path. Quick's presentation remains unverified.
- SwiftUI supplies heights and pagination for both paths. Native text uses the measured row bounds; per-page prepared lines are released with that page. Tests cover short-row alignment, wrapped head/tail placement and following-row/footer separation.
- The sink checks partial writes and EINTR, retains write failures, verifies final bytes and file identity, and returns data only after finalization. Cancellation remains throwing. The sink buffer and private ownership checks have a purpose; replacing them with an in-memory buffer would undo the measured improvement.
- Lazy row factories, the native text path and the bounded file sink address different allocations. No safe simplification was identified from this review. Earlier unused composition phase/error cases were already removed in `296663ef`; the final source uses one PDF context.

Three questions remain for later checks, not confirmed production defects: direct row-local ellipsis/wrapped-Unicode assertions; actual PDF rendering of control-bearing fallback filenames; and resolved-color parity between native fixed colors and SwiftUI fallback colors. The last question does not establish a visible mismatch. No code was changed speculatively.

## Local PR draft — not submitted

**Title:** Reduce memory use in large PDF reports

Generating a report with many files could push memory above 1 GiB after copying and verification had finished. Long filenames exposed a second case even after ordinary rows improved. Build report rows lazily, draw eligible text with shared native fonts, and write the PDF through a private buffered sink. Keep the measured layout, previews, recorded results and verification rules intact; cancellation and output errors must not return a partial report.

The all-wrapped 40,000-row probe dropped from a measured 1,624 MiB guard failure to a 191 MiB pass with every manifest row independently checked. The final Mac suite passed 1,435 tests, skipped 35 and failed none; the generic iPhone/iPad build passed. A 20-clip synthetic 4K preview probe, nine-operation physical engine matrix and small physical app-host workflow also passed within their recorded scopes. See the validation record for earlier-source app stress results, the wrapper's false rejection and remaining platform/evidence checks. These results do not reproduce or close #23.

This draft describes the PDF slice, not every earlier reliability change. Its intended base is #81's branch, as checked below. Do not submit the whole stack as a second parallel change against `main`, include abandoned experimental implementations, or claim that GitHub contains this local candidate.

## PR dependencies checked October 21

Read-only GitHub metadata matches the local heads below. All three PRs are open drafts. Their reported `CLEAN` merge state describes Git's ability to merge, not a validation or release approval. GitHub Actions remains disabled.

| Slice | Base | Head checked | Disposition |
| --- | --- | --- | --- |
| [#79 — drive discovery and saved evidence](https://github.com/BitmatchApp/Bitmatch/pull/79) | `main`, `0a50ee5c` | `overnight/integration-20261020`, `79bfdfc9` | First held PR; 42 changed files against its actual base. |
| [#80 — source-stability diagnostics](https://github.com/BitmatchApp/Bitmatch/pull/80) | #79's branch | `fix/source-stability-diagnostics-20261021`, `23bd2599` | Eight-file slice, follows #79. |
| [#81 — reused-file progress](https://github.com/BitmatchApp/Bitmatch/pull/81) | #80's branch | `fix/reused-file-progress-20261021`, `f6323e02` | Eight-file slice, follows #80. |
| PDF memory candidate | Intended base: #81's branch | Production `1f73beba`, followed by documentation commits | Local work; no PR found for this branch in the GitHub check. |

Local ancestry confirms #79 → #80 → #81 → PDF. The PDF slice has no changes under `Packages/BitMatchEngine` relative to #81; it changes report/app test code and docs. Its production source is what received the final Mac build/tests, generic iOS build and small app-host physical check recorded above. The stale local `main` ref is not the comparison base: the verified GitHub/cached `origin/main` is `0a50ee5c`. No ref was reset, branch checked out, PR retargeted or remote source changed during this review.

When approved gates and review are complete, merge in dependency order. After each parent merge, recheck the next PR's base and net diff; a squash or rebase can require updating child branches. Any resulting source change must retain or regain the relevant validation. One eventual release can contain the reviewed stack, but none is authorized now. Keep the frozen signed 0.2.11 artifact separate from these later source changes.

## Before merge, when testing is authorized again

- [x] Record the reproduced ordinary/app and wrapped-report failures separately from hypotheses about #23.
- [x] Complete final-source full Mac testing and generic iPhone/iPad app build; record skips and build-only limits.
- [x] Record independent all-wrapped content checks, preview inspection, deliberate-regression results and physical test scopes.
- [x] Recover the nine key saved app-test records read-only. Their counts and selected workflow markers match the recorded passes and controlled failures; see the [recovery record](report-result-recovery-2026-10-21.json). This does not recover every original artifact or repeat any test.
- [ ] Recover other available raw PDFs, detailed memory/manifest receipts and physical-engine logs, or identify the minimal probes needed to replace missing evidence. The archive inventory inspected so far covers older PDF experiments.
- [ ] Preserve the app-wrapper rejection and correct its `TEST EXECUTE SUCCEEDED` recognition. The one-test pass and trial/settlement markers were recovered independently; the original eleven external artifact files were not. Do not rerun media copying solely to alter wrapper bookkeeping or fabricate those artifacts from a passing summary.
- [ ] Finish independent content/visual checks for the final mixed artifact. If its PDF did not survive, regenerate only the necessary probe after approval.
- [ ] Add direct native-row ellipsis/wrapped-Unicode assertions, check fallback control text and compare resolved native/fallback colors. Compile and run the affected Mac and iOS tests; the current generic app build did not compile or execute the iOS test target.
- [ ] Repeat the 20,000-file coordinator report-off/on probe on final production source. The recorded 682 MiB pass predates wrapped-row support.
- [x] Confirm the current PR bases, heads and local ancestry through read-only metadata and Git checks. This does not approve merging.
- [ ] Finish the relevant signed-app/manual and mobile checks, review the final combined diff and recheck PR dependencies after any source/base change. Record what remains untested rather than treating an automated app-host pass as a manual walkthrough.

Keep #10, #23, the unexplained Thorough source-stability rejection and the diagnostic-recorder error as separate open investigations. Passing later runs do not identify their causes. Existing source identity, readback, coverage and no-overwrite rules stay strict. Merge and publication remain on hold.

The tracked large-app receipt validator and History probe runner also expect the build-and-test success banner. Their current wrappers invoke `test`, so this does not establish a failure in normal tracked usage. Any future support for `test-without-building` should handle its different banner with focused parser fixtures, while retaining exit-status, exact-test, zero-skip, workload, receipt and artifact requirements. A banner alone is never sufficient evidence.

## Documentation audit

The public README still describes the selected-file versus whole-card verdict correctly and already invites real-world bug reports. Its informal wording was preserved. No unreleased memory result was advertised as a shipped fix. The TODO now removes completed PDF/matrix checks from the pending work, and the overnight record points to the later results without rewriting earlier failures as passes.
