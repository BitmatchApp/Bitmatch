# Low-CPU reliability follow-up — October 21, 2026

Mike authorized three parallel tasks while using this Mac on set. Work used three subagents for implementation and source review. The initial pass used small Python checks against repository fixtures and disposable temporary folders. Mike later authorized only focused diagnostics package tests with one worker at low priority; those results are below. No Mac/iOS app build, simulator, drive access, external-tool download, merge, push or release occurred.

## Completed offline checks

`211774ed` adds `Scripts/ascmhl/validate_independent_classic_fixture.py`, twelve Python tests and instructions beside the existing externally generated padded-path fixture. It checks the exact file set, literal padded filename, original 30-byte payload, manifest and license hashes, size, MD5 and SHA-1. Parsing and traversal have small explicit limits. Negative controls cover corrupt bytes/digests, changed manifest/license, extra entries, unsafe/symlinked paths, XML structure/DTD/encoding and filename whitespace. Handcrafted Unicode/XML-escaping cases exercise this Python helper, not BitMatch's reader or an independent writer.

The final focused run passed **12 tests, zero failures/errors, in 0.017 seconds**. A separate direct validator invocation passed and reported one 30-byte media file with the documented manifest/license hashes. Three in-memory mutations independently disabled the MD5 comparison, manifest pin and license pin; each produced the expected assertion failure, with no test errors. Tracked source and permanent fixture bytes were unchanged by those mutation runs. The existing fixture's media, manifest and retained license were not edited; its README gained usage instructions.

The optional XSD adapter's local-byte/hash/resolver control flow was tested with a fake library. Actual schema validation and the external writer/verifier were **not run**; no pinned local runtime/schema inputs were supplied. The new tool does not claim that hashing an executable wrapper authenticates its installed dependencies. Independent Unicode output and Swift reader checks remain open.

## Diagnostic recorder — focused tests passed

`12e0e106` retains the zero-byte sticky failure marker and adds an exclusive, bounded detail file with a closed failure stage and numeric code. Export distinguishes a validated persisted detail from the current process's in-memory reason. Legacy, malformed, linked, partial or unavailable detail does not erase the error flag or invent an older cause. Readers check size/type/owner/link count and revalidate descriptor/name identity after reading. No free-form error, filename or path is exported. Numeric codes may be POSIX or Foundation codes.

Ten new XCTest methods and the existing cross-process lock-timeout test cover the intended persistence, legacy, privacy, type/bounds and memory-fallback behavior. They compiled and passed in the focused run at `d3721c5fcbb85d0d9d8e8b23dd1f2fd86eb9ef4f`. Earlier source review caught and corrected the missing fallback when marker creation itself fails, a POSIX integer conversion and sidecar identity checks. No timing threshold or recorder timeout was raised. The previous stress marker's cause remains unknown; this candidate cannot retroactively identify it.

The native SwiftPM runs used `taskpolicy -b`, nice 19, `--jobs 1`, `--no-parallel` and a private temporary scratch folder. Inherited hardware/stress controls were removed. XCTest and Swift Testing ran separately; filtering limited execution, though the package test target still needed compilation.

| Focused scope | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: |
| `DiagnosticStoreFailureDetailTests` | 10 | 0 | 0 |
| `DiagnosticStoreWriterTests` | 5 | 0 | 0 |
| `TransferDiagnosticStoreTests` | 15 | 0 | 0 |
| `DiagnosticStoreScopeTests` (Swift Testing) | 3 | 0 | 0 |

Both final commands exited zero. XCTest reported 2.992 seconds of execution; its resumed process took 192.382 seconds including a 176.23-second build. Swift Testing reported 0.120 seconds; its cached process took 4.016 seconds, including a 0.41-second build. No recorder corrections were needed after execution. Existing unrelated test warnings concern an unused benchmark `try?` result and inherited `@unchecked Sendable`; SwiftPM also deprecates `--build-system native`. These were retained, not described as a warning-free build.

A missing launcher path prevented the first launch before compilation. A later compile was interrupted at the then-current 60 GiB free-space floor after 208.581 seconds; no tests ran in that attempt. Its log and receipt remain separate. Space recovered and the run resumed from its partial cache. Mike subsequently clarified a **15 GB free minimum**. Only one owned compiler ran at a time, independently of other projects' jobs.

The private evidence bundle is `.codex-evidence-recovery/20261021-focused-diagnostics-0e61f227-aaa8-4d1a-b639-f953c9128065` in the workspace root. It retains raw logs, source identity, original stopped attempts, reviewed counts and SHA-256 receipts. After verifying those receipts and finding no live owned tool, the closed nonce-owned scratch build (about 368 MiB allocated) was removed. No other project's cache or job was touched.

## Drive-access audit — no production change

The [source audit](drive-access-review-2026-10-21.md) maps repeated bookmark/identity/ejectability work in queue presentation, selection setters, preflight, saved-record actions and Mac restore. The queue presenter's disk work is a concrete source finding; responsiveness impact has not been measured. A bounded reconciliation design and focused test plan preserve original-folder identity and final action validation. No selection, admission, ejection or permission behavior was changed in this pass.

## Remaining gates

Run the relevant full engine/Mac and iPhone/iPad checks when broader testing is authorized. The focused diagnostic run does not replace them, and the previously recorded PDF candidate app passes predate the new engine change. Complete the pending PDF edge/visual and final coordinator stress checks separately. Implement the drive-access worker boundary with held-worker, replacement, invalidation and final-action tests before claiming the UI stall risk addressed. No merge or release is authorized; #10 and #23 remain unresolved.
