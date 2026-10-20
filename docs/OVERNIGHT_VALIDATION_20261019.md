# Overnight validation — October 19–20, 2026

**Draft checkpoint.** This records local validation and its limits, not a release approval or proof that a field issue is fixed. The work started from `d6096442`; integration was at `4106a48a` when this draft was prepared. Several long-running tests were compiled earlier, as qualified below. Final integration and cleanup results still need to be recorded.

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

## First buffer-benchmark read

The selected SSD's opt-in raw benchmark completed **one XCTest, zero failures and zero skips**: 25 hash passes and 25 raw-copy passes, each over a 2 GiB fixture. This is a raw I/O/hash benchmark, not a verified application transfer.

The first timed hash used a 64 KiB buffer and read 2,147,483,648 logical bytes in approximately 8.798 seconds. Read-only samples from the selected OS storage driver counted 2,105,344,000 read bytes in conservative intervals wholly inside that phase. The wider bracket counted 2,185,887,744 read bytes, including roughly 69 ms before and 135 ms after the phase. Selected-driver samples reported success.

This confirms substantial **OS storage-driver read traffic during the first timed read**. Driver counters include other processes and metadata; they do not identify every byte as this test's work, prove NAND reads, or establish a cold hardware cache. Another long test was reading the other SSD. These conditions do not support a controlled throughput comparison or a buffer-default change.

Before that run, the benchmark harness was corrected so each FileHandle read and hash update share an autorelease pool. Its long loops check cancellation cooperatively, and monotonic phase records distinguish source creation, hashing, raw copying and cleanup without paths. Three small harness tests passed; the large benchmark was initially skipped during that compile gate and enabled separately for the run above. Synchronous filesystem calls can still wait.

## App, engine and simulator gates

The engine gates were rerun after the buffer-harness additions at `4106a48a`; the full Mac, iPad and iPhone suites passed again at `84445c21`, including the high-resolution probe guards and final PDF footer regressions. Logical test counts and parameterized case counts are kept separate.

| Gate | Completed result |
| --- | --- |
| Engine Debug, XCTest | 223 scheduled: 186 passed, 37 opt-in/platform skips, zero failures |
| Engine Release, XCTest | 223 scheduled: 186 passed, 37 opt-in/platform skips, zero failures |
| Engine Debug, Swift Testing | 219 declarations in 39 suites: 213 passed, six opt-in skips, zero failures |
| Engine Release, Swift Testing | 219 declarations in 39 suites: 213 passed, six opt-in skips, zero failures |
| Full Mac app suite | 1,291 logical tests: 1,269 passed, 22 skipped, zero failures; no reported runtime warnings |
| iPad simulator | 81 tests: 71 passed, ten skipped, zero failures; no reported runtime warnings |
| iPhone simulator | 81 tests: 71 passed, ten skipped, zero failures; no reported runtime warnings |
| Shared mobile build | Universal iOS simulator build passed |
| Local signed Mac archive | Built and signature verified; no release published |

Skipped opt-in tests are not counted as passes. Some were enabled in separate runs above; those runs do not turn the whole-suite skip count into zero.

A separate signed-app walkthrough completed a Standard transfer to two physical backups and produced a real PDF with clip previews. Settings import Cancel/Apply and export persistence were also exercised. The final rebuilt app's interactive recheck was interrupted by a closed native automation pipe; the app remained alive and an independent sample showed its main thread idle. That automation failure is neither a passed final walkthrough nor evidence of an app hang. Component captures and simulator builds do not replace physical iPhone/iPad file-provider and background-execution testing.

The diagnostics-export hardening had its own **32 passing XCTest cases**, zero skips and a universal mobile build. An oversized-input regression was observed failing before the fix. The tests cover malformed, oversized, unreadable, symlink and FIFO inputs, preserving valid events from the other input and reporting incomplete evidence honestly. This does not identify the cause of issue #23.

## Pending finalization

- **Large physical transfer:** the corrected 119.6 GB SSD A → SSD B case was still running at this checkpoint. Do not count it as a pass, infer its eventual verdict, or use an earlier flawed-harness attempt as a substitute.
- **Application performance:** isolated repeated Standard/Thorough application trials and their counter-aligned measurements need a settled receipt. Raw buffer throughput is not application performance evidence.
- **4K report-preview memory:** the [reviewed host-only probe](validation/report-preview-memory-2026-10-19.md) passed at 20 and 200 paths, each with three executed XCTest methods, zero skips/failures and no reported runtime warnings. Sampled process footprint peaked at 103 MiB. Its fixture repeats one two-frame H.264 pattern across distinct paths; it does not cover codec diversity, long GOPs, large encoded files or distinct camera clips. All preview pixels, source/destination hashes and PDF image placements were checked. The [separate footer fix](validation/report-pdf-footer-2026-10-19.md) passed its regressions and the integrated app suites: normal 20/200-clip reports retain all previews across 2/14 pages instead of 3/15. Oversized identity text remains fully paginated rather than truncated.
- **Intel:** [translated x86_64 engine tests](validation/ROSETTA_ENGINE_20261019.md) passed: XCTest 186 passed/37 skipped, Swift Testing 213 declarations passed/six skipped, zero final failures. Initial unsigned-loader bookmark setup failures remain documented. This is Rosetta coverage, not execution on a physical Intel Mac or older macOS.
- **Final revision and cleanup:** update this document after the remaining jobs settle, final combined gates complete, and owned media fixtures, images, caches and simulators are accounted for. Retain compact receipts; preserve uncertain or failed evidence rather than deleting it prematurely.

No run here reproduces a real HDD through the reporter's dock, a USB controller fault, power loss, a forced unplug during active I/O, physical-media failure, or every iOS file-provider/background condition. The successful cases strengthen the tested paths; they do not close issues #10 or #23 without decisive field evidence.
