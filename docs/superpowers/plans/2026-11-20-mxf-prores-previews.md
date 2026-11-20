# MXF ProRes Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reports show a frame for ProRes clips inside an MXF wrapper, found by a bounded in-house KLV scan and decoded by VideoToolbox.

**Architecture:** `MXFFrameLocator` (engine, pure Swift, descriptor-based, bounded) finds the first picture frame's offset and length. `ProResFrameDecoder` (Shared, VideoToolbox) validates the ProRes header and decodes one frame straight to a preview-sized buffer. `ReportThumbnailService.frame` dispatches `.mxf` to a shared serial MXF queue; everything else stays on AVFoundation.

**Tech Stack:** Swift 6, Darwin `open`/`fstat`/`pread`, VideoToolbox, CoreMedia, XCTest (engine) and Swift Testing (app).

**Spec:** `docs/superpowers/specs/2026-11-20-mxf-prores-previews-design.md`

## Global Constraints

- Locator never reads value bytes except the first 8 of the picture value (frame size + `icpf`, both verified there); headers only; `scanLimit` 64 MiB, `packetLimit` 4096, `frameLimit` 64 MiB applied to the ProRes frame size.
- `UInt64` offsets and lengths, overflow-checked; any overflow, past-EOF, indefinite BER (`0x80`), or BER length field over 8 bytes → nil. Zero-length non-picture packets are skipped.
- Decoder rejects before any session: `count < 32`, frame size > count or < 32, tag ≠ `icpf`, header size < 20 or `8 + headerSize > frameSize`, width or height outside 16…8192, width × height > 40_000_000, chroma not 4:2:2/4:4:4.
- Decoder asks for the fitted output size (≤ 256×144, aspect preserved, never upscaled) via pixel buffer attributes; session invalidated in `defer`; `autoreleasepool`.
- One shared serial queue for all MXF work; the per-clip deadline is passed to the locator as `shouldContinue`.
- Fixtures: `tiny-orange-64x64-lt.mxf`, `tiny-orange-64x48-lt.mxf`, `tiny-orange-64x64-hq.mxf` (7737 bytes each, frame at offset 6164, lengths 236 / 218 / 240) from the scratchpad `repro/fixtures`, copied into `Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/` and embedded as base64 constants in `BitMatchTests`. Nothing from ARRI enters the repo.
- Tests run under the shared lock: `until mkdir /tmp/bitmatch-test-lock; do sleep 5; done`, `rmdir` on exit.

## Review Focus

1. A card file crafted to loop the scanner (self-referencing lengths): `packetLimit` and `scanLimit` must stop it; pinned in Task 1.
2. A `.mxf` row whose backup file is a symlink: `collect`'s existing symlink check still runs first, and `O_NOFOLLOW` refuses it a second time; pinned in Task 3.
3. A stalled volume during the MXF read: the caller resumes nil at the deadline and the next clip is not blocked by the orphan beyond the shared queue; pinned in Task 3.
4. A 4:4:4 frame with alpha: decodes, alpha dropped; pinned in Task 2 only by the ARRI opt-in (4444 without alpha) — ledger if no alpha fixture can be made.
5. Uppercase `.MXF` from a camera that writes uppercase names: dispatch is case-insensitive; pinned in Task 3.

---

### Task 1: MXFFrameLocator (engine)

**Files:**
- Create: `Packages/BitMatchEngine/Sources/BitMatchEngine/MXFFrameLocator.swift`
- Create: `Packages/BitMatchEngine/Tests/BitMatchEngineTests/MXFFrameLocatorTests.swift`
- Add fixtures to `Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/` (three `.mxf` files).

**Interfaces:**
- Produces:
  ```swift
  public struct MXFFrame: Equatable, Sendable { public let offset: UInt64; public let length: UInt64 }
  public enum MXFFrameLocator {
      public static let defaultScanLimit: UInt64 = 64 << 20
      public static let defaultPacketLimit = 4096
      public static let defaultFrameLimit: UInt64 = 64 << 20
      public static func firstPictureFrame(descriptor: Int32, fileSize: UInt64,
          scanLimit: UInt64 = defaultScanLimit, packetLimit: Int = defaultPacketLimit,
          frameLimit: UInt64 = defaultFrameLimit, shouldContinue: () -> Bool = { true }) -> MXFFrame?
      public static func firstPictureFrame(at url: URL, shouldContinue: () -> Bool = { true }) -> MXFFrame?
      // opens O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC, fstat regular file, calls the descriptor form, closes.
      public static func readFrame(descriptor: Int32, frame: MXFFrame) -> Data?   // pread loop, EINTR retry, short reads; nil on failure
      static func pictureKeyPrefix: [UInt8]   // 13 bytes
      static func partitionPackKeyPrefix: [UInt8]   // 13 bytes
  }
  ```

- [ ] **Step 1: Write the failing tests** (XCTest, file-backed; a helper `write(_ bytes: [UInt8]) -> URL` in scratch, and a `klv(key:value:)` builder)

```swift
func testFindsTheFirstPictureFrameInTheFixtureFiles()        // each fixture: MXFFrame(offset: 6164, length: 236 / 218 / 240) via the URL form and via descriptor form
func testFrameBytesStartWithTheProResHeader()                 // readFrame → bytes 4..<8 == "icpf", count == length
func testNilForNonMXFTruncatedAndEmptyFiles()                 // "hello", first 100 bytes of fixture, empty file → nil
func testPartitionPackMayFollowRunIn()                        // 1 KiB of zeros + fixture → found at 1024 + 6164; 70 KiB of zeros + fixture → nil
func testZeroLengthFillPacketsAreSkipped()                    // partition pack, fill packet (key 06 0E 2B 34 01 01 01 02 03 01 02 10 01 00 00 00, length 0), picture packet → found
func testBERForms()                                           // short form (<128), long form 2-byte, long form with leading zero byte accepted; 0x80 indefinite → nil; 9-byte length field (0x89) → nil; length field cut off by EOF → nil; FF×8 → nil (past EOF)
func testPictureValueMustLookLikeProRes()                     // picture value with frame size 0 → nil; tag "icpg" → nil; frame size > KLV length with more file after → nil
func testFrameLimitAppliesToTheProResFrameNotTheKLVValue()    // clip-wrapped: one KLV holding frameA(236)+frameB(236) → length 236; frame size field > KLV length → nil; sparse file: KLV value 100 MiB (ftruncate) with frame-size field 5000 → MXFFrame(length 5000); with frame-size field 70 MiB → nil
func testLimitsStopTheScan()                                  // 5000 fill packets then picture → nil (packetLimit); picture placed after scanLimit bytes of fill (use small scanLimit arg) → nil; shouldContinue false after 3 calls → nil and no more than 4 header reads
func testHeadersOnlyAreRead()                                 // descriptor wrapped in a pipe? No: use a counting approach: place a picture frame after N packets whose values are in a sparse hole; a successful locate proves values were not read (reading a hole is fine) — instead assert via DTrace-free method: value regions filled with 0xFF and total `read` calls counted by an injected reader is not available; so assert by time: locate on a 2 GiB sparse file with 10 packets completes under 50 ms.
func testOverflowingLengthsAreNil()                           // length field 0x7F FF FF FF FF FF FF FF FF (8 bytes near max) at offset near end → nil without trap
```

- [ ] **Step 2: Verify failure** — `cd Packages/BitMatchEngine && swift test --filter MXFFrameLocatorTests` → compile error, types undefined.
- [ ] **Step 3: Implement** per the spec's locator section. BER: first byte `< 0x80` short form; `== 0x80` nil; else `n = b & 0x7F`, `n ≤ 8`, big-endian accumulate into `UInt64`. Run-in: read the first `min(65536, fileSize)` bytes once, find the partition-pack prefix, start there. Picture value: `pread` 8 bytes at the value offset; require `icpf` and frame size ≥ 32, else nil.
- [ ] **Step 4: Verify pass**, then `swift test` (whole engine) green under the lock.
- [ ] **Step 5: Commit** `feat(engine): bounded MXF first-frame locator`

---

### Task 2: ProResFrameDecoder (Shared)

**Files:**
- Create: `Shared/Core/Services/ProResFrameDecoder.swift`
- Create: `BitMatchTests/ProResFrameDecoderTests.swift` (base64 constants of the three fixtures; a helper that returns the frame bytes by slicing at 6164 with the known length)

**Interfaces:**
- Produces:
  ```swift
  enum ProResFrameDecoder {
      static let maximumPixels = 40_000_000
      static let maximumSide = 8192
      struct Header: Equatable { let frameSize: Int; let width: Int; let height: Int; let is444: Bool }
      static func header(of frame: Data) -> Header?          // nil on every validation failure in Global Constraints
      static func image(frame: Data, maximumSize: CGSize) -> CGImage?   // nil when header is nil or decode fails
  }
  ```

- [ ] **Step 1: Write the failing tests** (Swift Testing)

```swift
@Test func decodesTheOrangeFixtureFrameToAFittedImage()       // 64x64 LT → image ≤ 256×144, square (w == h), center pixel R > 200, 80 ≤ G ≤ 200, B < 80
@Test func keepsAspectAndNeverUpscales()                      // 64x48 LT with maximumSize 256×144 → 64×48 exactly (no upscale); with maximumSize 32×32 → 32×24
@Test func decodesHQAndLTUnderTheSameFormat()                 // 64x64 HQ decodes; header(of:).is444 == false for both
@Test func rejectsBeforeDecoding()                            // every prefix 1…31 bytes → header nil; tag "icpg" → nil; frameSize field = count+1 → nil; headerSize 10 → nil; width 16384 & height 16384 → nil; 8000×8000 (64 MP) → nil; 6560×3100 passes header validation (ALEXA 65)
@Test func emptyDataIsNil()
```

- [ ] **Step 2: Verify failure** — filtered xcodebuild: `-only-testing:BitMatchTests/ProResFrameDecoderTests` → compile error.
- [ ] **Step 3: Implement** per the spec's decoder section: `CMVideoFormatDescriptionCreate` with `kCMVideoCodecType_AppleProRes4444` or `kCMVideoCodecType_AppleProRes422HQ`; `CMBlockBufferCreateWithMemoryBlock` over a `malloc`ed copy with `kCFAllocatorDefault` as block allocator (owned); `VTDecompressionSessionCreate` with `kCVPixelBufferPixelFormatTypeKey: 32BGRA`, `kCVPixelBufferWidthKey/HeightKey` at the fitted size; `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:infoFlagsOut:outputHandler:)` then `WaitForAsynchronousFrames`; `CIContext` → `CGImage`; all inside `autoreleasepool`, `defer { VTDecompressionSessionInvalidate }`.
- [ ] **Step 4: Verify pass.**
- [ ] **Step 5: Commit** `feat(reports): decode one ProRes frame with VideoToolbox`

---

### Task 3: Wire MXF into ReportThumbnailService

**Files:**
- Modify: `Shared/Core/Services/ReportThumbnailService.swift` (`frame(_:timeout:)`, new `mxfFrame`, shared queue)
- Modify: `BitMatchTests/ReportThumbnailTests.swift` (add cases; reuse base64 fixtures from Task 2 via a shared test helper file `BitMatchTests/MXFFixtures.swift`)

**Interfaces:**
- Consumes: `MXFFrameLocator.firstPictureFrame(at:shouldContinue:)`, `MXFFrameLocator.readFrame`, `ProResFrameDecoder.image(frame:maximumSize:)`.
- Produces: `ReportThumbnailService.frame` unchanged signature; `static let mxfQueue = DispatchQueue(label: "BitMatch.report-preview.mxf")`; `static func mxfFrame(_ url: URL, timeout: TimeInterval) async throws -> Data?`; JPEG encoding factored into `static func jpeg(_ image: CGImage) -> Data?` reused by both paths.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func mxfBackupProducesAJPEGPreview()                    // .mxf row, backup = 64x64 LT fixture file → images[row.path] starts FF D8, ≤ 64 KB; requestedCount 1
@Test func uppercaseMXFIsDispatchedTheSameWay()               // ".MXF" path and file → preview present
@Test func nonProResMXFGetsNoPreviewAndNoError()              // hand-built MXF: partition pack + picture KLV whose value is 300 zero bytes → images empty, no throw
@Test func zeroTimeoutReturnsNilWithoutDecoding()             // ReportThumbnailService.frame(url, timeout: 0) on fixture → nil
@Test func stalledMXFReadDoesNotBlockTheNextClip()            // a FIFO (mkfifo) as the backup path: O_NONBLOCK open + fstat not regular → nil immediately; and a locator shouldContinue that is false at deadline (inject via timeout 0.05 and a 10 MiB-of-fill fixture built in the test) returns nil within 0.5 s
@Test func cancelledCollectionDoesNotStartAnotherMXFClip()    // mirror of cancellationDuringCollectionDoesNotStartAnotherClip with .mxf rows
@Test(.enabled(if: ProcessInfo.processInfo.environment["BITMATCH_ARRI_SAMPLE"] != nil)) func arriSampleProducesAPreviewWithinBudget()   // full collect on the ARRI path → JPEG, decode measured < 2 s, image 256×144
```

- [ ] **Step 2: Verify failure** — the first three fail (AVFoundation path returns nil for MXF).
- [ ] **Step 3: Implement**: in `frame`, `if url.pathExtension.lowercased() == "mxf" { return try await mxfFrame(url, timeout:) }`. `mxfFrame`: same continuation + timer pattern as `ThumbnailRequest` but the work block is `mxfQueue.async`: check deadline, open/locate (with `shouldContinue: { Date() < deadline }`), read, check deadline, decode, JPEG; resume once under the lock. Refactor the existing JPEG encoding into `jpeg(_:)`.
- [ ] **Step 4: Verify pass**; `./test.sh mac-test` green under the lock; `BITMATCH_ARRI_SAMPLE=/Users/mike/Downloads/F003C002_190925_MN99.mxf` filtered run green.
- [ ] **Step 5: Commit** `feat(reports): MXF ProRes clip previews`

---

### Task 4: Changelog, iPad run, full verification

- [ ] Changelog (Unreleased): "Reports now show clip previews for ProRes clips inside MXF files (ARRI ALEXA family), found and decoded by BitMatch itself since macOS does not open MXF for third-party apps. Other MXF content (ARRIRAW, Sony XAVC) still has no preview."
- [ ] `xcrun simctl list devices available | grep iPad` → pick a destination; `IOS_SIMULATOR_DESTINATION="platform=iOS Simulator,name=<iPad>" ./test.sh ipad-test` → the decoder tests must run and pass there (check the log names `ProResFrameDecoderTests`).
- [ ] `./test.sh engine-test`, `./test.sh mac-test`, `./test.sh ipad-build` green; record the lines.
- [ ] Commit `docs: changelog for MXF previews`
