# MXF ProRes report previews

Date: 2026-11-20. Branch: fix/mxf-report-previews. Follow-up to #91 (reporter: Codex Compact Drive, ProRes MXF; reports show no clip previews).

## Intent

Reports with "Clip previews" on show a frame for ProRes clips in an MXF wrapper (ARRI ALEXA family, also Panasonic and Canon ProRes MXF), the way they do for `.mov` and `.mp4` today.

## Why it does not work today, and cannot via AVFoundation

`ReportThumbnailService` asks AVFoundation (`AVAssetImageGenerator`) for a frame. Measured on macOS 27 with Apple's Pro Video Formats installed: every third-party AVFoundation client fails to open an MXF with "Cannot Open" (command-line tool, unsandboxed app bundle, sandboxed app bundle, Intel build under Rosetta); Apple's own `avmediainfo` fails too. QuickTime Player opens the same file. Apple's MXF reader is a MediaToolbox format-reader plug-in (`AppleMXFImport.bundle`, x86_64 only, 2007–2020) that only Apple's apps get. No BitMatch version has ever produced an MXF preview; the extension was never listed either.

## What works (spike on the ARRI sample F003C002, 1080p ProRes 4444, and on ffmpeg-made files)

MXF is a flat sequence of KLV packets (16-byte SMPTE key, BER length, value). The first picture essence element (key prefix `06 0E 2B 34 01 02 01 01 0D 01 03 01 15`, generic-container picture) sits within the first few dozen packets, well under 1 MB in. Its value is one complete ProRes frame: a self-describing bitstream starting with a 4-byte frame size and the `icpf` tag, carrying width, height and chroma format in its own header. VideoToolbox's public ProRes decoder (`VTDecompressionSession` with a format description of type `ap4h` for 4:4:4 or `apch` for 4:2:2) decodes that frame to a pixel buffer. The ARRI frame decoded to 1920×1080 in milliseconds; a 64×64 one-frame ffmpeg MXF (7.7 KB) parses and decodes identically.

## Goals

- A verified ProRes MXF clip on the backup gets a preview in the PDF, under the existing caps (200 previews, 30 s total, 2 s per clip, 64 KB per image, 256×144).
- No third-party code. The MXF reading is a bounded in-house scan; decoding is VideoToolbox.
- A clip the scan cannot handle gets no preview, exactly as an unsupported clip today, with nothing else affected.

## Non-goals and anti-goals

- Not a general MXF demuxer: no index tables, partitions, descriptors, audio, timecode or metadata. First picture frame only.
- Not Sony XAVC (H.264/HEVC in MXF), ARRIRAW, DNxHD, or clip-wrapped essence with no ProRes header at the start. Those stay without previews (ARRIRAW is not a ProRes bitstream; XAVC is a follow-up on the same shape).
- Never read more than a bounded prefix of a file; never allocate more than the frame cap; never let a preview failure touch transfer evidence, as today.

## Approaches

1. **Bundle an open-source MXF library (libMXF, or ffmpeg's demuxer).** Full container support, but C code inside a sandboxed, notarized Swift app, licence and build burden, and far more surface than a thumbnail needs. Rejected.
2. **Own bounded KLV scan + VideoToolbox decode.** About two hundred lines, pure Swift, testable with a 7.7 KB fixture; decoding uses Apple's own ProRes decoder. Chosen.
3. **Tell users MXF previews are not possible.** True for AVFoundation, false in general. Rejected.

## Design (approach 2)

**Engine, pure Swift, no media frameworks:** `MXFFrameLocator` in `BitMatchEngine`.

- `static func firstPictureFrame(in url: URL, scanLimit: Int = 64 MiB, packetLimit: Int = 4096, frameLimit: Int = 64 MiB) throws -> MXFFrame?` where `MXFFrame` is `(offset: Int64, length: Int)`.
- Reads with a file handle using `pread`-style offset reads of headers only (16-byte key + up to 9-byte BER length) and skips values; it never reads a value except the picture frame it returns the location of. Stops at the first picture element, at `packetLimit` packets, at `scanLimit` bytes, at end of file, or at the first malformed packet (key not starting `06 0E 2B 34`, BER length longer than 8 bytes, zero or negative length, length past end of file), returning nil.
- A value longer than `frameLimit` is not a frame: nil.
- Clip-wrapped essence (one value holding every frame): the picture value's first 4 bytes are the ProRes frame size; when that is smaller than the KLV length, the locator returns that size. When it is larger, nil.
- Only the first file in a multi-file (OP-Atom) set is ever looked at; if the picture element is not in this file, nil.

**Shared, VideoToolbox:** `ProResFrameDecoder` next to `ReportThumbnailService`.

- `static func image(frame: Data, maximumSize: CGSize) throws -> CGImage?`
- Validates the header: bytes 4–7 are `icpf`; width and height at 16–19 are 16 to 16384; chroma format bits are 4:2:2 or 4:4:4. Anything else: nil (no decode attempted).
- Codec type `ap4h` for 4:4:4, `apch` for 4:2:2 (the decoder accepts any ProRes 4:2:2 profile under that type; measured with an LT-profile frame). A frame with alpha still decodes; the preview drops alpha.
- Builds a `CMVideoFormatDescription`, a `CMSampleBuffer` over the frame bytes, and a `VTDecompressionSession` with BGRA output; decodes synchronously; downscales to `maximumSize` and returns the `CGImage`. The session is created per call and invalidated after; no caching.

**Wiring:** `ReportThumbnailService.frame(_:timeout:)` dispatches by extension: `mxf` goes to a new `mxfFrame(url, timeout)` that runs the locator, reads only the frame bytes, decodes, and JPEG-encodes through the same path as today (`maximumSize` 256×144, 64 KB cap). Everything else keeps the AVFoundation path. The timeout keeps its meaning: the work runs on the existing serial queue with the existing timer, so a stalled read or decode still returns nil at the deadline and cancellation still stops the next clip. Failures are swallowed exactly as today.

**iOS:** VideoToolbox exists on iOS; the same code compiles there. No iOS-specific behavior.

## Fixtures and tests

- `tiny-prores.mxf` (7.7 KB, ffmpeg, 64×64, one orange ProRes LT frame) as a base64 constant in the engine tests and the Shared tests, the way `previewFixture` is today. Nothing from ARRI enters the repo.
- Engine: locator finds the frame in the fixture at the known offset and length; returns nil for a non-MXF file, a truncated file, a file whose first packet claims a 2 GB value, a file with 5000 non-picture packets, an empty file; never reads past `scanLimit` (measured with a counting file handle or by placing the fixture after `scanLimit` bytes of padding).
- Shared: decoder returns a 64×64 image for the fixture frame; nil for a frame whose tag is not `icpf`, for absurd dimensions, for an empty `Data`.
- Shared: `ReportThumbnailService.collect` with a verified `.mxf` row whose backup is the fixture produces a JPEG under 64 KB; a `.mxf` row pointing at a non-ProRes MXF (the DNxHD ffmpeg file, generated in the test) produces no image and no error.
- Opt-in real media: `BITMATCH_ARRI_SAMPLE=/path/to/F003C002_190925_MN99.mxf` runs the full path on the ARRI clip and asserts a 256×144 JPEG within the 2 s per-clip budget.
- Mac suite and engine suite green; iPad build green.

## Left to the builder

Exact BER handling for the 1-byte short form (lengths under 128), the choice between `FileHandle` and `open`/`pread`, and the JPEG encoding reuse.
