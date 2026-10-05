# Large-file verification investigation

## What the reporter's diagnostics establish

The 0.2.3 session completed two transfers through verification, MHL, reports and journal settlement. The later eight-file transfer reached `copyDrained` at 2026-10-04 05:52:33 UTC with no cancellation flag. Its next recorded session begins at 05:56:24 UTC, without a verification-drained or terminal event for that transfer. The journal subsequently records an interruption.

This is consistent with an unclean interruption during verification. It does not identify a fatal signal, an OS resource termination, force quit, or another cause. The absence of logger errors strengthens the timeline but is not proof that every possible event was recorded. The recorded 0.2.2 run separately has an explicit user cancellation.

## Changes

- Include the Foundation read inside each chunk's autorelease pool in pinned destination readback, Thorough source rereading, Paranoid byte comparison, and the MD5/SHA-256/SHA-1 checksum loops. Do not rely on a pause check suspending the task.
- Preserve uncached destination reads, pinned descriptor access, source stability checks, and cancellation propagation.
- Add optional process physical footprint in MiB to structured diagnostics. It is evidence of resource usage, not an OS termination reason.
- Add file-ordinal/destination breadcrumbs for verification start, destination open, reads every 8 GiB, digest finish, and completion. Completion records matched, mismatched, failed or cancelled; it is not a success assertion by itself.
- Add advisory clip-inspection start/end events. These do not change its existing advisory policy.
- Record the effective verification worker count. The default adaptive count is unchanged.

The app reads an optional diagnostic preference at launch and passes it into the engine. On Mac, quit BitMatch before setting it:

```sh
defaults write BitMatchApp.BitMatch BitMatchVerifyConcurrency -int 1
```

For two workers use `-int 2`. Restore the normal adaptive behavior with:

```sh
defaults delete BitMatchApp.BitMatch BitMatchVerifyConcurrency
```

Restart the app after either change. Positive overrides are capped at 16; zero/negative/unset use the normal count. The preference limits verification tasks, not copy workers or whole-app memory.

No names, paths, clip metadata or free-form error messages are added to exported diagnostics. Existing private logs remain private.

## Reproduction

An optimized standalone async probe using the old 4 MiB Foundation read/hash loop grew to 1,080,591,632 bytes of physical footprint after reading 1 GiB, at which point its safety cap stopped it. With the read inside the pool, the same probe read 8 GiB and finished near 6.4 MB. This establishes buffer retention on this Mac/toolchain, not the reporter's termination cause.

Run the isolated actual pinned-read memory regression:

```sh
BITMATCH_MEMORY_TEST=1 arch -arm64 swift test --package-path Packages/BitMatchEngine --build-system native --filter VerificationMemoryTests
```

The 256 MiB sparse-file test checks the real pinned destination loop, all 64 read callbacks, an independently computed SHA-256, and a footprint-growth ceiling of 128 MiB. It is opt-in because process-footprint assertions need an isolated process. Terminal-event coverage also exercises both pipelined and sequential cancellation.

Run the real-driver eight-clip transfer with one and two verification workers:

```sh
Scripts/test-large-verification.sh
```

It creates disposable exFAT source and HFS+ destination images, writes six 256 MiB clips plus two 3 GiB clips (7.5 GiB total), includes macOS-generated AppleDouble companions, copies/verifies to a separate folder for each worker count, independently rehashes destinations and the source, and detaches/deletes its images without forced unmounts. It needs about 25 GiB free plus build space. It is intentionally smaller than the reporter's roughly 120 GB card. These virtual drives share a physical host disk; it does not reproduce his USB dock, HDD, source clips, or machine memory.

The investigation remains open pending OS termination evidence or a reproduction on the reporter's workload. FileHandle ownership and the clip parser were reviewed without finding the proposed double-close path; that does not rule out every possible process-level fault.

## Validation on 2026-10-04

- Actual pinned-read regression: green at 18 → 26 MiB for 256 MiB/64 chunks; isolated removal of only the read pool fails at 27 → 267 MiB. The source/destination checksum remains correct in both runs.
- Eight-clip real-driver test: one and two workers both pass, 16 results each (eight media files plus eight AppleDouble companions), all independent destination and unchanged-source SHA-256 checks pass.
- Engine suite: 110 XCTest cases, 15 opt-in skips, zero failures; 126 Swift Testing cases, two opt-in skips, zero failures. Memory and large-transfer tests are separately enabled above.
- Mac build and iPad/iPhone simulator build pass.
- The full local Mac app test suite has not completed: its test host stalls in dyld before entering app code. Default, non-debug-dylib, ad-hoc-signed and explicit ARM64 attempts were sampled or observed and stopped. This is an outstanding validation limit, not a passed suite or proof of a code defect. GitHub reports the CI workflow as `disabled_manually`, so PR #13 has no remote checks until the owner approves re-enabling it.

Detailed logs are kept locally under `dist/validation/verification-memory`. They include failed fixture expectations: Foundation's directory listing hid generated AppleDouble companions, while BitMatch correctly transferred 16 entries. The fixture was corrected with direct `lstat` checks rather than omitting companions. Those failed expectations are not product regressions.
