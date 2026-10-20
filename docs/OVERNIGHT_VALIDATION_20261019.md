# Overnight validation — October 19–20, 2026

**Draft checkpoint.** This records local validation and its limits, not a release approval or proof that a field issue is fixed. The work started from `d6096442`; individual gate revisions and earlier long-running binaries are qualified below. Final integration and cleanup results still need to be recorded.

[Issue #10](https://github.com/BitmatchApp/Bitmatch/issues/10) and [issue #23](https://github.com/BitmatchApp/Bitmatch/issues/23) remain open. These runs do not establish the reporters' exact failure mechanism.

## Mounted filesystem matrices

Disposable images exercised the actual macOS filesystem drivers. Source and destination images had separate mounted devices, but shared the host's underlying storage. This tests filesystem behavior, not independent hardware or power-loss recovery.

| Run | Coverage | Result |
| --- | --- | --- |
| Transfer and evidence matrix | APFS, case-sensitive APFS, journaled HFS+, case-sensitive journaled HFS+, exFAT and FAT32; 288 one-backup cases and 270 mixed two-backup cases | 558 broad scenarios completed; see the split-run qualification below |
| Preserved metadata and history checks | Six source formats to APFS in Standard, Thorough and Paranoid, without the usual companion-file exclusion | 18 scenarios passed |
| Collision and metadata policy checks | 24 existing-content collisions plus 36 companion-file policy combinations | 60 scenarios passed; six expected metadata refusals |
| Recovery matrix | 12 cases on each of APFS, case-sensitive APFS, journaled HFS+, exFAT and FAT32 | 60 passed, zero failures or skips |
| Existing filesystem fault suite | Six filesystems, including case-sensitive HFS+ | 72 scheduled: 68 passed, four expected skips, zero failures |

The first three rows cover **636 unique scenarios**, not 636 additional XCTest methods. A two-case smoke run overlaps that coverage and is not added to the total. Single-backup coverage uses all four verification modes with pipelining both off and on. Mixed two-backup coverage uses the three verified modes, with pipelining selected across the combinations; it is not every possible feature permutation.

The initial combined matrix attempt failed on an incorrect harness assumption that a collision always produced one result row. FAT-family metadata can add rows. The 558 broad scenarios had completed; the corrected policy and preserved-history phases were then run separately. This is split-run evidence, not one uninterrupted green 636-case invocation. Six expected metadata-preservation refusals are passing safety assertions, not six verified transfers: those destinations received no complete history or safe verdict. The four existing-suite skips were its FAT-only handoff case on non-FAT filesystems.

The recovery cases cover:

- Cancellation during copying, destination readback and ASC MHL work; retry of identical content and refusal of changed existing content.
- Competing publication, case-only name conflicts, source symlinks and destination symlink ancestors, with protected bytes checked afterward.
- A deliberately changed, owned source fixture; the transfer must fail closed.
- Real volume exhaustion returning `ENOSPC` (errno 28), read-only image reattachment, and normal detach after preflight but before descriptor pinning.
- Interrupted MHL publication and retained incomplete evidence that cannot become trusted history or a successful verdict.

Cancellation, race and mutation hooks control the interleavings. The disk-full and read-only cases use actual mounted filesystem behavior. Normal detach before pinning does not reproduce pulling a cable during a blocked kernel read. Symlink cases prepare their owned fixtures before starting; only the source-growth case deliberately mutates its source during a transfer. The recovery receipt records no remaining owned image mounts and no forced detach; the pair-matrix receipt records no remaining scratch roots.

Earlier full-executor coverage is documented separately in [TRANSFER_MATRIX.md](TRANSFER_MATRIX.md): 800 configurations and 1,600 initial/repeat operations, plus project/report, naming and collision cases. Those historical counts are not added to this overnight matrix or represented as a fresh rerun here.

## Physical SD to two SSDs

One opt-in engine XCTest completed **nine scenarios, zero failures and zero skips** using an exFAT SD source and two exFAT external SSD destinations, called SSD A and SSD B here. Only uniquely marked validation folders were used; no physical drive was formatted or forcibly ejected.

The generated source inventory contained 272 entries, including OS metadata companions. The selected transfer set contained 134 files and **2,151,787,901 bytes**; the complete inventoried source contained 2,152,353,149 bytes. The tests compared source inventory, sizes and content hashes before and after the run. They do not assert preservation of every filesystem attribute or access timestamp.

The scenarios exercised Quick, Standard, Thorough and Paranoid with pipelining off and on, plus a Standard reuse pass. New verified transfers continued through ASC MHL and Saved Check; reuse checked that the prior history stayed unchanged. Quick remained unverified. Intentional metadata exclusions did not turn a selected-set result into a whole-card safety claim.

The sampled engine-process physical footprint peaked at **32 MiB**. This is not the GUI app's memory footprint. The run overlapped another large transfer on SSD B, so its elapsed times are not a fair comparison of verification modes or drive performance.

The running binary was built from `5396f6c5` plus the corrected test harness, before later assertion, cancellation and fixture-retention guards were added. Those later harness guards were compiled and tested separately. The completed physical run must not be described as a rerun of every final harness revision.

An earlier physical large-file attempt also had a wrong MD5-versus-SHA-256 harness assertion. Completing its byte work does not make that attempt a pass. It is excluded from the successful physical results.

## Large physical SSD transfer

The corrected SSD A → SSD B run passed one actual XCTest, zero failures and zero skips, in 14,566.320 seconds. Eight generated MOV containers contained **119,600,000,000 selected media bytes**, including 44.5 GB and 45.3 GB files. Standard verification used two requested workers; two large destination readers were observed. ASC MHL and Saved Check completed, and the final source inventory, sizes and content hashes matched their baseline. The sampled engine transfer/MHL/Check footprint peaked at **32 MiB**, from 11 MiB initially. It is not a GUI-process measurement or a leak proof.

Copy/verification took approximately 7,682 seconds, MHL 3,264 seconds and Saved Check 3,228 seconds. MHL covered all 119.6 GB of selected media; exFAT's deliberate reread policy remained enabled. Earlier phases overlapped the SD matrix, and the slower connection dominated I/O, so these are observations rather than a controlled performance benchmark. Exclusions still cannot earn a whole-card safety claim.

Like the SD matrix, this long-running binary predates the final harness guards. Its older receipt says `sourceUnchanged`, meaning the asserted inventory/size/content-hash comparison, not every filesystem attribute. The follow-up controller initially rejected that field because it expected the later `sourceSnapshotCompared` spelling; that controller failure occurred before app trials or HFS+ provisioning and does not invalidate the native passing transfer. Its original failed receipt is retained separately.

The [FAT32 boundary follow-up](FAT32_BOUNDARY_VALIDATION_20261020.md) also passed two actual XCTest cases without skips or failures: the largest allowed file completed Standard → MHL → Saved Check and retry, while exactly 4 GiB returned `EFBIG` and preserved prior media/history and incomplete evidence. These used sparse APFS sources and fresh host disk images, not physical FAT32 media or materialized camera footage. Initial setup-only failures remain documented.

## Abrupt worker termination

The [process-death matrix](validation/PROCESS_DEATH_RECOVERY_20261019.md) passed 20 scenarios on APFS, journaled HFS+, exFAT and FAT32 images. Each directly spawned worker reached a durable, kernel-stopped boundary and then exited by SIGKILL. Its running journal reopened as interrupted; source hashes and existing bytes were preserved. Incomplete MHL could not pass Check. The positive boundary also matters: a completely published history remained intact and passed a fresh Check, while the unsettled journal stayed interrupted. This is process-death coverage, not a power-loss or OOM-cause reproduction.

The focused run scheduled three XCTest methods: two passed and one internal helper skipped. The 20 scenarios are not 20 additional XCTest passes. Ordinary discovery passed the ownership guard and skipped the two opt-in methods. Final images and disposable source payloads were cleaned after normal detach.

## Repeated transfers and many-file workloads

The [seeded host soak](validation/SEEDED_SOAK_20261020.md) passed 256 iterations using all 256 low-byte payload patterns, with 2,304 source hashes before, 2,304 after and 4,608 destination hashes. Its corrected runner requires one actual passing XCTest and retains partial or failed evidence. A separate engine case passed with 20,009 files; independent post-run source and destination hashes matched the declared fixture bytes. That case had no independent pre-transfer hash pass. These are host-filesystem engine tests, without MHL or app UI.

A separate production-coordinator/SwiftUI-host probe completed 20,000 files to two backups through MHL and journal settlement. Debug passed with 40,000 verified rows and matching source/destination hashes; its 874 MiB sampled peak included the test's post-transfer hash helper. After pooling that helper's per-file Foundation work, Release also passed: 40,000 verified rows, a 438 MiB sampled process peak and 393 MiB settled footprint. These figures include the test host and retained history, not just the shipping app's transfer buffers. The Release test host enables test visibility; it is not an identical shipping binary.

The [PDF-enabled follow-up](validation/COORDINATOR_MANY_FILES_MEMORY_20261020.md) passed two sequential 2,000-file transfers in one process, including all 4,000 entries across both destinations in each 144-page PDF. Source and destination hashes and persisted results matched. The initial corrected run passed seven tests without skips or failures and peaked at 327 MiB. Its raw log contained a SwiftUI queue `onChange` warning even though structured runtime warnings were empty. The queue observer now tracks completion transitions rather than every progress update; 24 focused presentation tests passed. A matched real-workflow rerun passed, peaked at 303 MiB and had no matches in either structured warnings or the broader raw-console scan. That establishes warning removal for this case, not every possible UI workload. Neither run proves constant memory use or the cause of issue #23.

Long Master Report summaries, notes and oversized file rows now paginate instead of clipping. Seven actual-service controls passed; six stress cases failed against the earlier renderer. The normal one-page case stayed one page, and Unicode notes retained their text across page breaks. These checks are separate from the transfer-PDF preview cases.

The probe exposed a separate [quadratic result lookup](validation/RUN_RESULT_LOOKUP_20261020.md). Its indexed replacement preserves arrival order, exact source/destination matching and first-duplicate behavior. Four semantic tests passed. This removes measured bookkeeping work; it does not establish a memory leak or explain issue #23.

## First buffer-benchmark read

The selected SSD's opt-in raw benchmark completed **one XCTest, zero failures and zero skips**: 25 hash passes and 25 raw-copy passes, each over a 2 GiB fixture. This is a raw I/O/hash benchmark, not a verified application transfer.

The first timed hash used a 64 KiB buffer and read 2,147,483,648 logical bytes in approximately 8.798 seconds. Read-only samples from the selected OS storage driver counted 2,105,344,000 read bytes in conservative intervals wholly inside that phase. The wider bracket counted 2,185,887,744 read bytes, including roughly 69 ms before and 135 ms after the phase. Selected-driver samples reported success.

This confirms substantial **OS storage-driver read traffic during the first timed read**. Driver counters include other processes and metadata; they do not identify every byte as this test's work, prove NAND reads, or establish a cold hardware cache. Another long test was reading the other SSD. These conditions do not support a controlled throughput comparison or a buffer-default change.

Before that run, the benchmark harness was corrected so each FileHandle read and hash update share an autorelease pool. Its long loops check cancellation cooperatively, and monotonic phase records distinguish source creation, hashing, raw copying and cleanup without paths. Three small harness tests passed; the large benchmark was initially skipped during that compile gate and enabled separately for the run above. Synchronous filesystem calls can still wait.

## App, engine and simulator gates

The engine gates passed again at `79f07486`, including the soak and private diagnostic-scope additions. Fresh integrated Mac, iPad and iPhone suites passed at `2c3ac909`; the only commit during that app run changed the TODO document. Logical test counts and parameterized case counts are kept separate.

| Gate | Completed result |
| --- | --- |
| Engine Debug, XCTest | `0d62cbc5`: 229 scheduled: 188 passed, 41 opt-in/platform skips, zero failures |
| Engine Release, XCTest | `0d62cbc5`: 229 scheduled: 188 passed, 41 opt-in/platform skips, zero failures |
| Engine Debug, Swift Testing | 223 declarations in 40 suites: 217 passed, six opt-in skips, zero failures |
| Engine Release, Swift Testing | 223 declarations in 40 suites: 217 passed, six opt-in skips, zero failures |
| Full Mac app suite | 1,305 logical tests: 1,282 passed, 23 skipped, zero failures; structured and raw UI-warning scans clear |
| iPad simulator | 85 tests: 75 passed, ten skipped, zero failures; structured and raw UI-warning scans clear |
| iPhone simulator | 85 tests: 75 passed, ten skipped, zero failures; structured and raw UI-warning scans clear |
| Shared mobile build | Universal iOS simulator build passed |
| Release builds | `2c3ac909`: universal Mac and iOS-device builds passed with signing disabled |
| Local signed Mac archive | `2c3ac909`: x86_64 and arm64, deep/strict signature verification passed; no install, notarization or release |

Skipped opt-in tests are not counted as passes. Some were enabled in separate runs above; those runs do not turn the whole-suite skip count into zero.

A separate signed-app walkthrough completed a Standard transfer to two physical backups and produced a real PDF with clip previews. Settings import Cancel/Apply and export persistence were also exercised. The final rebuilt app's interactive recheck was interrupted by a closed native automation pipe; the app remained alive and an independent sample showed its main thread idle. That automation failure is neither a passed final walkthrough nor evidence of an app hang. Component captures and simulator builds do not replace physical iPhone/iPad file-provider and background-execution testing.

The diagnostics-export hardening had its own **32 passing XCTest cases**, zero skips and a universal mobile build. An oversized-input regression was observed failing before the fix. The tests cover malformed, oversized, unreadable, symlink and FIFO inputs, preserving valid events from the other input and reporting incomplete evidence honestly. This does not identify the cause of issue #23.

Separate Thread Sanitizer and Address Sanitizer builds at `3c284702` exercised the selected diagnostics, recorded-metadata, disk-resolution and publication tests: each scheduled 24 XCTest methods, with 22 passed, two opt-in physical tests skipped and zero failures. Each sanitizer also passed 13 Swift Testing declarations covering the pipeline and byte-weighted progress. The test binaries contained the respective sanitizer initialization symbols, and neither run reported sanitizer findings. An initial receipt parser rejected the successful Swift Testing summary because it included a suite count; the retained logs were revalidated after correcting the parser. These checks cover the executed paths, not every possible race, memory leak or resource termination.

The later diagnostic-scope changes also passed Thread Sanitizer: 15 XCTest methods and six Swift Testing declarations, with four declarations passed and two opt-in large-file cases skipped. Instrumentation was confirmed and no findings were reported. Scope tests cover child-task inheritance, nested throwing scopes and concurrent isolation; the override does not propagate to detached tasks or other processes.

A preceding post-soak Release run failed two diagnostic-ordering assertions while reading the shared ring. A separate private-directory reproduction confirmed silent record loss between independent store instances; it does not establish which process affected the original test. The regression fixtures now use private diagnostic stores, and the fresh full Debug/Release engine gates above pass. This fixes test isolation, not independent-process writes to one diagnostics file; the failed logs remain retained.

## Pending finalization

- **Application performance:** isolated repeated Standard/Thorough application trials and their counter-aligned measurements need a settled receipt. Raw buffer throughput is not application performance evidence.
- **4K report-preview memory:** the [initial host-only probe](validation/report-preview-memory-2026-10-19.md) passed at 20 and 200 H.264 paths, peaking at 103 MiB. The [explicit-codec extension](validation/report-preview-codecs-2026-10-20.md) also passed actual 4K HEVC and ProRes 422 at 20 paths, plus ten H.264 reports in one process. Those three invocations each passed three methods without skips/failures; their peaks were 103, 143 and 102 MiB. All preview pixels, source/destination hashes and PDF placements were checked. Each codec still repeats one short generated pattern; there is no claim of long-GOP, large encoded-file or camera-footage coverage. The [footer fix](validation/report-pdf-footer-2026-10-19.md) retains normal 20/200-clip reports across 2/14 pages instead of 3/15; oversized identity text remains paginated rather than truncated.
- **Intel:** [translated x86_64 engine tests](validation/ROSETTA_ENGINE_20261019.md) passed: XCTest 186 passed/37 skipped, Swift Testing 213 declarations passed/six skipped, zero final failures. Initial unsigned-loader bookmark setup failures remain documented. This is Rosetta coverage, not execution on a physical Intel Mac or older macOS.
- **Final revision and cleanup:** update this document after the remaining jobs settle, final combined gates complete, and owned media fixtures, images, caches and simulators are accounted for. Retain compact receipts; preserve uncertain or failed evidence rather than deleting it prematurely.

No run here reproduces a real HDD through the reporter's dock, a USB controller fault, power loss, a forced unplug during active I/O, physical-media failure, or every iOS file-provider/background condition. The successful cases strengthen the tested paths; they do not close issues #10 or #23 without decisive field evidence.
