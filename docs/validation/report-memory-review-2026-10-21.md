# PDF review and merge checklist — October 21, 2026

## Working agreement

Mike needs this Mac on set. Work is limited to small source reads, documentation and a local PR draft until he authorizes more. No builds, tests, rendering, simulators, drive scans, image mounts, large cleanup or background test jobs. No merge, release, tag, signing, updater or GitHub Actions changes.

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

This draft describes the PDF slice, not every earlier reliability change. Confirm its base against the held #79–81 stack before creating or updating a PR. Do not include abandoned experimental implementations or claim that GitHub currently contains this local candidate without checking.

## Before merge, when testing is authorized again

- [x] Record the reproduced ordinary/app and wrapped-report failures separately from hypotheses about #23.
- [x] Complete final-source full Mac testing and generic iPhone/iPad app build; record skips and build-only limits.
- [x] Record independent all-wrapped content checks, preview inspection, deliberate-regression results and physical test scopes.
- [ ] Recover and inspect available result bundles from the surviving external image. Inventory lost versus recovered evidence; do not mount it during the current low-impact period.
- [ ] Preserve the app-wrapper rejection and correct its `TEST EXECUTE SUCCEEDED` recognition. Revalidate the saved one-test result/trial/artifacts; do not rerun media copying solely to alter wrapper bookkeeping.
- [ ] Finish independent content/visual checks for the final mixed artifact. If its PDF did not survive, regenerate only the necessary probe after approval.
- [ ] Add direct native-row ellipsis/wrapped-Unicode assertions, check fallback control text and compare resolved native/fallback colors. Compile and run the affected Mac and iOS tests; the current generic app build did not compile or execute the iOS test target.
- [ ] Repeat the 20,000-file coordinator report-off/on probe on final production source. The recorded 682 MiB pass predates wrapped-row support.
- [ ] Finish the relevant signed-app/manual and mobile checks, review the final combined diff and confirm PR dependencies. Record what remains untested rather than treating an automated app-host pass as a manual walkthrough.

Keep #10, #23, the unexplained Thorough source-stability rejection and the diagnostic-recorder error as separate open investigations. Passing later runs do not identify their causes. Existing source identity, readback, coverage and no-overwrite rules stay strict. Merge and publication remain on hold.

## Documentation audit

The public README still describes the selected-file versus whole-card verdict correctly and already invites real-world bug reports. Its informal wording was preserved. No unreleased memory result was advertised as a shipped fix. The TODO now removes completed PDF/matrix checks from the pending work, and the overnight record points to the later results without rewriting earlier failures as passes.
