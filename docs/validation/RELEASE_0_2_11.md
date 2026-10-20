# 0.2.11 release validation

**Status: preparation in progress. Not released.** Planned version 0.2.11, build 21. The final integrated candidate, signing and publication results must be recorded below before release. No pending row is a passing check.

Base: `63f248b2be90e0aa9ee30328d24c119bf8198cf0`, containing the changes merged since `v0.2.10`. Local validation uses Xcode 27.1 (27A9275), Swift 6.4. GitHub Actions remains intentionally disabled; its absence is not a test result.

## Scope

- On-demand History clip search, cached completed-card summaries and fewer redundant journal writes.
- Serialized cooperating diagnostic writers and clearer final destination-identity diagnostics.
- Content-only Check for the supported classic MHL 1.1 inventory subset.
- Honest Quick-mode recovery/result counts and owned queued-preparation cancellation.
- Bottom mobile transfer controls and source-name layout at larger accessibility text sizes.
- Fresh readback for an existing empty file on exFAT, adopted into the engine branch and subject to the integrated gates below.

The individual merged batches retain their own records: [combined workflows](combined-workflows-2026-10-20.md), [History search](history-search-2026-10-20.md), [queue summaries](queue-summaries-2026-10-20.md), [journal startup](journal-startup-2026-10-20.md), [Quick summaries](quick-summaries-2026-10-20.md), [diagnostic writers](diagnostic-writers-2026-10-20.md), [cancellation readiness](fanout-cancellation-readiness-2026-10-20.md) and [MHL compatibility](../EVIDENCE_COMPATIBILITY_VALIDATION.md). These are earlier-revision results, not substitutes for the integrated release gates.

## Empty-file investigation and limits

The earlier physical matrix rejected a zero-byte file during Standard reuse. Strict repeat transfers did not reproduce that within-run failure. A later inode change between runs does not establish which branch rejected the original file or why. A remounted volume's changed device number is also not proof of within-run inode drift. Issues #10 and #23 remain open; this work does not establish their causes.

The new diagnostic event records a closed rejection reason, changed-field names, evidence-presence flags, file ordinal, destination index, byte count and POSIX error code where applicable. It does not export filenames, footage paths or raw filesystem identifiers. Existing private logs remain private.

The refresh is restricted to actual exFAT, Standard verification and a successful reused zero-byte file whose inode alone differs from the recorded readback identity. The device, size and timestamps must still match. It opens only an existing regular file through pinned, no-follow traversal, requires uncached EOF and matching original SHA-256/MD5 evidence, and retains the pin and reader through the result callback. Cancellation propagates; a failed proof cannot leave an accepted success. All new successful callbacks finish **before** the unchanged final source, destination-coverage and logical-root checks. Source bytes, destination bytes and ASC MHL readback policy are unchanged.

### Candidate evidence already reported

These results belong to the private candidate, not the final app:

| Check | Result and limit |
| --- | --- |
| Destination-identity diagnostic regressions | Eight XCTest cases passed. An isolated wrong-reason variant ran all eight and produced two assertion failures; restored code passed all eight. Production source stayed unchanged during that proof. |
| Fresh-readback candidate on actual exFAT | 37 cases passed, zero failures or skips, as reported by the implementation owner. The original intermittent failure was not reproduced. |
| Final-check ordering proof | Moving the prepass below the existing final gates made four selected methods fail with 36 assertions, covering earlier-file, earlier-destination, earlier-refreshed-file and source mutation across the selected pipeline modes. This is an injected mutation test, not a field reproduction. |
| Restored full candidate suite | 37 passed, zero failures or skips on actual exFAT. The repeated-proof descriptor observation remained 19 → 19. |
| Adopted source | The adoption receipt confirms only comment changes from the tested private candidate and preserves the earlier diagnostics. Branch validation follows below; integrated app gates remain pending. |

Private working receipts are under `/private/tmp/bitmatch-empty-reuse-20261020/DiagnosticProof/` and `/private/tmp/bitmatch-empty-reuse-v3-20261020/`. Preserve the logs, source manifests and failed fixtures; do not commit private fixture paths or raw file identities into public diagnostics.

The adoption receipt records these SHA-256 values relative to `Packages/BitMatchEngine/`:

- `Sources/BitMatchEngine/File/DestinationWriter.swift`: `87e69a00eb41e3e2edefbd1a8e72049d477dc7fef582bae3d2431174c17c3691`
- `Sources/BitMatchEngine/TransferPipeline.swift`: `90a6d7fe347d518d313fb2f385ce36df49b9337429b12f9e92e8b72e1dfc04f3`
- `Tests/BitMatchEngineTests/EmptyIdentityRefreshPrepassTests.swift`: `80cc211eac6bf80e67b2b88f45748f7d81e48194eb76c43b43ca8a0597dda080`

### Adopted engine branch

Commit `3e7105b4d57d0b961743f5e96709980db4d1c406` contains the reviewed implementation, diagnostics and regression tests. These results first ran on the engine branch. Its complete package tree, `856b1e9d3d8cc51499ce0cdef3cf18aac74f7410`, matches release commit `a6915935de0007ef95e4cc9c6f59259eb2d1bee7` byte for byte. The engine results therefore apply to the integrated package; app-host and signed-release checks remain separate.

| Check | Result |
| --- | --- |
| Full engine XCTest | 314 executed, 82 intentional opt-in skips, zero failures: 232 passed. |
| Full engine Swift Testing | Runner reported 245 tests in 41 suites, with six explicit opt-in skips and zero failures. |
| Adopted fresh-readback cases on actual T9 exFAT | 37 passed, zero failures or skips. The 128-proof descriptor observation stayed 19 → 19. |
| Final SD → T9 matrix | One XCTest completed 18 operations: three cycles, pipelining off/on, a fresh transfer and two existing-file retries per variant. Every operation completed ASC MHL and saved Check with independent hashes. |
| Source and earlier evidence | All 309 source files, totaling 281,771,367 bytes, matched the snapshot. Each operation selected 152 files, including 17 empty files. Existing ASC MHL histories remained unchanged. |
| Bounded filesystem pressure probe | 4,096 total entries across eight rounds; held and reopened identities stayed stable. This did not reproduce the original rejection. |

The matrix had one source and one physical backup. Its output includes a 256 MiB streaming fixture, small/boundary files and Unicode/deep paths. No destination-identity rejection occurred in the final run. Fresh proof of injected inode drift is covered by the separate 37-case suite; an ordinary green retry is not evidence that the refresh branch ran naturally.

Logs are `final-engine-xctest.log`, `final-engine-swift-testing.log`, `final-adopted-actual-exfat-37.log` and `final-physical-18.log` under the private candidate receipt directory. The physical summary is under the marked `attempt-11674a50-9957-45b9-886d-000364b900e1/artifacts/` directory. The final validation receipt binds these logs, source hashes and package tree. They are not a signed app walkthrough. Passed physical fixtures and generated build caches were removed with recorded identity/ownership checks; host evidence remains.

## Independent offline evidence checks

The release branch reran `Scripts/ascmhl/validate_classic_corpus.py` against the unchanged pinned classic reference CLI at `34f06f22ae965d12e49590adc301373d5ce611ff` and the exact primary-schema hashes. All **20 checks passed**, including schema validation, six Python MD5/SHA-1 and size records, original-media verification and same-size corruption/missing/truncated controls with their required exit codes. The permanent corpus remained unchanged, and disposable scratch was empty afterward. This verifies the external fixture and reference behavior; it does not run BitMatch's Swift reader, history writes or physical media.

The same release scripts passed **82 ASC corpus checks** against the unchanged official reference commit `0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687`: inventory/chain schemas, reference C4, original media and paths, supported and deliberately unsupported fixture algorithms, rename/directory lineage and disposable corruption controls with expected failure codes. The extended FAT-history fixture passed **six independent check groups** covering schemas/ordered generations/C4, its immutable original completion witness, official media verification and diff, changed-inventory rejection and unchanged originals. These checks validate the external corpus and history fixture; they do not regenerate BitMatch output, run the Swift reader or prove physical-drive behavior.

Receipts and logs are under `/private/tmp/bitmatch-release-0211-reference-20261020-1aq_4cyf/`: `classic-receipt.json`, `asc-receipt.json` and `cleanup-receipt.json`. The initial ASC attempt stopped before cases because package metadata was not installed; that setup failure is preserved separately. A private installation of the pinned tool corrected the environment without changing its tracked source. After the passing rerun, all 150 tracked reference files were hashed, the transient checkout/dependencies were removed, and 20 retained evidence files passed their SHA-256 checks. The retained artifacts total about 88 KiB and disposable scratch is empty. No global Python package or hardware was changed.

## Source-name layout branch checks

The final shared view in layout commit `673a1c55fd2d05c7ab04cf574e6e70709e1b5b41` has SHA-256 `4dff2dd21bdf76d9da3309fbdfa45c9a0f6beaea99d4c81f8b2c3cd4187420c2`. It gives the source its own row at accessibility text sizes, leaves remove/subfolder controls below, and supplies the selected name as its accessibility value. iOS targets stay at least 44 points; Mac buttons retain native compact sizing.

| Branch check | Result |
| --- | --- |
| Focused Mac captures | Two passed, zero skips or failures. |
| One-line-title mutation | One test executed and failed on missing rendered name words; restoring the view passed both focused cases. This was a behavioral failure, not a compile failure or empty selection. |
| Full Mac app suite | 1,371 passed, 31 opt-in skips, zero failures; 1,402 total cases in the summary. |
| Universal iOS simulator build | Succeeded for arm64 and x86_64. An earlier interrupted attempt remains recorded separately and is not a pass. |
| iPad source-name focus | One passed, zero skips or failures. |
| Full iPad simulator suite | 97 passed, zero skips or failures. |
| Full iPhone simulator suite | 97 passed, zero skips or failures. |

The implementation owner inspected 11 actual PNGs, including complete Unicode/long names at 375-point width and accessibility5, 760-point split-view layouts, normal bottom Start, and paused Resume/Cancel. OCR and geometry assertions separately check retained text and nonoverlapping controls. These are test-host renders and simulator suites, not physical touch, VoiceOver or external-storage validation. Full integrated version-21 app gates remain pending.

Receipts: `/private/tmp/bitmatch-source-accessibility-20261020/final-ui-validation.json`, `final-ui-commit.json`, `ResumeAX/receipt.json`, `ResumeMobile/receipt.json` and `final-visual-inspection.json`. Completed test bundles were compacted with their logs, summaries and images retained; the generated build cache was removed and both owned simulators were shut down after testing.

## Final integrated gates

Final candidate commit and source manifest: **pending**.

| Check | Result |
| --- | --- |
| Engine Debug, XCTest and Swift Testing | Passed on the byte-identical integrated package: XCTest 314 executed, 82 intentional skips, zero failures (232 passed); Swift Testing reported 245 tests/41 suites, six explicit skips, zero failures. |
| Engine Release, XCTest and Swift Testing | Pending. |
| Focused new diagnostic and adopted empty-file regressions | Eight diagnostic cases passed; 37 actual-exFAT cases passed on the byte-identical adopted package. Release-configuration repeat pending. |
| Mac full app suite | Pending. |
| Mac Debug and Release builds | Pending. |
| iPhone/iPad shared-code and device Release builds | Pending; identify simulator versus physical device. |
| iPhone narrow-width unit/rendering checks | Pending; record tested widths, text sizes and source names. |
| iPad split-view unit/rendering checks | Pending. |
| Mac source-name and affected workflow captures | Pending. |
| Offline updater checks | Eight passed as reported by the release owner; final receipt pending. |
| SD → T9 physical transfer, fresh and reused | 18 Standard operations passed on the byte-identical adopted package, with pipelining off/on, MHL, saved Check, independent/source hashes and earlier histories preserved. Separate signed native transfer pending. |
| Signed Mac app walkthrough | Pending. |

The available removable hardware is one T9 SSD and one SD card. The 18-operation matrix used one physical backup, T9. A separate signed native walkthrough may use a disposable internal APFS folder as a second backup only after identifying it as a physically distinct disk; record that topology explicitly. Two folders on T9 must not be reported as independent backups. Earlier two-external-SSD results retain their original revisions and limitations.

Keep all failed attempts, skips, permission stalls and corrected harness mistakes separate from passing reruns. Do not infer a successful result from a build, screenshot, elapsed time or 100% progress alone. Real-device VoiceOver, cable/power loss, mobile external-storage behavior and every possible drive/bridge combination remain outside synthetic coverage.

## Signed walkthrough

Launch the unmodified notarized production archive for startup, persistence and Settings checks. Do not reset the user's production settings, journal or source media. Disposable fixture workflows may use a separate Developer ID-signed copy with an isolated bundle ID, matching compiled binary UUIDs and matching sandbox entitlements. Record the identity changes and checks explicitly. That copy is not separately notarized, and its functional tests do not prove the published bundle's file-access grants or replace its startup/Gatekeeper checks. Both artifacts remain distinct in the receipts; the distributed app and DMG stay untouched.

- [ ] Notifications, Settings and menu-bar status/Open behavior.
- [ ] Copy → verification → ASC MHL → reports → saved result, including an existing-file retry.
- [ ] Source unchanged, independent destination hashes, intact prior histories and saved Check.
- [ ] Pause/Resume, confirmed Cancel and queued-preparation/Quit settlement; no late copying after cancellation.
- [ ] Main window hide/reopen and relaunch retain accurate active or interrupted state.
- [ ] Bottom mobile controls and large-text source layout inspected; record simulator and human interaction separately.
- [ ] Report/thumbnail and Check behavior remain honest about exclusions, Quick mode and one physical backup.

## Signing and publication

Run the existing release process without changing credentials or signing keys. `SKIP_NOTARIZE=1` is a diagnostic artifact, not a release pass.

| Step | Receipt |
| --- | --- |
| All marketing/build versions are 0.2.11 / 21 | Pending. |
| `Scripts/release_mac.sh 0.2.11` archive and signing | Pending. |
| App and DMG notarization, stapling and Gatekeeper | Pending. |
| Signed app version/build/minimum OS match expected archive | Pending; macOS minimum remains 15.5. |
| Signed walkthrough complete | Pending. |
| GitHub tag/release, DMG and matching SHA-256 | Pending; do not publish before all required gates pass. |
| Homebrew version/checksum and audit result | Pending; record any environment failure separately. |
| Sparkle signed appcast, published last | Pending; derive version, build and minimum OS from the archive. |
| Final published asset, cask and appcast comparison | Pending. |

Publish the GitHub release first, update Homebrew second, and publish Sparkle last. Keep public notes short and describe confirmed behavior. Do not announce the original empty-file rejection or either field report as solved without evidence.
