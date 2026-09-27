# BitMatch Development Guide

Read [docs/THESIS.md](docs/THESIS.md) for what BitMatch promises and the current plan, and [ARCHITECTURE.md](ARCHITECTURE.md) for how the code is laid out. [AGENTS.md](AGENTS.md) has the platform rules every change follows. This guide covers building, testing, debugging and releasing.

## Building

- Xcode 16 or newer; CI uses Xcode 16.4. Open `BitMatch.xcodeproj`.
- Schemes:
  - `BitMatch`: the macOS app (macOS 15.5 or newer).
  - `BitMatch-iPad`: the iPhone and iPad app (iOS/iPadOS 18.5 or newer). Despite the name it targets both device families.
- Both apps compile everything under `Shared/` and depend on the local package `Packages/BitMatchEngine`. Everything builds in Swift 6 language mode; keep it warning-free. `bash test.sh engine-test` runs the engine's own tests in seconds.
- For an iPhone or iPad device build, set your development team in Signing & Capabilities.

## Where changes go

- **The engine and its rules** live in `Packages/BitMatchEngine`: copy, verify, safety, readiness (`TransferReadiness`), what may be chosen (`DestinationSelectionPolicy`, `BackupTargetPolicy`), the verdict (`ResultOutcome`, `TransferCompletion`), evidence and the journal. The one state owner, `SharedAppCoordinator`, and the presentation models live in `Shared/Core/`.
- **Screens** live in `Shared/Views/`. Each draws a pure presentation value (`*Presentation` in `Shared/Core/Models/`) and decides nothing itself. Put a new rule in the presentation or model, with a test, not in a view.
- **Platform code** stays in `BitMatch/` (Mac) or `BitMatch-iPad/` and `Platforms/iOS/` (iPhone and iPad), and should be limited to what only that platform can do: pickers, drag and drop, panels and share sheets, Disk Arbitration and volume monitoring, SFTP (Mac only). Shared screens take these as slots or closures (`SetupLocationsPlatform`, `MasterReportPlatform`, the `CoordinatorSetupScreen` slots).
- Files in `Shared/` must compile on both platforms. Wrap AppKit or UIKit use in `#if os(...)`.

### Transfer safety boundary

Safety checks belong in the shared engine, not only in views. Readiness on Setup explains a problem early, but `TransferPipeline` and `SafetyValidator` must still refuse an unsafe source or backup when called directly, and `BackupTargetPolicy` must guard every path that adds a backup.

Required behavior (see `Packages/BitMatchEngine/Sources/BitMatchEngine/File/SafetyValidator.swift`, `DestinationWriter.swift`, `BackupTargetPolicy.swift`, and `Packages/BitMatchEngine/Sources/BitMatchEngine/TransferPipeline.swift`):

- never write to the source; never overwrite an existing destination file
- copy to a temporary file and publish it only after sync, a size check and a source-stability check, without replacing anything (hard link, or an exclusive name claim on exFAT/FAT)
- refuse output roots that collide with the source, each other, symlinks, files or nested folders
- include hidden files and empty folders; skip symlink entries
- use uncached checksums for live verification and evidence
- write result status only through `ResultOutcome`; a Quick copy is never "verified"

### Execution path

Platform views present the selection and readiness. Start (the button and ⌘R) calls `SharedAppCoordinator.startCurrentMode()`, which builds a `CopyVerifyConfig` for `CopyVerifyExecutor`. The executor owns timing, error tracking, result coalescing, the sleep assertion, ASC MHL and report handoff, and the verdict. It calls `TransferPipeline`, which runs the real preflight and transfer. Do not add a platform-only transfer path, and do not rely on UI validation as the safety boundary.

Live progress and per-file rows reach views through `LiveProgressFeed` and `LiveResultsFeed`, not through the coordinator's `objectWillChange`. A view that draws live progress or rows observes the feed directly; do not republish per-tick values on `SharedAppCoordinator`.

## Testing

Run the named jobs from the repository root:

```bash
bash test.sh mac-test        # BitMatchTests on macOS
bash test.sh mac-build       # macOS Debug build
bash test.sh ipad-build      # iOS simulator Debug build (the shared-code gate)
IOS_SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPad (A16)' bash test.sh ipad-test
bash test.sh release-builds  # macOS and iOS simulator Release builds
```

`ipad-test` refuses to guess a simulator; set `IOS_SIMULATOR_DESTINATION` to one installed on your machine. Set `DERIVED_DATA_ROOT` to reuse a build folder (default `.derived-data/`).

`.github/workflows/ci.yml` defines `mac-test` and `ipad-build` jobs on push and pull request. The README notes that GitHub Actions is currently disabled for the repository, so run both locally before submitting changes.

### Change workflow

1. Read the shared path before changing copy, verification, preflight, state, readiness or report behavior.
2. Add or update a focused test in `BitMatchTests` (or `BitMatch-iPadTests` for iOS-only behavior). Tests that guard a rule carry a **Plant:** comment: a one-line production change that must make them fail. Try it, see the test fail, revert.
3. Run `bash test.sh mac-test`.
4. Run `bash test.sh ipad-build` after every change to shared code or a presentation model.
5. For UI changes, check an iPhone width (under 600 pt), an iPad split view (600–959 pt) and a Mac window from its 580 pt minimum to wide. Say which checks ran in a simulator and which on a device.
6. Run `bash test.sh release-builds` before release work.
7. Automated tests are not proof of physical-media safety. Use the scripts below and `docs/HARDWARE_TESTING.md`, with throwaway data, when a change can affect transfer reliability.

### Useful test helpers

- `BitMatchTests/TestHelpers/FakeFileSystemService.swift`: the one fake `FileSystemService`.
- `DisposableTransferFixture` and `TestFixtures`: real temporary folders.
- `CameraCardLayouts`: folder trees for camera cards.
- `SharedCoordinatorTestSupport`: builds a `SharedAppCoordinator` for tests.
- `WorkflowSnapshotTests` (both test targets) render the real screens with seeded data. They are skipped unless `BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS=1` is set.

### Coverage

```bash
xcodebuild test -scheme BitMatch -enableCodeCoverage YES -resultBundlePath coverage.xcresult
xcrun xccov view --report coverage.xcresult
xcrun xccov view --report --json coverage.xcresult
```

### Reliability diagnostics and hardware testing

- `Scripts/run_apfs_fault_tests.sh` creates and removes a marked, disposable APFS image, then checks the case in which one destination becomes inaccessible while another succeeds.
- `Scripts/run_soak_tests.sh` runs repeatable transfer stress. Set `BITMATCH_SOAK_SEED` and `BITMATCH_SOAK_ITERATIONS` to reproduce a failure; the defaults are `20260711` and `25`. It prints validated JSON before removing its marked temporary folder.
- `Scripts/ascmhl/validate_reference.sh` checks generated ASC MHL against the official reference tooling.
- For cable removal, sleep, low-power hubs, exFAT and other physical-media cases, follow [docs/HARDWARE_TESTING.md](docs/HARDWARE_TESTING.md) and record results in [docs/HARDWARE_COMPATIBILITY.md](docs/HARDWARE_COMPATIBILITY.md). The automated APFS and exFAT disk-image tests do not prove that real hardware faults are safe.

## Debug tools (Mac)

Debug builds of the Mac app have a **Developer** menu (`BitMatch/App/BitMatchApp.swift`, `#if DEBUG`):

- **Open Interface Lab** (⌥⌘L): launches a second app instance with `--interface-lab`, a no-I/O visual harness with its own sample screens (`BitMatch/Views/InterfaceLab/`).
- **Enable/Disable Dev Mode** (⌥⌘D). The items below need Dev Mode on.
- **Fill Test Data** (⌥⌘T): fills in a sample source, backups and detected camera.
- **Stress Test (Small / Medium / Large)**: runs a real copy between generated folders in the temp directory.
- **Verbose Dev Logs.**
- **Clear All Data**: resets the last operation's results and state.

`DevModeManager` (`BitMatch/Core/Services/DevModeManager.swift`) implements them. None of this exists in Release builds. iPhone and iPad have no debug menu.

## Debugging notes

- **Folder picking on iOS does nothing.** `IOSFileSystemService` retains its document-picker delegate (`currentDelegate`) until the picker finishes; check that it is still retained and that the picker is presented from a valid view controller. Look for "SWIFT TASK CONTINUATION MISUSE" in the console.
- **File access denied on iOS.** Every scan, size check and copy must hold security-scoped access, released with `defer`. See `IOSFileSystemService` and `SharedAppCoordinator.executeOperation`.
- **A backup is refused on a device but not in the simulator.** Simulator paths sit under the Mac's `/Users`; device Files locations sit under `/private/var/mobile`. `SafetyValidator.isProtectedSystemPath` treats that as user storage on iOS only (`BitMatch-iPadTests/IOSStoragePathTests.swift`).
- **A view does not update.** State that drives UI should be `@Published` on `SharedAppCoordinator` or a model it forwards, except live progress and rows, which views observe on `LiveProgressFeed`, `LiveResultsFeed` or `ProgressPresentationModel` directly.
- **Concurrency.** Do heavy file-system enumeration off the main actor and marshal results back. Do not iterate `NSDirectoryEnumerator` with `for in` inside async code; use `while let url = enumerator.nextObject() as? URL`. Do not call actor-isolated methods from nonisolated initializers.
- **Logging.** Use `SharedLogger`. `AppLogger` (Mac) forwards to it.

## macOS release

Prerequisites: a Developer ID Application certificate for the release team, a notarytool profile named `bitmatch-notary` (override with `NOTARY_PROFILE`), and a Sparkle EdDSA key in the login Keychain.

```bash
xcrun notarytool store-credentials bitmatch-notary \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "AUJW7AGG26" \
  --password "APP_SPECIFIC_PASSWORD"

Scripts/release_mac.sh 0.1.7
```

The script builds, signs, notarizes, staples and checksums `dist/BitMatch-<version>.dmg` with a matching `.sha256`. `SKIP_NOTARIZE=1 Scripts/release_mac.sh <version>` checks signing and DMG creation without submitting to Apple. iPhone and iPad are build-from-source for now.

Back up the Sparkle private key before the first release and store the export securely. From Sparkle's resolved package artifacts, run `generate_keys -x <private-key-file>`. Never commit the exported key. Use `generate_keys -f <private-key-file>` to restore it on another Mac.

Before tagging, run the signed app from `dist/BitMatch-<version>.xcarchive` against real or disk-image volumes: allow drive access, copy a card to two destinations, check "safe to erase", Eject, and relaunch. Debug builds and tests do not exercise the sandboxed release paths.

After publishing the GitHub release, publish its signed appcast entry:

```bash
Scripts/publish_appcast.sh 0.1.7
```

The script reads the archived app's build and short versions, signs the matching DMG with Sparkle's `sign_update` and the login Keychain, updates `appcast.xml` in [BitmatchApp/bitmatchapp.github.io](https://github.com/BitmatchApp/bitmatchapp.github.io), then commits and pushes the newest entry. It uses the resolved Sparkle package's tool when available and downloads the matching Sparkle release tools otherwise. It never exports the private key.

Then run `Scripts/bump_cask.sh <version>`. It checks the published DMG against the local checksum, updates `Casks/bitmatch.rb` in [BitmatchApp/homebrew-tap](https://github.com/BitmatchApp/homebrew-tap), pushes it, and runs `brew audit`. `brew upgrade bitmatch` sees the release from then on.

## Conventions

- Keep shared vs platform boundaries: no AppKit or UIKit in shared files outside `#if os(...)`.
- Main-actor correctness for anything that touches UI; progress callbacks reach the coordinator on the main actor.
- New copy or verify behavior has tests for overwrite, source change, hidden files, symlinks and reporting.
- Use `BitMatchError` or `FileOperationError` for user-facing errors, with a message that says what to do.
- No naked TODOs in committed code: write "Future enhancement:" with intent, or file an issue.
- Cancel does not delete copied files. Cancel-time cleanup stays disabled until the pipeline has more field validation.
- Do not replace screenshots with mocks, stale simulator images, or views that show personal paths or media.
