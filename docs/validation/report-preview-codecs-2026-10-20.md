# Explicit-codec and repeated-report preview probe

October 20, 2026. This extends the [4K preview memory probe](report-preview-memory-2026-10-19.md)
with two additional encoders and repeated reports in one process. It changes
test code only. All media lived in disposable Mac host scratch; no physical
card, backup drive, MHL handoff or durable History workflow is claimed here.

Each codec used one original, locally generated two-frame 3840×2160 quadrant
pattern, copied to 20 distinct source paths. The fixture requires the requested
encoder, the actual track dimensions and the actual FourCC. It never falls back
to a different codec. Unsupported `canApply`/`canAdd` results are explicit skips
with an `unsupported` receipt; actual encoding failures remain failures. Both
additional codecs were supported on this Mac.

| Probe | Actual FourCC | Report rounds | Initial / overall peak / final settled | Highest decoder / PDF phase | Probe test time |
| --- | --- | --- | --- | --- | --- |
| HEVC, 20 paths | `hvc1` | 1 | 46 / 103 / 83 MiB | 80 / 83 MiB | 3.388 s |
| ProRes 422, 20 paths | `apcn` | 1 | 45 / 143 / 85 MiB | 81 / 84 MiB | 3.819 s |
| H.264, 20 paths | `avc1` | 10 in the same process | 45 / 102 / 59 MiB | 93 / 93 MiB | 28.680 s |

The normal invocation passed the two small guard tests and intentionally skipped
the opt-in probe. Each of the three opt-in invocations passed those two tests
and the real probe: four invocations, 11 passed test executions, one intentional
skip, zero failures and zero xcresult runtime warnings. The real probes produced
60 independently verified pipeline rows across three transfers, followed by
240 preview extractions and 12 PDF reports. Repeated H.264 rounds reuse the same
verified backup; they are not ten additional transfers.

All 240 JPEGs passed dimension, byte-size and quadrant-pixel checks. Independent
Poppler inspection counted 20 JPEG placements in every PDF, each 256×144. All
24 pages were rendered; a contact sheet and representative full-size pages
were inspected. The reports retained every clip caption, verdict and footer.
Identical images may share a PDF resource, so resource count is not presented
as a count of distinct pictures.

Source SHA-256 inventories were captured before copying: 60 files in total.
Every report round rechecked the source and backup inventories independently:
240 source hashes and 240 destination hashes afterward. Every comparison
matched. Successful scratch media was removed only after these checks and the
final latched memory guard passed. PDFs, JPEGs, logs and memory receipts remain
private because their generated location fields contain local paths.

The ten-round run waits two seconds after each report's images and native PDF
objects leave scope. Its per-round physical-footprint samples were
83, 83, 83, 83, 83, 92, 92, 93, 59 and 59 MiB. The additional final settling
sample was 59 MiB. These observations show the measured trajectory; they do
not assert a leak-free trend or a permanent upper bound. Single-round probes
also include the original final two-second settling period.

The original limits remain unchanged: 200 previews, 30 seconds per collection,
two seconds per clip and a sampled 1,024 MiB process-footprint guard. Sampling
was requested every 10 ms; brief peaks can be missed. No probe hit the guard or
lost a sample. Cancellation is cooperative; synchronous filesystem, decoder
and PDF calls cannot be forcibly preempted by this harness. Per-report native
PDF objects are scoped inside an autorelease pool, rather than retained by the
test across rounds. Fixture and hash tasks are joined before returning.

This adds decoder diversity, not camera-format diversity: the three codecs all
encode the same tiny two-frame pattern. It does not cover long-GOP footage,
large encoded clips, every decoder, an interactive UI, or the cause of issue
#23. Timings are shared-host observations, not performance guarantees.

With the Mac test host reserved, build once and select the existing test class:

```sh
TEST_RUNNER_BITMATCH_HIGH_RES_PREVIEW_MEMORY=1 \
TEST_RUNNER_BITMATCH_HIGH_RES_PREVIEW_CLIPS=20 \
TEST_RUNNER_BITMATCH_HIGH_RES_PREVIEW_CODEC=hevc \
TEST_RUNNER_BITMATCH_HIGH_RES_PREVIEW_ROUNDS=1 \
TEST_RUNNER_BITMATCH_HIGH_RES_PREVIEW_ARTIFACTS=/private/tmp/bitmatch-preview-evidence \
xcodebuild -project BitMatch.xcodeproj -scheme BitMatch \
  -destination 'platform=macOS' -jobs 4 -parallel-testing-enabled NO \
  -only-testing:BitMatchTests/ReportPreviewMemoryTests test
```

Codec accepts `h264` (default), `hevc` or `prores422`. Rounds accepts 1–10
(default 1); clip count remains 20–200. Increase only after the smaller measured
case is safe. The checked-in defaults still skip the real probe.
