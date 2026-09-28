# To do

The working list for BitMatch. Newest decisions at the top of each section. When something ships, move it to the [changelog](../CHANGELOG.md) and delete it here.

## Next update (0.2.2)

Small, safety-first, no new settings.

- [ ] **"Don't format the card" wording.** When the card itself was the problem (it changed or read unreliably), say plainly: do not format this card. Keep that distinct from "a backup failed", where the card is fine.
- [ ] **Card-untouched test.** A test that hashes the entire source tree (names, sizes, dates, contents, extended attributes) before and after a transfer and proves nothing changed, in every verification mode.
- [ ] **xxHash64 for verification.** Use xxHash64 as the verification hash, which ASC MHL supports natively. The XXH64 reader already exists in `SavedChecksumCheck.swift`. Measure before and after with `RealCopyBenchTests` on a fast drive.
- [ ] **MHL round trip.** Confirm that a second offload onto the same drive adds a new ASC MHL generation to the existing history chain, and that Check verifies against an existing MHL. Fix whatever doesn't.
- [ ] **macOS 15.0.** Find out whether the minimum can drop from 15.5 to 15.0 at no cost. Don't go below 15; Swift 6 `Mutex` and some SwiftUI APIs need it.
- [ ] **Re-copy files that fail verification.** When a file this run just wrote fails verification, re-copy and re-verify it once automatically. Never overwrite files that were already on the drive before the run.
- [ ] **Opt-in crash reports.** Apple's MetricKit crash and hang diagnostics, off by default. Nothing is sent without the user saying yes, and no third-party service.

## Later (after the feature freeze)

- [ ] **Organize and rename.** Naming patterns, folder presets and organize-by-date on the destination, built on project transfers and camera naming. The biggest remaining workflow gap.
- [ ] **Slow-cable hint.** When a fast drive or card reader is connected at USB 2 speed, say so in one quiet line on the Mac (for example "T9 is connected at USB 2 speed. A faster cable could make this copy about 25× quicker.").
- [ ] **Time estimate before Start.** Show an estimate on the setup screen from the card size and recent measured speeds.
- [ ] **One destination out of space.** Pause just that destination, let the user free space, then resume. Today that destination fails and the others finish.
- [ ] **Offload from Finder.** A Finder action (right-click a card, then "Offload with BitMatch").
- [ ] **Shortcuts support** (App Intents), so offloads can be automated.
- [ ] **Per-destination notes** written into the report and the ASC MHL.
- [ ] **Cloud destinations**, if users ask for them.
- [ ] **SFTP on a persistent connection** instead of one `ssh` process per file, if SFTP becomes a headline feature.
- [ ] **Copy-completion notification on iPhone** for a Mac offload.
- [ ] **"How verification works"** explainer in the Guide.
- [ ] **Liquid Glass pass** on macOS/iOS 26 (toolbar, composer, rows, safe-to-erase moment), with a material fallback. Check it in person before merging.
- [ ] **VoiceOver pass** on real devices (see [THESIS](THESIS.md)).

## Needs hardware

- [ ] **Two-drive speed test** with two fast external drives on 10 Gb/s cables, run through `RealCopyBenchTests`. Then delete the test card `bench-card` from the T9.
