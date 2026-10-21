# 0.2.11 release validation

**Status: local release gates passed with the limits below; release changes merged in #77, publication held. Not released.** Version 0.2.11, build 21, source `f74d8c7df999119084dd5c7d086fc6d206f7ace0`. Its full Mac suite passed 1,405 definitions with 18 intentional opt-in skips and zero failures; both iOS device and universal simulator Release builds passed. Its new signed artifact passed the existing release recipe, app/DMG notarization and 25 independent checks; ten read-only enclosed-app checks passed with clean owned detach. Final production startup/Settings and isolated signed fresh-transfer/refused-handoff checks passed, including independently checked PDFs. Native Dock inspection was unobserved; its focused regressions and full Mac suite provide the stated coverage. Publication remains pending. Signed `ad29248b` and `11402b0f` artifacts are superseded and must not be distributed; their evidence remains scoped to the recorded inputs. No pending check counts as passed.

Read-only GitHub metadata checked October 21 confirms [#77](https://github.com/BitmatchApp/Bitmatch/pull/77) merged as `ad6ecbf4`; the latest public release remains `v0.2.10`. This note records the frozen 0.2.11 artifact, not the later unmerged reliability/PDF candidate. That later work and its holds are in the [PDF review and PR stack](report-memory-review-2026-10-21.md#pr-dependencies-checked-october-21).

Base: `63f248b2be90e0aa9ee30328d24c119bf8198cf0`, containing the changes merged since `v0.2.10`. Local validation uses Xcode 27.1 (27A9275), Swift 6.4. GitHub Actions remains intentionally disabled; its absence is not a test result.

## Scope

- On-demand History clip search, cached completed-card summaries and fewer redundant journal writes.
- Serialized cooperating diagnostic writers and clearer final destination-identity diagnostics.
- Content-only Check for the supported classic MHL 1.1 inventory subset.
- Honest Quick-mode recovery/result counts and owned queued-preparation cancellation.
- Bottom mobile transfer controls and source-name layout at larger accessibility text sizes.
- Fresh readback for an existing empty file on exFAT, adopted into the engine branch and subject to the integrated gates below.
- Quiet completion for independently verified selected files when only recognized AppleDouble metadata was deliberately excluded; detailed evidence and conservative whole-card safety remain intact.

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
| Adopted source | The adoption receipt confirms only comment changes from the tested private candidate and preserves the earlier diagnostics. Integrated engine and app validation follows below; the signed walkthrough remains separate. |

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

The implementation owner inspected 11 actual PNGs, including complete Unicode/long names at 375-point width and accessibility5, 760-point split-view layouts, normal bottom Start, and paused Resume/Cancel. OCR and geometry assertions separately check retained text and nonoverlapping controls. These are test-host renders and simulator suites, not physical touch, VoiceOver or external-storage validation. Final integrated version-21 app gates are recorded below; the signed native walkthrough remains separate.

Receipts: `/private/tmp/bitmatch-source-accessibility-20261020/final-ui-validation.json`, `final-ui-commit.json`, `ResumeAX/receipt.json`, `ResumeMobile/receipt.json` and `final-visual-inspection.json`. Completed test bundles were compacted with their logs, summaries and images retained; the generated build cache was removed and both owned simulators were shut down after testing.

## Earlier integrated gates — superseded app candidate

Frozen earlier integrated candidate: `ad29248bf47e2bfad0fa4447a5d158e3ef381e4a`, version 0.2.11 / build 21, in [draft PR #77](https://github.com/BitmatchApp/Bitmatch/pull/77). Its engine package tree is `856b1e9d3d8cc51499ce0cdef3cf18aac74f7410`. All 687 tracked-file hashes, HEAD and clean status matched before and after the final app gates. Those gates predate the later quiet-metadata runtime changes. The initial signed artifact and partial native results are recorded below; later updated-app results are recorded below. The unchanged engine package retains its separately pinned engine results.

| Check | Result |
| --- | --- |
| Engine Debug, XCTest and Swift Testing | Passed on the byte-identical integrated package: XCTest 314 executed, 82 intentional skips, zero failures (232 passed); Swift Testing reported 245 tests/41 suites, six explicit skips, zero failures. |
| Engine Release, XCTest and Swift Testing | Passed on the frozen integrated package: XCTest 314 total, 232 passed, 82 intentional opt-in skips, zero failures in 122.685 s. Swift Testing reported 245 tests in 41 suites, six explicit skipped methods and zero failures in 15.459 s; this is not a claim of 245 non-skipped passes. |
| Focused new diagnostic and adopted empty-file regressions | Eight diagnostic cases passed in the full suite; all 37 fresh-readback cases also passed on actual T9 exFAT in optimized Release, zero skips or failures, in 6.929 s. The full engine run skips those physical opt-ins; this separate opt-in run supplies their actual execution. |
| Mac full app suite | 1,384 passed, 18 opt-in skips, zero failures; 1,402 total cases. Capture opt-ins account for the different skip count from the earlier branch suite. |
| Mac Debug and Release builds | Debug app/test host compiled and passed the full suite. An initial signed Release archive later passed for this earlier candidate; it is superseded. This earlier checkpoint was followed by the final `f74d8c7d` builds and full Mac gate below. |
| iPhone/iPad shared-code and device Release builds | Unsigned generic iOS device Release build succeeded for arm64; universal simulator Release succeeded for arm64 and x86_64. Both products record 0.2.11 / build 21. No physical mobile device was installed or tested. |
| iPhone narrow-width unit/rendering checks | 97 passed, zero skips or failures on the iPhone simulator; includes 375-point normal/large-text workflow and full long/Unicode source-name captures. |
| iPad split-view unit/rendering checks | 97 passed, zero skips or failures on the iPad simulator; includes 760-point split-view and narrow-width layouts. |
| Mac source-name and affected workflow captures | Passed within the full suite, including 580-point and wide source-name layouts at accessibility text sizes. Across the combined hosts, 212 PNGs were retained and nine were visually inspected; OCR and geometry checks are separate assertions. |
| Offline updater checks | Eight tests passed, zero failures, in 11.661 s. The runner stubs external signing, GitHub, Git and Xcode operations; it does not publish an update. |
| SD → T9 physical transfer, fresh and reused | 18 Standard operations passed on the byte-identical adopted package, with pipelining off/on, MHL, saved Check, independent/source hashes and earlier histories preserved. The later signed native checks below use T9 plus a separate internal APFS backup; they are not part of this one-backup matrix. |
| Signed Mac app walkthrough | Final `f74d8c7d` startup, fresh transfer and refused-history retry passed within the explicit native scope below; Dock inspection remained unobserved. |

Final combined app results and cleanup are in `/private/tmp/bitmatch-source-accessibility-20261020/ResumeCombined0211/validation-summary.json`, with exact source manifests, compressed raw logs, compact test results and `visual-inspection.json`. The generated app build cache and the exact owned simulator pair were removed after successful checks; screenshots and failure/mutation evidence remain. Simulator renders and builds do not prove external-storage behavior, direct touch or VoiceOver on a physical iPhone/iPad.

Optimized-engine and offline-updater receipts are under `/private/tmp/bitmatch-release-0211-20261020.3m9d8kwf/`: `engine-release-xctest.json`, `engine-release-swift-testing.json`, `engine-release-actual-exfat-37.json`, their raw logs and `offline-updater-tests.json`. The preserved engine-log SHA-256 values match `engine-release-cleanup.json`; the generated engine build cache was removed afterward without changing the frozen package. These passing engine checks do not replace the updated app-host gates or final signed walkthrough.

The available removable hardware is one T9 SSD and one SD card. The 18-operation matrix used one physical backup, T9. The separate signed native walkthrough used T9 plus a disposable internal APFS folder on a physically distinct disk, as recorded in its receipts. Two folders on T9 must not be reported as independent backups. Earlier two-external-SSD results retain their original revisions and limitations.

Keep all failed attempts, skips, permission stalls and corrected harness mistakes separate from passing reruns. Do not infer a successful result from a build, screenshot, elapsed time or 100% progress alone. Real-device VoiceOver, cable/power loss, mobile external-storage behavior and every possible drive/bridge combination remain outside synthetic coverage.

## Quiet-metadata update — earlier checkpoints

After the initial signed build, the walkthrough exposed repetitive metadata warnings in otherwise verified transfers. The user requested that default ignored companions stay out of the main result. The updated app uses the persisted expected-exclusion qualification, exact selected-file plan and positive verification digests to present a quiet selected-file finish. Failed handoffs, missing/failed/unverified rows, missing proof, Quick and cancellation remain attention outcomes. Queue restore now requires the same positive-checksum proof as live completion, so a saved verified label without a digest cannot release the next card. Raw history, detailed exclusions, whole-card safety and eject permissions are unchanged.

Focused Mac receipts are under `/private/tmp/bitmatch-source-accessibility-20261020/MetadataQuiet0211/`, summarized in `focused-validation-summary.json`, with the later selected-count capture run in `focused-final-preflight-render-green-summary.json`:

| Check | Result and limit |
| --- | --- |
| Final focused suite, including selected preflight counts | 238 test definitions passed, zero failures or skips; the device summary reports 259 executions including parameterized cases. Includes real standalone pipeline completion/report-failure routing, nil/empty-checksum journal reload, actual preview/default/preserve adapters, and source/Start captures. |
| Remove saved-selection proof | 28 cases executed, four failed and 24 passed. Actual assertions caught quieting real/legacy/partial outcomes; this was not a compile failure or empty test selection. |
| Restore status-only queue proof | 63 cases executed, two failed and 61 passed. Both missing/empty-checksum reload cases lost their saved pause, demonstrating the guard's effect. |
| Guard restoration and completion wording | Each passed all 193 definitions with zero failures or skips before the later preflight checks were added. The implementation owner inspected the actual 580-point PNG: neutral selected-file result, no metadata warning/count or retry prompt outside closed details. |
| Selected counts before Start | Passed in the later 238-case focus. Both setup adapters use reviewed selected counts; when selected bytes are unknown they show a count without guessing a byte total. Full inventory bytes remain the conservative capacity/readiness input. Pending or inconsistent reviews do not invent a selected count. |
| Updated full Mac, iPhone and iPad gates | At `3bd79b3`, Mac passed 1,399 cases with 18 skips, iPad passed 98, and the iPhone run finished with 94 passed/four failed. Test-host-only corrections followed in `bb93de36` and `11402b0f`. The corrected phone suite passed 99 cases; its unchanged phone path and the Mac gate are carried forward with explicit input proof. Final iPad passed 98 cases with one explicit phone-only regression skip and zero failures on `11402b0f`. Both final iOS Release builds passed on `11402b0f`; signed/native/publication status is recorded separately below. |
| Updated mobile Release builds, signed Mac build and native walkthrough | At `11402b0f`, both iOS Release builds, the unchanged Mac release-script retry, 25 independent artifact checks and read-only enclosed-app comparison passed. That artifact is superseded for final Dock/PDF presentation. The later `f74d8c7d` Mac/mobile builds and signing checks passed as recorded below; the final fresh/refused native checks passed within the limits below, while publication remains pending. |
| Merge and publication | Pending; no release asset, cask or appcast is approved by these focused checks. |

Two initial focused runs failed because the new tests were not ready. The first started before the asynchronous metadata review settled: both attempts correctly refused changed exclusions before copying, saved zero result rows and an interrupted record, and logged `kind=other`, code 3, `taskCancelled=false`, `explicit=false`. Waiting for the actual reviewed paths corrected the fixtures. The next run tried opening a second journal while the first still held its exclusive lock; releasing the first owner before reopening fixed that genuine reload test. Original logs, records and failures remain retained. Neither correction changed the expected safety outcome or established a production defect.

### iPhone capture-host correction and earlier platform builds

The complete `3bd79b3ff81418afe06a32ad4b34073551438fbd` run finished with Mac **1,399 passed, 18 opt-in skips, zero failures**; iPad **98 passed, zero skips or failures**; and iPhone **94 passed, four failed, zero skips**. The failed iPhone methods were the accessible-source-name, AppleDouble-control, readable-composer and viewport-action captures. The failed full run remains part of the record; later focused passes do not turn it into a passing full suite.

The original failed full-run log starts the native UI target at line 125, last records Landscape Left at line 306, then starts the unit/render target at line 332 without an intervening orientation reset (one-based lines). A controlled test then demonstrated the mechanism: a portrait 375-point capture inherited the landscape scene's 62-point safe area on each side, leaving only 251 usable points. The ordering evidence supports the inherited-scene explanation; the original captures did not record their numeric geometry, so the controlled measurement is kept separate. An isolated settings-helper predecessor run passed three of three cases, so that helper is not a proven cause and remains unchanged.

Commit `bb93de366d7c541680d6fab4887b4e19975c3cd1` changes only `BitMatch-iPadTests/WorkflowSnapshotTests.swift`. It uses supported scene-geometry requests to match orientation to the fixture, waits up to five seconds before capture, records orientation/insets/usable width, and requires a portrait capture to retain its full width. It adds a portrait-after-landscape regression. The broad orientation prerequisite then caused confirmed test-host timeouts on flexible iPad windows; that failed stage was interrupted and retained, without claiming completed full-suite totals. Follow-up `11402b0f5c46a246251ad12fa68f4de9c6fa31b7` restricts the request/wait to phone scenes and explicitly skips the phone-notch regression on iPad, while keeping the shared usable-width assertions. Production layout, transfer logic, Mac inputs and build settings are unchanged; OCR, touch-target and clipping assertions were not weakened.

| Capture-host check | Result and qualification |
| --- | --- |
| Forced-landscape negative control | The regression produced three actual assertion failures in 1.963 s, with 62-point left/right insets and 251 usable points. Xcode then stalled while finalizing the result and the owned run was interrupted after more than 180 s. This establishes the recorded behavioral failures, **not** a normally completed red test gate. |
| Corrected focused iPhone run | Six passed, zero failures or skips; the run completed normally in 98.852 s. Recorded orientation changed from landscape to portrait, both horizontal insets were zero, and usable width was 375 points. |
| Retained Mac suite from `3bd79b3` | 1,399 passed, 18 skipped, zero failures. The final handoff records equal production, Mac-test and configuration hashes through `11402b0f`; only the mobile snapshot test file changed. This is a retained exact-input result, not a new Mac rerun. |
| Corrected complete iPhone suite on `bb93de36` | 99 passed, zero failures or skips, in 266.0 s. Its first source capture directly records landscape before capture, portrait after the guard, zero horizontal insets and full 375-point usable width. The final handoff retains this full run for `11402b0f` with equal production hashes, an unchanged executed phone correction and a true phone guard proven by the later focus; it is not a second full-phone run. |
| Broad-prerequisite iPad attempt on `bb93de36` | Interrupted after confirmed orientation-wait assertion failures. `known-failed-stage-interruption.json` preserves the errors and stop signals; no completed full-suite pass or count is claimed. |
| Narrowed-host focus on `11402b0f` | Phone: five passed, zero failures or skips. iPad: four passed, one explicit phone-only regression skip, zero failures. The usable-width assertions remain active on both. |
| Final complete iPad suite on `11402b0f` | 98 passed, one explicit phone-only notch-regression skip, zero failures; 99 total, completed normally in 249.935 s. Before/after source manifests matched. Actual quiet-metadata, selected-count, large-text and bottom-action PNG checks remain separately recorded. |
| Final unsigned iOS device and universal simulator Release builds | Passed on `11402b0f`: arm64 device in 126.789 s; arm64/x86_64 simulator in 158.183 s. Both products record 0.2.11/build 21 and iOS minimum 18.5. Source manifests before/after builds and after cleanup matched. These are unsigned builds, not TestFlight or physical-device validation. |
| Final signed Mac artifact and native walkthrough | The unchanged release-script retry passed on `11402b0f`; 25 independent artifact checks also passed, as detailed below. The read-only enclosed-app comparison passed and detached cleanly. Later native checks and the final successor status are recorded below. No signed artifact was built from `3bd79b3` or `bb93de36`; the older `ad29248b` artifact remains superseded. |

The correction receipt is `/private/tmp/bitmatch-release-0211-20261020.3m9d8kwf/capture-host-correction-commit.json`. The diagnosis, completed green receipt, summaries, compressed raw logs, source manifests and geometry evidence are under `/private/tmp/bitmatch-source-accessibility-20261020/PhoneOrientationGreen0211/`; the interrupted negative-control evidence remains under `PhoneOrientationRed0211/`. Full `3bd79b3` results are under `MetadataQuietFinal0211/`; the interrupted broad-iPad attempt and completed phone run are under `MetadataQuietHostFinal0211/`. The phone-only focus is under `PhoneOnlyHostFocused0211/`, and `MetadataQuietPhoneOnlyFinal0211/receipt.json` records the final Mac/phone input proof and remaining final gates. Keep those inputs and outcomes separate. None is a physical mobile-storage, direct-touch or VoiceOver pass.

### Signed `11402b0f` artifact — superseded for final Dock/PDF presentation

The first final-source archive attempt exited 65 while Xcode signed Sparkle: **“A timestamp was expected but was not found.”** It reached neither notarization nor publication. `FailedFinalArchive1/` retains its receipt and log. Two later disposable framework probes passed: one requested a timestamp explicitly; the other repeated the exact original Xcode signing arguments with only the output path changed and also produced a timestamp. These probes did not change source, credentials or signing policy. The original failure's cause remains unproven; a transient signing-service failure is an inference, not an established diagnosis.

A retry of the unchanged `Scripts/release_mac.sh 0.2.11` process completed normally on `11402b0f`, exit zero. App and DMG notarization were accepted, tickets were stapled, and both Gatekeeper assessments passed. The `11402b0f` DMG is **9,157,308 bytes**, SHA-256 **`cc325d84c8a29c48a870a74a6f87d5be06427323bcc4623c2320b6f5d13ad242`**. This artifact includes the updated window presentation but precedes the later Dock-counter correction. Retain it as `11402b0f` evidence; neither it nor the earlier `ad29248b` image is the final distributable.

The independent artifact verifier passed **25 commands**, including strict signatures, staples, Gatekeeper, DMG integrity, universal arm64/x86_64 binaries, archived metadata and matching executable/dSYM UUIDs. The archive records 0.2.11/build 21 and minimum macOS 15.5. The public Sparkle Ed25519 signature was independently verified against the archived app's public key and exact final DMG bytes, without accessing/exporting a private key. Original artifacts remained unchanged. This verifies the local artifact/signature; it does not claim that a public release asset or appcast has been uploaded or checked.

The first private read-only enclosed-app checker stopped safely because its one-whole-device assumption did not account for an APFS image's backing disk plus synthesized container. That is a validation-harness assumption, not a product defect. Its separately retained recovery re-proved ownership of the exact private image and detached it without force. The corrected checker binds both reported device families and the actual read-only diskutil fields to that same fresh attachment, then detaches only its unique GUID backing. It passed ten commands: 66 regular files, six symlink targets and directory modes matched the archive; signature and original-artifact checks passed. The image was fully detached and the original empty private mountpoint was restored and removed. No app was launched, physical drive accessed or existing mount adopted. Content/mode/target equality does not claim cross-filesystem inode, ownership or extended-attribute identity.

Receipts are `signed-mac-release-final.json`, `ArtifactVerificationFinal-11402b0f/receipt.json`, `DMGContentFinalV2-11402b0f/receipt.json` and `FailedFinalArchive1/receipt.json` under the private release-evidence directory. The failed first image-check assumption and its verified detach recovery remain separate under `DMGContentFinal-11402b0f/`. Native checks of this artifact are recorded below. Final `f74d8c7d` signing and independent artifact checks passed as recorded below; its native verification/PDF inspection passed within the limits below; public distribution remains pending.

### Initial signed artifact and partial native walkthrough — superseded

The initial `Scripts/release_mac.sh 0.2.11` run passed for `ad29248b`. Its unmodified app and DMG passed signature verification, notarization, stapling and Gatekeeper; the independent receipt records universal arm64/x86_64 binaries, version 0.2.11, build 21 and minimum macOS 15.5. This artifact predates the quiet-metadata update and must not be distributed as the final candidate.

The unmodified notarized archive launched with the user's existing paused queue and saved settings intact, showed notification authorization, and retained the explicit preserve-metadata preference. The functional fixture app was a separately Developer ID-signed, bundle-ID-isolated copy with matching compiled UUIDs and sandbox entitlements, not a separately notarized or published bundle.

| Earlier native check | Result and limit |
| --- | --- |
| Fresh Standard Card transfer | Passed through verification, ASC MHL and PDF/CSV/JSON on the initial QA candidate: SD source, T9 exFAT backup and a physically distinct internal APFS backup. Five selected files and five reviewed exclusions produced ten verified results and ten excluded results across the two destinations. Independent hashes and completion-witness checks passed. Recorded source bytes, names, modes and modification times matched; separately disclosed zero-byte inode changes are not an unchanged-identity claim. |
| Same-folder existing-file retry with ASC MHL | All selected media reverified and reused; both requested handoffs correctly refused to extend or replace existing histories. Current saved summary and reports retained the exact refusal, no expected-exclusion completion qualification was granted, and prior histories/reports stayed unchanged. The private verifier passed this **refused-handoff** scenario; it is not a successful new MHL publication. |
| PDF clip preview | The first report contained a 256 × 144 frame from the synthetic clip. The walkthrough log records inspection of both PDF pages without clipping or overlap. This is earlier-candidate preview evidence, not final UI or a new verification of media. |
| Initial cancellation fixture | The 512 MiB fixture reached completion before cancellation was established. It supplies no Cancel, partial-file or retry-after-cancellation coverage. The later actual `11402b0f` cancellation/recovery checks are recorded separately below; this initial completed attempt remains no cancellation coverage. |

The first native checker incorrectly assumed the publication marker's initial operation UUID must equal the report's returned-operation UUID. The engine constructs those objects separately. The corrected private checker requires their explicit diagnostic correlation to one executor run/session; it also preserves prior evidence snapshots and discloses the narrowly observed empty-file inode changes. The failed checker attempt remains separate from the passing reruns; no runtime policy was relaxed to fit the harness.

Private earlier-candidate receipts are under `/private/tmp/bitmatch-release-0211-20261020.3m9d8kwf/`: `signed-mac-release.json`, `ArtifactVerification-3tejsxo3/receipt.json`, `native-walkthrough-observations.json`, `native-card-checked-rerun/summary.json` and `native-card-handoff-refused-rerun/summary.json`. Their source revision and limits remain attached to those results.

## Final Dock/PDF presentation and app gates

Commit `f74d8c7df999119084dd5c7d086fc6d206f7ace0` contains the final presentation follow-up. Durably qualified metadata exclusions no longer add an attention badge or amber Dock icon. Qualified PDFs use a neutral “Selected files verified” banner, list selected rows only and retain a small unique metadata count. Exact job/source/destination/mode/scope/count/row binding is required before either quieting the PDF or removing its generated caution paragraph. Unrecognized `._` files remain selected. The automatic proof follows authoritative acceptance and MHL/project gates, without prematurely saving final journal qualification. Raw CSV/JSON rows, notes and unsafe fields, whole-card safety and erase/eject permissions are unchanged.

The real MHL-failure PDF retains its warning, explains incomplete handoff evidence and labels its counter “file issues.” Actual refusal details stay in Notes. This avoids attributing a real handoff problem solely to ignored metadata.

| Final-source check | Result and limit |
| --- | --- |
| Dock pre-fix negative | Existing queue fixtures completed with 26 passes and two failures on the old production policy: both attention count and icon assertions discriminated the bug. |
| Dock restored focus | 31 passed, zero skips or failures. Missing proof, failed selected files, absent/empty checksums, MHL failure, Quick and unrelated attention remain conservative. |
| Initial PDF banner negative | 13 passed, two failed, zero skips before the proof-backed PDF presentation. |
| Selected-only PDF table negative | The corrected filename-extraction fixture completed with 18 passed and two intended visibility failures before the table filter. A separate earlier assertion included a PDFKit leading-dot whitespace mismatch and is not the discriminating proof. |
| Final PDF/Dock focused gate | 97 passed, six existing filesystem opt-in skips, zero failures; 103 definitions. Actual automatic, saved-History and MHL-refusal PDFs rendered and were independently inspected without clipping or overlap. Exact CSV/JSON excluded filenames/notes and unsafe fields remain; the newly written JSON binds the PDF hash. |
| Final full Mac suite | 1,405 definitions passed, 18 intentional opt-in skips, zero failures; 1,423 total. The device summary includes 1,551 non-skipped executions with parameterized cases. Process completed in 98.226 s. |
| Final universal iOS simulator Release | Passed for arm64 and x86_64 in 469.600 s. This builds the changed shared PDF code; it is not a fresh mobile interaction or full unit-suite run. |
| Final iOS device Release | Passed for arm64 in 216.987 s. Device and universal simulator products both record 0.2.11/build 21 and minimum iOS 18.5. |
| Retained mobile screen suites | Phone 99 passed at `bb93de36`; iPad 98 passed/one explicit phone-only skip at `11402b0f`. The final screen-retention receipt matches 67 mobile shell/test/non-PDF view inputs and explicitly excludes changed shared PDF code. Five later phone-focused cases prove its final phone guard. These are retained screen results, not full reruns on `f74d8c7d`. |
| Final signed artifact, startup/Dock and automatic PDF transfer | Final `f74d8c7d` signing/notarization, 25 artifact checks and ten read-only enclosed-app checks passed. Production startup/Settings and isolated signed fresh Card/refused-history checks passed with independent hashes/evidence checks and actual PDF inspection. Native Dock was unobserved. Both older signed artifacts are superseded. |

The six focused skips are existing filesystem matrix opt-ins: camera rename, case collisions, FAT32 large-file limits, the full synthetic matrix, the issue-10 HFS-to-exFAT executor scenario and project/report filesystem coverage. A separate added-test macro compile failure produced no test execution; its correction and log are retained, not counted as behavioral red coverage.

Receipts are under `/private/tmp/bitmatch-source-accessibility-20261020/`: `PDFTruthfulFinal0211/handoff.json`, `PDFQuietCompactFinal0211/handoff.json` and `FinalDockPDFAppGates0211/receipt.json`. The final full Mac summary/raw log, both build logs, `final-handoff.json`, before/after/after-cleanup source manifests and `mobile-screen-retention-proof.json` preserve the exact inputs. All tracked inputs remained identical throughout and after cleanup, and the nine changed Dock/PDF file hashes match the focused gate. The owner removed 984,535,040 allocated bytes of generated cache, preserving source dependencies, logs, test results and all evidence; that allocation is not a claim of net APFS free-space gain. No GitHub Actions or physical mobile-device validation is implied.

### Native `11402b0f` checks — retained scope, superseded PDF/Dock

These functional checks used the separately signed isolated QA copy with matching compiled UUIDs and sandbox entitlements. They are not fresh tests of `f74d8c7d`; its engine remains unchanged, while its PDF/Dock presentation requires a newly signed positive transfer below.

| Native check | Result and limit |
| --- | --- |
| Fresh Standard Card | `native-final114-card-checked` passed independent destination hashes, MHL/marker/report checks. Five selected source files and five recognized exclusions on two backups were correctly separated. Both PDF pages were inspected, including the clip frame on page 2. This establishes the old PDF/thumbnail only. |
| Actual pause/resume/cancel | Paused at 12%, retained pause through Quit → Keep Copying, resumed, paused at 21%, then explicitly cancelled. `native-final114-cancelled-checked` passed: T9 partial bytes/incomplete marker retained, no MHL/completed automatic report and unsafe saved outcome. Two earlier 512 MiB attempts completed before Pause and supply no cancellation coverage. |
| Unsafe same-output retry | `native-final114-unsafe-retry-v2` passed. The T9 partial remained failed/preserved; the fully verified APFS sibling legitimately created its own initial MHL. Overall safety stayed false with no completion qualification. |
| Fresh-folder recovery | `native-final114-fresh-recovery-v2` passed complete-file copying into new destination folders, preserving the old partial bytes, history, reports and journal attempt. This is not byte-offset resumption. |
| Source preservation | Original bytes, names, modes and modification times matched. The private checker separately discloses the already observed zero-byte Card inode drift after fresh EOF/hash proof; no source-identity stability or relaxed production gate is claimed. |

The old retry checker wrongly prohibited every MHL whenever any destination failed. Its failed receipt is preserved; the corrected checker permits only an exactly covered, independently read-back sibling with positive saved digests and one matching previously empty history root. Existing MHL files cannot be extended or changed. This is a harness correction, not an engine defect. Likewise, private folder preparation initially rejected the normal exFAT-generated AppleDouble directory companion; those small failure receipts and partial empty folders were retained, with no source or prior-output writes.

All receipts above remain under `/private/tmp/bitmatch-release-0211-20261020.3m9d8kwf/`. The old `11402b0f` archive and isolated app were moved intact into `SupersededCandidate114/` with identity/hash evidence, not republished. Final artifact verification and the scoped fresh/refused native checks passed as recorded below; retained controls apply only to their unchanged inputs. Publication remains pending.

## Final signed `f74d8c7d` artifact

The unchanged existing release recipe passed on its first attempt for the clean `f74d8c7d` source: Developer ID signing, accepted app and DMG notarization, stapling and Gatekeeper. The final DMG is **9,183,393 bytes**, SHA-256 **`c4211059f0b23747cbb14ef77d871d83cf94bac0b16d16aeadc09d3804f0c2d9`**. No signing credentials or policy changed. The earlier `11402b0f` timestamp failure and disposable signing probes remain separate historical evidence; they do not describe this successful first attempt.

Independent verification passed all **25 artifact commands**, including the original 18 checks, archive/dSYM UUID matching, universal binaries and offline public Ed25519 updater-signature verification against the app's existing public key. The archive records 0.2.11/build 21, bundle ID `BitMatchApp.BitMatch` and minimum macOS 15.5. All six Mach-O binaries carry arm64/x86_64 slices. The executable and dSYM UUIDs match: x86_64 `643EFC5E-A7DF-3F8D-8BD9-784B0EEA1A73`, arm64 `CFBC67FD-C65D-3F65-8DA0-ACA2A7F5F8B1`.

The read-only enclosed-app comparison passed **ten commands**: all 66 regular file contents, six symlink targets and directory modes match the archive. Both manifests hash to `d1ba235d8003275cf797bb80dcc441901fb5efe873c2ea33ca3a787939a52563`. The uniquely owned image detached, its device families disappeared and the private mountpoint was removed. Original app/DMG artifacts remained unchanged; filesystem owners, xattrs and cross-filesystem inode equality were not claimed. No physical drive was used by these artifact checks.

Build receipt/log: `SignedFinal-f74d8c7d/signed-mac-release-final.json` and `.log` under the private release root. Independent receipts: `ArtifactVerificationFinal-f74d8c7d/receipt.json`, `DMGContentFinalV3-f74d8c7d/receipt.json` and `independent-artifact-final-f74d8c7d-summary.json`. Build provenance is the clean exact source, existing build recipe and retained logs, not a compiled Git stamp. Artifact checks do not validate a native transfer or public downloaded asset. The final fresh Card and refused-history retry subsequently passed independent verification and PDF inspection as recorded below. Public distribution remains pending.

## Signed walkthrough

### Final `f74d8c7d` native checks — passed within stated scope

The unmodified notarized production app passed startup and Settings checks, including authorized notifications and preservation of the existing preferences, queue and 30 History records. Disposable fixture workflows used a separate Developer ID-signed copy with an isolated bundle ID, matching compiled binary UUIDs and matching sandbox entitlements. That copy was not separately notarized. Its destination folders had to be reselected after re-signing; its functional checks do not establish production bookmark persistence. The distributed archive and DMG remained unchanged.

The fresh Card run `BCF3DC5B-F37C-446D-BE6F-9E8D283C34D4` passed `native-f74-card-v4/summary.json`. A disposable SD source copied to physical T9 exFAT and a separate internal APFS backup. Setup and completion showed five selected files and two destinations, with five of five verified for each backup and no metadata-only attention message. Independent destination hashes, source bytes/names/modes/modification times, MHL content/chain/completion status, publication markers, operation linkage and terminal/root rechecks passed. The raw result still retains ten selected and ten excluded rows across both backups; whole-card safety remains false.

Both actual PDF pages were inspected: neutral “Selected files verified,” ten selected rows across five names/two backups, a small unique count of five metadata exclusions and the correct 256×144 synthetic clip frame on page 1. The PDF has no erase banner or excluded-filename rows in this qualified case, and no clipping. Its SHA-256 is `27056d02e73b761d1c8371115345d4e947a7e338740f8bcd0a8bf9c227ab7f2e` (87,285 bytes). The v3 and v4 copied PDFs are byte-identical, so their visual evidence applies to the same report.

The initial v3 checker stopped only at a PDF text-name assertion after its byte/source/MHL checks: extraction emitted `⾳` (U+2FB3) for the visibly correct `音` (U+97F3). Its failed receipt remains retained. The private v4 correction aliases that one extraction glyph only, rejects collisions between distinct source names or selected/excluded roles, and checks per-name multiplicity. Raw names, source/destination comparisons, runtime policy and all other assertions are unchanged. The completed v4 result passed; this was a harness correction, not a product Unicode failure.

History Retry then reused the same outputs with ASC MHL still enabled. Run `032F70C2-221E-4969-B2BB-1F191ABE3FB7` passed `native-f74-handoff-refused-v4/summary.json`: selected media verified, while the requested new history was correctly refused because existing ASC MHL histories cannot yet be extended or nested. No new history was published, completion qualification stayed false and the queue paused for the actual handoff problem. Earlier history/report bytes, file sets and the previous journal record remained unchanged. Both report pages were inspected: the warning correctly explains incomplete handoff evidence, shows zero file issues, keeps the actual ASC MHL cause in Notes and retains the full selected/excluded table and clip frame on page 2 without clipping.

The native checks disclose previously observed inode-only changes between reads of owned zero-byte exFAT fixtures. They prove fresh EOF/hash with all other original metadata unchanged; they do not claim that those inodes stayed stable or reproduce the original within-run rejection. Raw identities remain in private evidence only.

| Walkthrough coverage | Result and limit |
| --- | --- |
| Final production startup, Settings and profile preservation | Passed on the unmodified final notarized app. Notification status was Authorized; preferences, queue and 30 History records were retained. This is not a new notification-delivery test. |
| Final signed copy → verification → MHL → automatic reports → saved result | Fresh Card and refused-history retry passed the independent native checker and actual PDF inspection described above. Functional transfers used the isolated signed identity, not the public notarized bundle identity. |
| Source/readback and preservation | Source content and original names/modes/modification times, independent destination hashes, prior histories/reports and journal preservation passed, with the zero-byte inode observations explicitly disclosed. |
| Saved Check | Passed in the unchanged-engine 18-operation matrix. No fresh signed Check-screen interaction is claimed. |
| Pause, Resume, Quit → Keep Copying, explicit Cancel and recovery | Retained `11402b0f` controls, unsafe same-output retry and fresh-folder recovery passed within unchanged engine/coordinator/control-path scope. These interactions were not rerun on `f74d8c7d`. |
| Mobile bottom controls and larger text | Retained phone/iPad suites and inspected layouts apply through the explicit 67-file unchanged-input proof. Current shared PDF changes have the final Mac regressions and both iOS Release builds. No physical iOS storage, touch or VoiceOver walkthrough was performed. |
| Final native Dock, menu-bar Open and hide/reopen | Native Dock accessibility inspection timed out and is **unobserved**. Its 31 focused regressions and final full Mac suite provide automated evidence. Final native menu-bar Open and hide/reopen were not rerun; earlier release checks retain their original scope. |

Final observations are in `final-native-f74-observations.json`, with the individual v4 summaries and the failed v3 receipt retained separately under the private release root. QA exit was verified. After both final checks and PDF inspection, `native-walkthrough-cleanup.json` confirmed the source hashes and removed only the exact UUID-owned SD, T9 and internal fixture roots. It did not erase/eject a drive or touch unrelated data. The field reports remain open; their root causes are not established.

## Signing and publication

Run the existing release process without changing credentials or signing keys. `SKIP_NOTARIZE=1` is a diagnostic artifact, not a release pass.

| Step | Receipt |
| --- | --- |
| All marketing/build versions are 0.2.11 / 21 | Confirmed in all 12 marketing-version and 12 build-version project settings at the frozen candidate. Archived metadata remains a separate check below. |
| `Scripts/release_mac.sh 0.2.11` archive and signing | Passed first attempt on clean `f74d8c7d`, using the unchanged existing process. The old `11402b0f` failure/probes remain separately preserved; no credentials or policy changed. |
| App and DMG notarization, stapling and Gatekeeper | Accepted/passed for final `f74d8c7d`; independently verified within 25 commands. |
| Signed app version/build/minimum OS match expected archive | Passed on final `f74d8c7d`: 0.2.11/build 21, universal arm64/x86_64, minimum macOS 15.5. Ten enclosed-app checks passed and the owned image detached cleanly. |
| Signed walkthrough scope | Final `f74d8c7d` production startup/Settings and isolated fresh/refused native transfers, evidence checks and actual PDFs passed. Earlier controls/recovery are retained only for unchanged inputs. Native Dock is unobserved; physical iOS, final native menu/hide actions and field root causes are not claimed. |
| GitHub tag/release, DMG and matching SHA-256 | Pending; do not publish before all required gates pass. |
| Homebrew version/checksum and audit result | Final 0.2.11 publication/audit pending. A separate online audit of the currently published 0.2.10 cask passed as an environment preflight; it did not validate or publish 0.2.11. |
| Sparkle signed appcast, published last | Local final `f74d8c7d` public-signature verification passed. Publication, served feed and downloaded public asset remain pending. |
| Final published asset, cask and appcast comparison | Pending. |

Publish the GitHub release first, update Homebrew second, and publish Sparkle last. Keep public notes short and describe confirmed behavior. Do not announce the original empty-file rejection or either field report as solved without evidence.
