# Ambiguous filename handling — October 20, 2026

A disposable journaled HFS+ image reproduced a crash before copying: it held both `K.mov` and `K.mov` (the Kelvin sign), with different contents and distinct raw UTF-8 names and inodes. Swift compares those names as equal. The existing portable-name check exempted Swift-equal names, and a later unique-key dictionary trapped. A contained command-line worker built from the unchanged engine at `953c779f` exited by SIGTRAP with “Duplicate values for key.” Source hashes and the existing destination sentinel stayed unchanged.

The shared engine now rejects repeated portable-name keys and checks the captured **complete** manifest immediately after enumeration, before AppleDouble selection, sets, fingerprints or path dictionaries. Existing live-tree safety checks remain. A later live scan cannot establish that an earlier captured list was unambiguous. This is a preflight refusal, not a filename rewrite or a change to verification defaults.

The same source in the patched worker returned a normal unsafe-source error, preserving both source files and the destination sentinel. The original crashing binary, source hashes, byte-exact snapshots and failed-worker logs are retained privately. No app host or physical drive was used to reproduce the crash.

A second contained worker reproduced the same kind of trap in the final destination-metadata check. An unambiguous source was copied into an existing HFS+ folder containing `K.mov` and `K.mov`. Both prior files survived, but the unique-key dictionary trapped instead of returning a result. The engine now builds that metadata map with an explicit duplicate check. A duplicate fails the existing authoritative-results gate: selected files receive failed results, no complete MHL job is created, and the verdict remains unsafe. This check uses Swift string equality only; it does not impose a new case-folding rule on unrelated destination files. Copying may already have happened when this final check refuses completion.

## Coverage

Five ordinary regressions require the specific unsafe-source error for canonically equivalent or repeated paths, retain the existing ASCII-case refusal, and allow individual Unicode spellings, distinct emoji sequences and equivalent spellings in different directories.

Two further ordinary regressions require the precise destination completion error for canonical aliases and preserve distinct case-only or unrelated Unicode destination entries.

Two opt-in HFS+ regressions create the actual Kelvin pair with exclusive POSIX writes. Snapshots use raw UTF-8 `Data` keys rather than `String`, so the tests cannot accidentally merge the two names. Each first completes a tiny Standard transfer, ASC MHL and Saved Check. The ambiguous-source case must fail before returning an operation, preserve every source entry and prior destination/history snapshot, and leave the prior history passing a fresh Check. The ambiguous-destination case must return a failed selected-file result, create no new MHL history, preserve all prior media and history, retain the newly copied bytes and leave the source unchanged. It does not require a new Check to treat the deliberately added ambiguous files as intact. Required assertions throw before successful fixture cleanup. The final focused run passed all nine methods with zero failures or skips.

```sh
BITMATCH_UNICODE_HFS=1 swift test \
  --package-path Packages/BitMatchEngine --jobs 4 \
  --disable-swift-testing \
  --filter 'SourceFilenameAmbiguityTests|MountedUnicodeSourceTests'
```

Without the opt-in, both image tests skip. Unsupported setup fails rather than being counted as a passing mounted case. The fixture normally detaches only its identity-checked image and refuses recursive cleanup while any filesystem remains mounted beneath its owned root. Failed fixtures remain available. Native filesystem calls are not forcibly preempted.

Full engine gates passed separately in Debug and Release, with all environment-controlled stress, hardware and mounted-image cases disabled:

| Configuration | Framework | Passed | Skipped | Failed |
| --- | --- | ---: | ---: | ---: |
| Debug | XCTest | 195 | 43 | 0 |
| Debug | Swift Testing | 217 | 6 | 0 |
| Release | XCTest | 195 | 43 | 0 |
| Release | Swift Testing | 217 | 6 | 0 |

XCTest scheduled 238 methods in each configuration. Swift Testing reported 223 declarations in 40 suites, including its six explicit skips. The enabled nine-method focused run above supplies the real mounted HFS+ evidence; the ordinary full runs do not repeat it.

## Application gates

The full Mac app suite passed 1,282 tests, with 23 skips and zero failures. The first run failed one assertion that expected the previous error message; after updating that assertion, the fresh full run passed. The original failed result remains retained. Both structured and raw runtime UI-warning checks were clear; compiler warnings are retained separately, without an all-warnings-free claim.

Unsigned shared iOS-device and universal Mac Release builds passed. A local universal diagnostic archive also passed deep, strict signature verification using the unchanged signing configuration. It was not installed, exported, notarized or published. Before/after hashes bind all 444 Swift files to the tested code in `546c3d0d`; later validation-document commits do not change that code. These gates do not establish a physical mobile-device or final signed-UI walkthrough.

A fresh x86_64-only Release bundle also passed the same nine explicitly selected XCTest methods under Rosetta: nine passed, zero skipped or failed. Both disposable HFS+ cases ran and normally cleaned their fixtures. Xcode's signed universal XCTest host loaded the translated bundle; no private unsigned test loader or signing credentials were needed. This is translated engine coverage on Apple Silicon, not a physical Intel Mac, older macOS runtime or application walkthrough.

## Driver observations and limits

A separate raw POSIX probe attempted 13 name pairs on each of APFS, case-sensitive APFS, journaled HFS+, case-sensitive journaled HFS+, exFAT and FAT32: **78 pair probes**, not 78 application transfers or XCTest methods. Receipt keys are filename bytes. OS-created AppleDouble entries are counted separately from principal files.

- Every tested Mac driver rejected the second exclusive create for NFC `café.mov` versus NFD `café.mov`. These attempts do not prove that foreign-created media can never contain problematic names.
- HFS+, case-sensitive HFS+ and FAT32 allowed the Kelvin pair. APFS, case-sensitive APFS and exFAT refused it.
- Emoji joiners, variation selectors and non-ASCII case mappings did not behave uniformly across drivers. These observations are not a general filename-portability guarantee.
- A case-sensitive APFS source with `clip.mov` and `CLIP.mov`, containing identical bytes, was refused by the existing case-collision preflight. Sigma/final-sigma sources with identical and different bytes both settled unsafe on the case-insensitive APFS destination, with no complete MHL or green verdict. They did not establish a second unsafe-outcome bug.

Initial engine probes used 256 MiB destination images and correctly stopped at the existing 1 GB free-space reserve. Those setup refusals were retained; the crash and normal-refusal controls used an owned host APFS destination with sufficient real free space. No reserve or other safety rule was bypassed.

The destination crash control used a separate 2 GiB HFS+ image with sufficient free space. Its patched worker returned normally with failed results and unsafe verdicts both with and without MHL generation. An initial rebuild of that private worker omitted its testability compiler flag and failed compilation; the corrected build and actual worker run are retained separately from engine test results.

All seven research images were normally detached after identity checks, and their exact backing files were removed. Small receipts, logs, binaries and snapshots remain. A first cleanup comparison stopped before detaching anything because the initial driver probe had hashed only the first 1,024 bytes of each file. The corrected comparison matches that original scope: complete contents for the tiny principal payloads, a prefix for 4 KiB AppleDouble companions. Full current companion hashes were also saved; they do not establish full original-companion preservation. The separate application regressions use full-file snapshots for their source and history assertions.

These are generated tiny files on host-backed images, not camera footage, USB/dock reliability or a physical-device walkthrough. The disappearing-between-scans race was not directly injected; validating the captured manifest before its consumers closes that gap by construction. This crash is **not established as the cause of issue #10 or #23**; both field investigations remain separate.
