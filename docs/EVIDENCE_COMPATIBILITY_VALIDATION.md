# Saved-evidence compatibility

October 10, 2026. This batch expands Check and saved-report regressions. It does not change media copying, destination readback, MHL publication or source handling.

## Reproduced failures

The first focused run compiled and executed seven new test functions (including parameterized cases), then failed with 28 assertion issues against the prior reader. It demonstrated:

- Leading/trailing filename whitespace was removed from MHL paths.
- Nested inventories were resolved from the selected ancestor instead of their own card folder.
- Namespace-prefixed ASC inventories were not understood.
- Corrupt, unsupported, duplicate, unsafe-path and failed-action evidence could be skipped beside a readable record, leaving a partial check.
- Unknown report algorithms could be treated as Standard verification.

The reader now preserves paths, resolves each inventory from its own folder, processes XML namespaces and refuses ambiguous/unsupported file evidence. A failed discovery is explained in Check rather than shown as “no saved checksums.” Successful ASC results state that only file contents were checked, not history chains or directory structure. Report JSON and MHL reads use the existing 64 MiB report limit.

## Independent corpus

The committed corpus is under `Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/EvidenceCompatibility`. Its README records provenance and scope. Media bytes are original synthetic payloads; no footage, client metadata or personal hostname is included.

The official ASC reference implementation is pinned in the validation record to `ascmitc/mhl@0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687`. Its CLI generated the MD5, XXH64 and C4 inventories. All passed its inventory/chain XSDs, `ascmhl-debug verify` and `ascmhl diff`. Tests include two generations, zero-byte files, Unicode/XML escaping, filename whitespace and nested card folders. Negative variants add missing/changed media, unsupported hashes, malformed XML, conflicting duplicates, traversal, failed actions, foreign namespaces, future versions and entity declarations. Checks leave the copied media and histories unchanged.

Handcrafted JSON fixtures cover current, legacy, unknown extra fields, Quick, unsafe, unknown method, unknown algorithm and truncated reports. The classic-MHL example establishes an unsupported boundary; it is not claimed as external-tool output.

The old `validate_reference.sh` pointed at the generator's pre-package location and outdated API. It now uses a package executable linked to the real engine. Besides validating the permanent corpus, it validates freshly generated BitMatch output, lets the official CLI append a generation, independently checks C4 chain digests, and confirms that corrupted media is rejected.

## Validation

The final focused engine corpus and existing saved-checksum run passed all 21 test functions (including parameterized cases). The focused Mac run passed all 47 tests in ComparePresentationTests and ReportScannerTests.

The first full engine run passed 123 XCTest cases (15 intentional skips) but failed one Swift Testing setup assertion: FanOutTests' two-second wait for its injected stall. The same case failed when the whole fan-out suite ran concurrently, passed alone in 0.187 seconds, and all 18 fan-out tests passed with explicit `--no-parallel`. No later safety assertion failed. `test.sh engine-test` now passes that flag explicitly; tests still exercise concurrent workers internally. Failed logs are retained, not counted as passes. The complete rerun with explicit `--no-parallel` passed: 123 XCTest cases, 15 intentional skips, zero failures; the 145-test Swift Testing run passed, with six opt-in tests skipped. Those include large-media/memory and external-fixture workflows. The mounted exFAT handoff and 54-transfer AppleDouble filesystem matrix ran and passed.

The two new Mac presentation/integration tests were also mutation-checked. Replacing unreadable discovery with “not found” and removing the ASC scope text produced two behavioral failures; the production code was restored automatically afterward. The initial unmodified focused Mac run had passed both tests.

The full Mac suite passed: 1,092 passed, 12 opt-in/hardware skips, zero failures. Both new warning captures rendered at 580 and 1,000 points. AppKit bitmap captures omit some native layers, so these are layout evidence, not a substitute for the signed-app walkthrough.

The iPhone 17 Pro simulator passed all 71 tests on the compatibility branch. After merging #20 into that branch, the iPad Air 11-inch (M4) simulator passed all 72 tests. Both runs included opt-in workflow renders. The new warning was inspected at 320 and 820 points; text and actions remained readable. These are simulated/seeded views, not physical-device file-provider testing.

The initial reference environment used the shell's Python 3.9 and failed the tool's Python 3.11+ requirement. The successful reference run uses a separate Python 3.12 environment. That setup failure is retained with the test logs under `dist/validation/evidence-compat/`.

## Combined pre-release checks

After merging #20 into this branch, the full Mac run passed: 1099 passed, 13 skipped, zero failures. `test.sh engine-test` also passed: 123 XCTest cases, 15 intentional skips, zero failures; the 150-test Swift Testing run passed, with the same six opt-in skips listed above. The mounted exFAT handoff and 54-transfer filesystem matrix ran. The final repaired reference script passed its corpus, fresh output, second-generation and corruption controls.

## Limits

This is file-content interoperability coverage, not certification against every offload tool. BitMatch still does not discover standalone classic MHL, verify ASC directory/root hashes or chains, interpret rename history, or extend existing histories. Those roadmap items remain open. Supported BitMatch reports still take precedence over ASC inventories for Check. The saved-report scanner summarizes past evidence; it does not freshly verify media. Synthetic fixtures do not establish physical cable, dock or drive reliability.
