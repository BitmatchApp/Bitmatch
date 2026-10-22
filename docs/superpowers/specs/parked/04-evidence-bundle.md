> **Status: Parked.** Parked on 2026-10-21 after review. Not scheduled. The original proposal follows unchanged below the line.
>
> **Blockers found in review**
> - docs/TODO.md excludes proxy generation, transcoding and Final Cut workflows without clear user need; this builds exactly those plus a contact sheet.
> - Reports and MHL output already exist; most of the bundle duplicates them in a new container.
>
> **Worth keeping:** Receipt-last atomicity and independently toggleable artifacts are good design. A narrow version, zip the existing report artifacts plus a one-page receipt, is a half-day feature if asked for. No transcoding.
>
> **Un-park when:** A named user asks for a hand-off bundle; scope starts at reports + receipt only.

---

# 4. Verify-and-emit evidence bundle

## Goal

A first-class **"drop a folder, verify it, emit a bundle"** workflow: verify a card or folder
against its checksums, then produce a toggleable set of evidence and media artifacts that a
producer can hand off or archive.

## Scope

**In scope**

- A bundle run over an already-copied folder (or card), producing, each independently
  toggleable:
  - a **contact sheet** (image grid of clips, one thumbnail each);
  - an **EXIF/metadata CSV** (clip name, camera, capture date, resolution, duration, codec);
  - an **HTML tree/report** (navigable list of what was verified);
  - an **MHL manifest** (reusing the existing ASC MHL output);
  - **proxy media** (configurable codec and frame scale, for an offline edit);
  - a **Final Cut proxy folder** (a folder FCP can ingest directly);
  - a **receipt** (a short human summary of what was verified and when).
- Exclusion patterns and hidden-file handling, configurable per run.
- Auto-open the bundle after creation (opt-in).

**Out of scope**

- Transcoding for delivery/color or dailies workflows.
- Media cataloging, playback, or editing.
- A cloud dashboard or full project management.
- Re-verifying the *source card* (the bundle verifies a copy, not the card).

## Where it lands

- `Packages/BitMatchEngine` — the pure `EvidenceBundlePlan` (which artifacts are requested)
  and `EvidenceBundleResult` (what was produced and its verification outcome). Verification
  itself reuses `FolderComparer` / `SavedChecksumCheck`.
- `Shared/Core/Services/` — `EvidenceBundleBuilder` (orchestrates the artifacts) and the
  presentation model, alongside `ReportExporter` and `ReportScanner`.
- `Shared/Views/` — the bundle screen, reusing the `Compare`/`MasterReport` presentation
  patterns.
- `Platforms/macOS/` + `Platforms/iOS/` — the platform bits (proxy codec selection uses
  AVFoundation; Final Cut folder writing is a folder layout, not a platform API).

## Design

### The plan

A bundle run is one config object and one result object:

```swift
// Packages/BitMatchEngine/Sources/BitMatchEngine/Evidence/EvidenceBundle.swift
public struct EvidenceBundlePlan: Codable, Sendable {
    public var contactSheet: Bool = true
    public var metadataCSV: Bool = true
    public var htmlTree: Bool = true
    public var mhlManifest: Bool = true
    public var proxyMedia: Bool = false
    public var proxyCodec: ProxyCodec = .h264
    public var proxyScale: ProxyScale = .half
    public var finalCutProxyFolder: Bool = false
    public var receipt: Bool = true
    public var exclusionPatterns: [String] = []
    public var includeHidden: Bool = false
    public var autoOpen: Bool = false
}

public enum ProxyCodec: String, Codable, Sendable { case h264, hevc, proResProxy }
public enum ProxyScale: String, Codable, Sendable { case full, half, quarter }

public struct EvidenceBundleResult: Codable, Sendable {
    public let outputFolder: URL
    public let artifacts: [Artifact]           // what was actually written
    public let verification: VerificationSummary
    public let excludedCount: Int
    public let receiptURL: URL
}
```

### The flow

1. **Choose a folder.** The user picks (or drops) an already-copied folder; it must have been
   copied by BitMatch (so there are saved checksums / an MHL) — or the user opts into a fresh
   verify pass.
2. **Verify.** Reuse `SavedChecksumCheck` against the saved checksums/MHL. Verification runs
   first and is the gate: if it does not pass, the bundle is not produced (fail-closed).
3. **Emit.** `EvidenceBundleBuilder` walks the verified file list and, for each enabled
   artifact, writes it to the output folder. Each artifact is written atomically (temp file +
   rename) and a failed artifact is recorded, not silently skipped.
4. **Receipt.** Always last; it lists every artifact produced, the verification summary, and
   the exclusions. If any requested artifact failed, the receipt says so.
5. **Auto-open** (opt-in) reveals the output folder.

### Artifact details

- **Contact sheet** — a single image (or per-card images) laid out as a grid, one thumbnail
  per clip with the clip name underneath. Render with the platform image APIs; no external
  font or asset requirements.
- **Metadata CSV** — one row per clip: `name, camera, captureDate, duration, resolution,
  codec, size, digest`. Read from the media's metadata (AVFoundation) and the saved checksums.
- **HTML tree** — a static, self-contained HTML file (inline CSS, no JS dependencies) listing
  the verified files in a collapsible tree, with counts and the verification result.
- **MHL** — the existing `ASCMHLGenerator` output, unchanged.
- **Proxy media** — transcode each clip to the chosen codec and scale with AVFoundation, into
  a `proxies/` subfolder, preserving the source folder structure.
- **Final Cut proxy folder** — a folder laid out the way Final Cut expects proxy media
  (relative paths mirroring the original, with proxy-named files), so it can be imported
  directly.
- **Receipt** — a short text/markdown summary, written last.

### Exclusion semantics

Exclusions apply only to the *bundle* (proxy/contact sheet/metadata), never to verification:
a file excluded from the bundle is still verified if it is in scope of the checksum check, and
the receipt records both "verified" and "bundled" counts separately. This mirrors the existing
"verify selected vs whole card" distinction and keeps evidence honest.

## Safety & verdict semantics

- Verification is the gate; no bundle is produced from a failed verify.
- The bundle is evidence *about* a verified copy, not a fresh verification of the card, and it
  never claims source assurance.
- A partially-emitted bundle is clearly incomplete: the receipt is the last file written, and
  its presence (plus the recorded artifact list) is what makes a bundle "complete."
- The safe-to-erase verdict is not touched by a bundle run.

## Acceptance criteria

- **Gate:** a folder that fails verification produces no bundle and a clear error. `Plant:`
  build the bundle without running verification and see the test fail.
- **Toggle independence:** disabling an artifact omits it and does not affect the others.
  `Plant:` always write the contact sheet regardless of the flag and see the test fail.
- **Receipt correctness:** the receipt lists exactly the artifacts written, plus the
  verification summary and exclusion count. `Plant:` hardcode the artifact list and see the
  test fail.
- **Atomicity:** a simulated failure mid-bundle leaves already-written artifacts intact and
  records the failed one; the receipt (never written on failure) is absent, so the folder is
  not mistaken for complete.
- **Metadata CSV:** columns are stable and the digest column matches the saved checksums for a
  fixture card.

## Validation gates

- `bash test.sh engine-test`, `bash test.sh mac-test`, `bash test.sh ipad-build`.
- A manual run on a small fixture card, confirming the contact sheet renders, the CSV parses,
  the proxy plays, the FCP folder imports, and the receipt is accurate.
- Confirm the bundle does not affect existing `Compare`, `Master Report`, or safe-to-erase
  behavior.
