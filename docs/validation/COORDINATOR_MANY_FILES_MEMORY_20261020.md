# Many-file coordinator memory probe

This opt-in Mac app test exercises the real coordinator, transfer pipeline and
observed production progress/queue views with 20,000 distinct 1 KiB files and two
backups. Standard verification and ASC MHL stay enabled. Synthetic disk identities
make the workflow eligible for two-backup policy; every folder is actually on the
same host filesystem. This is not independent physical-backup coverage.

The test checks 40,000 verified live/final/journal/engine rows, matching row IDs,
completed journal state, exact planned counts, active view renders and monotonic
progress below 100% while active. It independently hashes every original and both
copies after the transfer, preserving the original manifest. Report-on runs also
require an actual readable PDF whose manifest contains every relative source
path exactly twice, once per backup, with no missing or extra selected paths.
Its page count and the PDF are retained with the receipt. The fixture-specific
text check tolerates PDFKit line breaks inside these short generated names; it
is not a general parser for footage paths. Thumbnails are disabled in this case.

The actual app-test process samples its physical footprint every 10 ms. Missing
samples or a 1 GiB observation fail closed and request cancellation of owned work.
The coordinator awaits the pipeline; the test joins its own worker, monitor and
layout task, then records settled memory before a passing receipt. Filesystem
calls and synchronous PDF rendering remain cooperative;
this guard is not an OS-enforced memory cap or an absolute runtime guarantee.
Successful fixtures remove only explicitly named owned media children; failures
retain their media and evidence. Each file's independent hash validation, including
read/open/hex formatting/close, is inside an autorelease pool so the test helper does
not accumulate Foundation temporaries across the entire inventory.

Two ordinary regressions check sticky memory-limit cancellation and unavailable
memory samples. The expensive coordinator case skips unless explicitly enabled.
Use these environment values in the app test target's xctestrun environment:

```text
BITMATCH_APP_MANY_FILES_MEMORY=1
BITMATCH_APP_MANY_FILES_COUNT=20000
BITMATCH_APP_MANY_FILES_REPORTS=off
BITMATCH_APP_MANY_FILES_MAX_SECONDS=1200
```

The count accepts 100–20,000; reports accepts `off` or `both` (one pass without
reports, then a fresh pair of backups with reports); the cooperative deadline
accepts 60–1,200 seconds and defaults to 600. Run only
`CoordinatorManyFilesMemoryTests` with app-host parallel testing disabled.

## Results and limits

The corrected 300-file Debug smoke passed seven tests: three XCTest methods and
four normal result-index semantic tests, with no failures or skips. The actual
coordinator case produced 600 verified rows, 51 progress callbacks and 56 active
view renders. Its 499 memory samples peaked at 142 MiB and settled at 93 MiB.

The 20,000-file Debug report-off case passed: 40,000 verified rows, 3,014 progress
callbacks and 3,690 active view renders, with 24,541 samples. XCTest wall time was
248.983 seconds. Peak process footprint was 874 MiB, including the earlier
validation helper; the transfer phase peaked at 640 MiB and the post-run direct
hash check at 874 MiB. It settled at 257 MiB. This retained result predates the
whole-file validation-helper autorelease-pool correction and is qualified as such.

An earlier 20,000-file attempt was deliberately interrupted to repair a harness
cleanup-path comparison; it is not counted as a pass or a product failure. That
comparison affected only the test's own evidence directory, and cleanup now uses
an explicit child-name allowlist.

The corrected-helper Release 20,000-file report-off case passed one XCTest in
210.093 seconds, with no skips or failures. It produced 40,000 verified rows,
3,069 progress callbacks and 3,661 active view renders. Across 21,300 samples,
process footprint was 48 MiB initially, 438 MiB at peak and 393 MiB after settling
with the completed coordinator/results/history still loaded.
The observed transfer-phase peak was 380 MiB; the post-run direct hashes peaked at
438 MiB. The memory guard stayed clear and no samples were unavailable. This run changed
both the build configuration and the helper pools; the peak difference is not
a controlled attribution to either change alone.

Xcode's structured runtime-warning summary was empty, but the captured native log
contains one SwiftUI `onChange(of: Array<QueueSessionRow>)` multiple-updates-per-frame
warning during the MHL handoff. It is retained as a presentation follow-up, not
silently reported as a warning-free run.

The first 2,000-file report-on attempt completed both transfers, independent
source/copy hashes and a 144-page PDF, then failed the test's exact-path assertion.
PDFKit inserted a newline after each underscore in its text extraction, while
Poppler extracted all 4,000 visible manifest paths correctly. The corrected
fixture-specific extractor independently revalidated that retained PDF: exactly
2,000 selected paths, each present twice. This was a harness assertion defect,
not missing PDF evidence. That failed fixture/receipt is retained, and a fresh
coordinator rerun validates the corrected harness rather than relabeling the
failed XCTest as passed.

The corrected Release 2,000-file two-pass case then passed with the two normal
memory guards and four result-index regressions: seven tests, no skips or
failures. Each pass produced 4,000 verified results and passed all direct source
and backup hash checks. The report-on pass produced a readable 144-page PDF with
exactly 4,000 manifest entries: every one of the 2,000 source paths twice.
Across 11,927 footprint samples, the process started at 72 MiB, peaked at 327 MiB
(in the test's PDF extraction), and settled at 119 MiB. The memory guard stayed
clear. The native queue-observer warning remained; Xcode's structured warning
summary was empty. The first/report-off pass took 20.856 seconds and the second,
with the previous completed record still displayed and reporting enabled, took
105.937 seconds. These differ in history and reporting work, so they are not an
isolated report-performance comparison.

This establishes the 20,000-file report-off and 2,000-file report-on scopes
separately. A 20,000-file PDF was not run. The queue presentation currently groups
completed records' result rows on repeated renders; caching that immutable
summary is a separate possible performance improvement, not part of this patch.

The Release test build uses normal optimizations plus the command-line
`ENABLE_TESTABILITY=YES` override; it is an app-test host, not the signed shipping
app. Xcode log capture, XCTest, live views and the test's own inventories all share
the measured process. Build work elsewhere on the Mac makes elapsed times
observations rather than throughput benchmarks.

Row arrays, manifests, history and PDF pages retain expected O(N) evidence. This
probe does not establish constant memory for unlimited files/history, prove
native picker/device/drive behavior, or identify the cause of issue #23. Separate
large-file, thumbnail, filesystem and process-death tests cover other workloads.
