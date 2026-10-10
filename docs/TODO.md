# To do

The working list for BitMatch, reviewed against `main` at `964d094b` on October 10, 2026. These are roadmap candidates, not instructions to implement every feature or a promised release scope. When something ships, record it in the [changelog](../CHANGELOG.md) and remove the finished task here.

**Source media → trustworthy copies → independent verification → accurate evidence → safe-to-erase decision.**

Investigate #16 first. Then follow evidence and actual user reports. Preserve source protection, no-overwrite guarantees, complete verification and honest verdicts. Core workflows apply to Mac, iPad and iPhone; keep platform limits explicit. See the [thesis](THESIS.md) and [architecture](../ARCHITECTURE.md).

## P0 — Active user-reported failure

- [ ] **AppleDouble transfer failures ([#16](https://github.com/BitmatchApp/Bitmatch/issues/16)).** One fresh-exFAT companion conflict is reproduced, and a reviewed exclusion option is implemented. The report itself still lacks a diagnostic trace or filesystem details; it does not prove that every companion should be skipped. Investigate avoidable failures separately from intentional filtering.

  Mounted APFS, HFS+ and exFAT fixtures now cover macOS-generated companions, publication, initial/repeated copies, multiple destinations, handoff histories and reports. The existing default includes companions and refuses conflicting files; the new policy leaves those conflicts intact. A passing synthetic case does not close the user report.

  **Exclude AppleDouble companion files** is implemented as a default-off, explicit selection policy. Keep the complete source inventory distinct from the selected transfer set. Preflight must show the exclusion count and let the user review the excluded files before starting. Record excluded files and counts in reports and history, and carry that distinction into safety decisions. Never silently drop camera files, sidecars or legitimate source data, or describe an intentionally incomplete copy as the entire source. “Selected files verified” must not imply that the whole card is backed up or safe to erase.

  **Implementation under review:** the default-off reviewed exclusion policy and real APFS/HFS+/exFAT regressions are implemented; see [the findings and validation](ISSUE16_APPLEDOUBLE.md). Fresh exFAT publication can produce a different companion, which is still retained rather than overwritten. The reporter's exact failure remains unconfirmed; keep #16 open pending diagnostics and a retest.

  **Acceptance:** avoidable AppleDouble failures are reproduced and fixed with regressions; genuine conflicts still preserve existing files. Any exclusion is explicit, auditable and tested across selection, copying, verification, evidence and verdicts. Source contents remain unchanged. A passing synthetic case is not proof that the reporter's hardware issue is resolved.

## P1 — Reliability and recovery

- [ ] **Storage-aware verification scheduling.** Replace the CPU-derived default with scheduling informed by physical storage identity and measured behavior. Avoid competing large sequential reads on one HDD; permit useful concurrency across independent SSD/NVMe devices. Account for shared devices and buses only where reliably identifiable. Preserve diagnostic worker-count overrides and benchmark actual throughput and memory use on physical hardware, including the two-drive test below. **Acceptance:** independent destination readback remains complete, cancellation still stops the run, and unknown topology gets a conservative policy rather than invented independence.

- [ ] **Bounded source-read retries and “Don't format the card” warnings.** Cover both source changes and read instability, separately from destination failures. Retry transient source I/O failures a small, bounded number of times and record each attempt and reason. Separate verified backup contents from source-media health: a recovered read must still warn against formatting or reusing an unstable card until investigated. Distinguish that from a failed backup. Explore chunk retries only with proven hash continuity and source identity checks. **Acceptance:** injected recoverable and persistent faults produce accurate counts, evidence and warnings; retries never hide changed data or turn exhaustion into success.

- [ ] **Explicit interrupted-transfer recovery.** Build on existing journal retries, identity checks and independent verification before whole-file reuse. Show reused, recopied, failed and pending files per destination; retain the old attempt. **Acceptance:** no unproven existing file is overwritten, original volume/folder identity remains required, and the original attempt remains interrupted/unsafe; only a fully verified new attempt can earn a safe verdict. Describe complete-file recovery honestly; do not claim byte-offset resume.

- [ ] **Repair a failed destination from a verified sibling.** After recovery provenance is defined, investigate SSD A → failed HDD B repair without rereading the original card unnecessarily. Require authoritative file evidence, revalidate A, independently verify B, and record the original source, repair source and new attempt in reports/history. **Acceptance:** stale or changed sibling evidence cannot authorize a repair; existing unverified files are never overwritten; copies on the same physical device never count as independent backups.

- [ ] **Check everything again at Start.** Existing engine preflight checks output roots, overlaps and access; journal preparation checks stored identities. Audit remaining gaps between selection, queueing and execution. Cover card/drive disconnect or replacement and two queued cards resolving to the same output folder (for example two “NO NAME” cards without a card number in the naming pattern). **Acceptance:** refuse unsafe starts before copying, explain why nothing was copied, and retain regressions for each gap found.

- [ ] **Finish the card-untouched regression.** `SourceTreeUnchangedTests` already compares paths, contents, sizes, modification dates and permissions through the app executor in every verification mode, with reports and MHL enabled. Extend it to capture and compare extended attributes and relevant filesystem metadata; coordinate with #16's real companion fixtures. **Acceptance:** the full source snapshot is unchanged after success, cancellation and failure; unsupported metadata checks are reported as such, not counted as passes.

- [ ] **Re-copy a newly written file that fails verification.** Investigate one automatic re-copy/re-verify, coordinated with recovery and sibling repair. **Acceptance:** replacement is limited to an output whose identity and ownership by this attempt are proven; never replace a file predating the run or one changed by another writer. Preserve the initial failure and retry outcome, and keep the verdict unsafe if retry fails.

- [ ] **One destination out of space.** Investigate pausing only that destination while the others finish, then revalidate space and identity before continuing. Today the failed destination is reported while others can finish. **Acceptance:** partial work remains visibly incomplete, cancellation works, and the overall verdict cannot become safe until every required backup verifies.

- [ ] **Opt-in crash reports.** Investigate Apple's MetricKit crash/hang diagnostics, off by default, with no third-party service or automatic sending. Existing local diagnostic exports already record phases, cancellations, verification breadcrumbs and memory use; they cannot establish why a process disappeared.

## P2 — Evidence and interoperability

- [ ] **Upstream MHL / source provenance.** Reuse `SavedChecksumCheck` where appropriate to offer source verification against accompanying classic MHL or ASC MHL evidence. Record “source arrived intact” separately from “BitMatch created verified backups.” Preserve original manifests. Current Check discovers ASC inventories under `ascmhl/`; standalone classic-MHL discovery and an upstream transfer verdict still need work. **Acceptance:** incomplete, mismatched, malformed and unsupported evidence gets an honest separate verdict; a failed provenance check never becomes success and never prevents preservation of damaged-but-irreplaceable media.

- [ ] **MHL interoperability corpus.** Expand the existing generated-fixture/reference checks and multi-file saved-record regressions with permanent, redistributable classic/ASC manifests and representative external-tool output. Cover multiple generations, relative paths, renames, directory changes, unsupported algorithms, corrupt/malformed records, Unicode and unusual filenames. **Acceptance:** validate with independent reference implementations, record fixture provenance/licensing and expected outcomes, and never silently treat unsupported evidence as fully verified.

- [ ] **ASC MHL structural verification.** After the corpus establishes expected semantics, extend Check to validate supported root/directory hashes and detect renamed, moved, missing or structurally altered content. **Acceptance:** distinguish file-content verification from structural verification; older manifests without structural evidence remain usable with an explicit scope. Do not claim full history verification before the chain semantics are implemented and independently tested.

- [ ] **Extend existing MHL histories.** Check already verifies recorded file contents; generating another history generation is still unsupported. Coordinate with structural verification and the reference corpus. **Acceptance:** preserve existing histories, validate the new chain independently, and ensure interruption cannot expose a partial generation as complete. Keep the current refusal until this is proven.

- [ ] **Evaluate xxHash64 for transfer verification.** The saved-checksum reader already supports XXH64; transfer verification still uses the current modes. Retain the proposed performance investigation with `RealCopyBenchTests`, after reliability work. Any algorithm change needs an explicit compatibility/safety decision, measurements, and truthful reports; this roadmap does not authorize weakening verification.

## P3 — Useful reports and history

- [ ] **Optional clip thumbnails in PDFs.** The Mac already exposes an `includeThumbnails` preference, default off, but no thumbnail extraction/rendering path was found in the current report code. Resolve that misleading control when taking up this work; do not count the setting as an implemented feature. Keep generation optional and off by default. Start with one representative frame per supported video clip, preferably through AVFoundation, after critical copy/verification work. Support report generation/regeneration from previously verified media, with bounded memory, concurrency and time. Keep large reports compact; skip unsupported, unreadable and proprietary formats gracefully. Cache only where repeat generation benefits justify the storage and privacy cost. **Acceptance:** opted-in PDFs show supported clips' names, images and verification information; unsupported clips remain listed. Thumbnail failure never changes copy success, verification or safe-to-erase decisions, and footage/thumbnails never enter diagnostic exports. No proxies, transcoding, media browser or contact-sheet management.

- [ ] **More detail in History.** Add date/time, file count, total size, measured copy/verify durations and average speed to expanded rows where missing. Keep collapsed rows compact; show a dash for measurements absent from older records rather than inventing them. Coordinate with the reused/recopied/pending counts above.
- [ ] **History from the drives themselves.** Read past offloads from saved reports on connected destinations, so “Backed up before…” works for a shuttle drive filled on another Mac. Keep discovered evidence distinct from a fresh verification.
- [ ] **Per-card/per-drive notes and operator.** Carry these into reports and ASC MHL and from one card to the next; coordinate with organize-and-rename work.
- [ ] **“How verification works” guide.** Explain readback, modes, selected-file scope, evidence and the limits of a safe-to-erase decision.

## P4 — Convenience after reliability

- [ ] **Portable settings/workflow export and import.** Build on existing project recipes and saved settings. Include safe preferences, verification/report choices, naming recipes and reusable destination configurations; preview changes before import and revalidate destinations on the receiving machine. **Acceptance:** omit credentials, security-scoped bookmarks, private history and machine-specific identities. No facility configuration-management system.
- [ ] **Simplified operator mode, only if users ask.** Investigate preconfigured destinations, naming and verification with an everyday source → start → review flow. Warnings stay visible and validation still runs; no facility administration or permission system.
- [ ] **Organize and rename.** Extend existing project naming and folder recipes with remaining naming-pattern and organize-by-date workflows. Preserve original card contents and test destination collisions before adding new options.
- [ ] **Speed for each drive.** Show which destination is slow instead of only an average; use measurements from the storage-scheduling work.
- [ ] **Slow-cable hint.** On Mac, show a quiet hint when reliable connection information identifies a USB 2 bottleneck. Do not promise a speed multiplier without measurements.
- [ ] **Time estimate before Start.** Use card size and recent measured speeds; keep “estimating” when evidence is insufficient.
- [ ] **Phone notification with no account.** Optional completion/failure push through an open service such as ntfy. Make disclosure of card names/results to that service explicit.
- [ ] **Offload from Finder.** Right-click a card and choose “Offload with BitMatch.”
- [ ] **Shortcuts support.** App Intents for offloads, preserving the same validation and verdict rules.
- [ ] **Cloud destinations, if users ask.** A selected backup destination, not a cloud dashboard.
- [ ] **Persistent SFTP connection.** Replace one `ssh` process per file if SFTP becomes a headline feature.
- [ ] **macOS 15.0 minimum.** Investigate lowering 15.5 to 15.0 without breaking APIs or behavior; do not go below 15.
- [ ] **Liquid Glass pass.** macOS/iOS 26 toolbar, composer, rows and completion, with a material fallback. Check it in person before merging.

## Validation, accessibility and release readiness

These remain ongoing gates, not optional competitor features. Use disposable data and retain failures and skipped checks alongside passes.

- [ ] **Physical hardware reports.** Ask users to fill in the [hardware report template](HARDWARE_REPORT_TEMPLATE.md) for their cameras, readers, drives and connections. Follow the [hardware testing procedure](HARDWARE_TESTING.md); disk-image tests do not establish cable, dock or controller reliability.
- [ ] **Two-drive speed test.** Two fast external drives on 10 Gb/s cables, through `RealCopyBenchTests`; feed results into storage-aware scheduling. Remove only the owned `bench-card` fixture from the T9 after confirming its identity.
- [ ] **VoiceOver pass on real devices.** Preserve the remaining accessibility checks in the [thesis](THESIS.md).
- [ ] **Release walkthroughs.** For behavior changes, run relevant engine and Mac tests, build iPhone/iPad, and exercise the signed app's affected workflow. Record physical-device, simulator and synthetic coverage separately; do not close user reports on a synthetic pass alone.
- [ ] **iPhone/iPad distribution.** TestFlight, then the App Store, so users need not build from source.
- [ ] **Real screenshots.** Replace demo queue imagery with real-card workflows when available, after removing private production details.

## Developer chores

- [ ] **Tests without permission prompts.** Investigate drive-access prompts that stall Mac tests; prefer owned temporary fixtures and scoped test configuration without weakening release entitlements. The documented DerivedData-outside-Desktop workaround addresses a separate loader stall.
- [ ] **Buffer benchmark first run.** Avoid measuring freshly written files still in cache; evict/rewrite before timing or discard a warm-up run, and verify that the measured read actually reaches storage.
- [ ] **Reverse flight on Edit.** Loading a queued card back into setup should carry it up the same way Start carries it down.

## Out of scope

Do not add these for competitor parity: proxy generation/transcoding; dailies/color workflows; P5/LTO archive management; media cataloging or clip playback; full project-management systems; Final Cut relinking; facility administration; cloud dashboards; automatic camera-card formatting; general-purpose bidirectional synchronization.

Existing lightweight project transfers, folder recipes and optional remote backups remain in scope. New convenience work waits behind the reliability and evidence work above.
