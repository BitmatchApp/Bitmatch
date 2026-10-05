# BitMatch Architecture

This document describes the code as it is today. It covers what exists and where it lives, not history or plans. For what BitMatch promises, and the plan for bringing the code in line with those promises, read [docs/THESIS.md](docs/THESIS.md).

Paths are relative to the repository root. Symbols are cited by type or function name rather than line number, because line numbers drift.

## Targets

`BitMatch.xcodeproj` defines six targets. Both apps depend on one local Swift package, `Packages/BitMatchEngine` (the engine; see below). Every target, and the package, builds in Swift 6 language mode with no concurrency warnings.

### The engine package

`Packages/BitMatchEngine` holds the code that makes promises 1-3 true, with no UI imports: `TransferPipeline` (one copy-and-verify run), `CardSource` (the fail-closed source manifest), `DestinationWriter` (pinned, never-replace writes and verified reads), `ChecksumEngine`, `FolderComparer` (folder comparison), `SavedChecksumCheck` (checking files against saved reports and MHL records), `TransferCompletion` (result rows, the ASC MHL plan and the verdict), `TransferJournal`, `EvidenceWriter` and `EvidenceReader` (CSV, JSON, checksum manifest; reading reports back), `ASCMHLGenerator`, and the shared rules `SafetyValidator`, `BackupTargetPolicy`, `DestinationSelectionPolicy`, `TransferReadiness` and `PathContainment`. App files `import BitMatchEngine`. Its own tests run with `bash test.sh engine-test` (`swift test`; runtime depends on enabled fixtures); tests that need app types stay in `BitMatchTests`.

| Target | Product | Platform | Compiles |
|---|---|---|---|
| `BitMatch` | macOS app | macOS 15.5 | `BitMatch/`, `Shared/`, and one file from `Platforms/`: `Platforms/macOS/Services/MacOSPlatformManager.swift` |
| `BitMatch-iPad` | iPhone and iPad app (`TARGETED_DEVICE_FAMILY = 1,2`) | iOS 18.5 | `BitMatch-iPad/`, `Shared/`, `Platforms/`, and one item from `BitMatch/`: `BitMatch.xcdatamodeld` |
| `BitMatchTests` | unit tests hosted in `BitMatch.app` | macOS | `BitMatchTests/`, including `BitMatchTests/TestHelpers/` |
| `BitMatchUITests` | UI tests for `BitMatch` | macOS | `BitMatchUITests/` |
| `BitMatch-iPadTests` | unit tests hosted in `BitMatch-iPad.app` | iOS | `BitMatch-iPadTests/` |
| `BitMatch-iPadUITests` | UI tests for `BitMatch-iPad` | iOS | `BitMatch-iPadUITests/` |

Target membership comes from Xcode file-system synchronized folders (`PBXFileSystemSynchronizedRootGroup`). Each target lists the folders it compiles; there are no per-file build phase entries. Only two single files cross over, each through a membership exception in `project.pbxproj`:

- `MacOSPlatformManager.swift` is added to the Mac target. The iPad target also compiles all of `Platforms/`, but that file's body is inside `#if os(macOS)`, so it compiles to nothing on iOS.
- The Core Data model `BitMatch/BitMatch.xcdatamodeld` is added to the iPad target.

Test targets reach app code through `@testable import`. `test.sh` wraps the `xcodebuild` invocations for these jobs: `mac-test`, `mac-build`, `ipad-build`, `ipad-test` (which needs `IOS_SIMULATOR_DESTINATION`), and `release-builds`. `DEVELOPMENT.md` covers building and testing.

## Source layout

| Folder | Role | Built into |
|---|---|---|
| `Shared/Core/Models/` | Value types (operation state, progress, results and `ResultOutcome`, verification modes, camera, photographer and remote-backup models), the pure rules `TransferReadiness` and `DestinationSelectionPolicy`, and the view-ready `*Presentation` types each shared screen draws | Both apps |
| `Packages/BitMatchEngine/` | The engine package (above) | Both apps, as a package product |
| `Shared/Core/Services/` | App services around the engine: `SharedAppCoordinator`, `CopyVerifyExecutor` (runs a transfer and its project lifecycle), `ComparisonCoordinator`, `ReportExporter` (PDF and project evidence), `ReportScanner`, `LocalTransferJournal` (observable journal), camera detection (`Camera/`), timing, errors | Both apps |
| `Shared/Core/ViewModels/` | `PhotographerJobViewModel`, `CameraLabelModel` (label suggestion, per-card memory, saved settings), `ProgressPresentationModel` (smoothed progress, speed and time left), `LiveProgressFeed` and `LiveResultsFeed` (live progress and per-file rows, observed apart from the coordinator) | Both apps |
| `Shared/Views/` | The SwiftUI screens both apps show: `Setup/`, `Progress/`, `Outcome/`, `Compare/`, `MasterReport/`, plus `TransferLibraryView` (queue and history), `CompareResultsView`, `TransferAttentionBanner` and `SkippedReportsNotice` | Both apps |
| `Platforms/iOS/Services/` | `IOSPlatformManager`, `IOSFileSystemService`, `IOSDriverScanner` (the Files folder picker for Master Report) | iOS app |
| `Platforms/macOS/Services/` | `MacOSPlatformManager` | Mac app (via the exception above) |
| `BitMatch/` | Mac app shell: `App/` (entry point, `ContentView`, `MacAppEnvironment`), `Core/ViewModels/MacVolumeAccessModel.swift`, Mac-only services, and the Mac adapters and slots for the shared screens | Mac app |
| `BitMatch-iPad/` | iPhone/iPad app shell: entry point, `ContentView`, the two layouts, and the iOS adapters and slots for the shared screens | iOS app |

Some files under `Shared/` are wrapped in `#if os(...)` and so exist on only one platform. `RemoteBackupQueue.swift`, `RemoteBackupCoordinator.swift`, and `RemoteBackupProvider.swift` are macOS-only. `IOSBackgroundTaskService.swift` is real on iOS and a no-op stub on macOS. `TransferSleepPreventer.swift` takes an idle-sleep assertion on macOS and does nothing on iOS.

## Screens

Every flow is one shared screen in `Shared/Views/`. Each screen draws a pure presentation value from `Shared/Core/Models/` and decides nothing itself. Layout follows the screen's own width through `AdaptiveNavigationPolicy` (`Shared/Core/Models/AdaptiveNavigationPresentation.swift`: compact under 600 pt, toolbar under 960 pt, sidebar above), not the device.

| Flow | Screen (`Shared/Views/`) | Presentation (`Shared/Core/Models/`) | Adapter from `SharedAppCoordinator` | What each platform adds |
|---|---|---|---|---|
| Setup | `Setup/SetupScreen.swift` | `SetupPresentation`, `StartButtonPresentation`, `TransferPlanPresentation` | `Setup/CoordinatorSetupScreen.swift`, one for all platforms | Slots for the location pickers, problem banners, project setup, camera label editor and project evidence. Mac: `BitMatch/Views/CopyAndVerify/MacSetupView.swift`. iOS: `BitMatch-iPad/Views/CopyAndVerifyView.swift` |
| Source and backup boxes | `Setup/SetupLocationsView.swift` | `SetupLocationsPresentation` | `Setup/CoordinatorSetupLocations.swift`, one for all platforms | A `SetupLocationsPlatform`. Mac: `MacSetupLocations.swift` (open panel, drag and drop, drop toast). iOS: `IOSSetupLocations` in `CopyAndVerifyView.swift` (Files picker, alert) |
| Advanced options | `Setup/TransferOptionsSection.swift` | `TransferOptionsPresentation` | takes bindings | Nothing. Compare uses the form with only the verification picker |
| Transfer queue and progress | `TransferQueueSection.swift`, `Progress/ProgressScreen.swift` | `QueueSessionPresentation`, `TransferProgressPresentation` | `TransferPresentationAdapters.swift`, one for all platforms | Running and finished transfers remain in expandable rows below Setup. iOS adds the Files-based Add Card action; Mac adds Eject and the composer transition |
| Outcome | finished content in `TransferQueueSection.swift` | `TransferOutcomePresentation` | journal records become immutable finished-row presentations | Retry, export, copy summary, destination evidence and the safe-to-erase hero adapt to row width; Eject is Mac-only |
| Compare | `Compare/CompareScreen.swift`, `CompareResultsView.swift` | `ComparePresentation`, including the shared coordinator builder and start gate | one thin view per platform: `BitMatch/Views/CompareFoldersView.swift`; `CompareFoldersView` in `BitMatch-iPad/Views/ModularContentView.swift` | Folder picking; dropping on the Mac |
| Master Report | `MasterReport/MasterReportScreen.swift` | `MasterReportModel`, `MasterReportPresentation` | one per platform, both named `MasterReportView` (`BitMatch/Views/`, `BitMatch-iPad/Views/`) | A `MasterReportPlatform`: open and save panels and Show in Finder on the Mac; the Files picker and share sheet on iOS |
| Transfers (queue and history) | `TransferLibraryView.swift` | `TransferLibraryPresentation` | none: it takes the coordinator and journal | Opened as a sheet from a toolbar button on every platform |

## App shells

### iPhone and iPad

- **Entry point.** `BitMatch-iPad/BitMatch_iPadApp.swift` registers the `com.bitmatch.app.transferprocessing` background-task handler and shows `ContentView`.
- **Coordinator.** `BitMatch-iPad/ContentView.swift` owns a `SharedAppCoordinator()` directly. Its iOS convenience initializer passes in `IOSPlatformManager.shared`.
- **Layout.** The layout is chosen by window width, not device idiom:
  - `.compact`: `BitMatch-iPad/Views/PhoneContentView.swift`
  - `.toolbar` or `.sidebar`: `BitMatch-iPad/Views/ModularContentView.swift`. The mode switcher is `AdaptiveModeNavigation` (`BitMatch-iPad/Views/HeaderTabsView.swift`).
- **Modes.** Both layouts switch on `coordinator.currentMode` (`AppMode`: Copy & Verify, Check, Master Report). Copy & Verify always shows `CopyAndVerifyView`; its shared `TransferQueueSection` sits directly below the setup locations while transfers wait, run and finish. Compare shows its own progress and outcome inside `CompareScreen`.
- **Settings.** `SettingsSheetView` in `ModularContentView.swift`: report and camera settings, the project's remote destination (kept for the Mac to upload), and screen dimming.

### macOS

- **Entry point.** `BitMatch/App/BitMatchApp.swift` shows `BitMatch/App/ContentView.swift`. Menu commands are posted as `NotificationCenter` events and handled in `ContentView`: Settings (⌘,), View → the three modes (⌘1–3), and File → Start (⌘R) and Cancel (⌘., disabled while nothing runs).
- **Coordinator.** As on iPhone and iPad, the Mac views bind to `SharedAppCoordinator` directly; it is the only state owner. `ContentView` holds a `MacAppEnvironment` (`BitMatch/App/MacAppEnvironment.swift`) as its one `@StateObject` and renders `MacMainView`. `MacAppEnvironment.make()` builds the Core Data–backed `PhotographerJobViewModel`, a `SharedAppCoordinator` on `MacOSPlatformManager.shared` that uses it, and the Mac companions below. Start and ⌘R call `startCurrentMode()`, the same entry point on every platform.
- **Routing.** `MacMainView.mainContentSwitch` always shows the selected mode. In Copy & Verify, `MacSetupView` keeps Setup visible and places `MacQueueSection` below it; running and finished transfers stay in expandable rows.
- **Mac-only companions.** Each reads from and writes to the shared coordinator and keeps no copy of its state:
  - `MacRemoteBackupController` (`BitMatch/Core/Services/`): the SFTP remote-backup queue, scheduler and host-key prompt (the thesis's named Mac exception).
  - `MacVolumeAccessModel` (`BitMatch/Core/ViewModels/`): volume monitoring, backup-drive discovery, `/Volumes` bookmarks, and last-used backups. At launch it restores last-used backups only when every one of them can be restored (`LastBackupsRestorePolicy`, `Shared/Core/Models/SetupPresentation.swift`).
  - `MacCameraAutoSourceController` (`BitMatch/Core/Services/`): choosing a detected camera card as the source when Preferences allow it.

  `MacRemoteBackupController` and `MacVolumeAccessModel` reach views as environment objects (`macCompanions(_:)`); the Preferences window (`BitMatch/Views/PreferencesWindow.swift`) receives its companions explicitly.
- **Debug builds.** A Developer menu (DEBUG only, `BitMatchApp.swift`) opens the Interface Lab (`BitMatch/Views/InterfaceLab/`, a separate app instance started with `--interface-lab`), toggles Dev Mode, and, with Dev Mode on, fills test data, runs small/medium/large stress tests, toggles verbose logs, and resets the last operation (Clear All Data). `DevModeManager` (`BitMatch/Core/Services/DevModeManager.swift`) implements them.

## Operation state

State is stored once. `OperationStateService.currentState` (`Shared/Core/Services/OperationStateService.swift`) is the only stored `OperationState` (`Shared/Core/Models/OperationModels.swift`). `SharedAppCoordinator.operationState` is a computed property over it: reading returns `stateService.currentState`, and writing calls `stateService.adopt(_:)`, which records the state as reported and logs, rather than rejects, a transition that `OperationStateMachine` does not list. The service's own lifecycle calls (start, pause, resume, complete, fail, cancel) go through `OperationStateMachine.transition(to:)`, which can reject them. The coordinator forwards the service's `objectWillChange`, so views observing the coordinator see every change. `pauseOperation()` and `resumeOperation()` pause or resume the engine first, then update the service.

The verdict is derived from results. Each file result's `outcome` (`FileOperationResult`, `Packages/BitMatchEngine/Sources/BitMatchEngine/EngineProtocols.swift`) is a `ResultOutcome` (`Shared/Core/Models/TransferModels.swift`): `verified`, `copiedUnverified`, `checksumMismatch` or `failed`. The engine writes `ResultOutcome.statusText` into `ResultRow.status`, and `ResultRow.isSuccessStatus` reads it back through `ResultOutcome(statusText:)`. Text that is none of the four (older saved history) falls back to a fail-safe rule: it must contain "✅" and no failure marker. `copiedUnverified` counts as a success but never as verified.

## Choosing the source and backups

Three shared rules decide what may be chosen and when Start is allowed, on every platform.

- **`DestinationSelectionPolicy`** (`Packages/BitMatchEngine/Sources/BitMatchEngine/DestinationSelectionPolicy.swift`) runs the moment the user picks or drops a location. A backup must be a folder, not already chosen, not the source or inside or around it, and allowed by `BackupTargetPolicy`. The source must be a folder that does not overlap a chosen backup. The macOS system-folder check applies on the Mac only. `CoordinatorSetupLocations` runs it, then the platform's add, and shows any refusal (the Mac drop toast, an iOS alert).
- **`BackupTargetPolicy`** (`Packages/BitMatchEngine/Sources/BitMatchEngine/File/BackupTargetPolicy.swift`) is the one rule for what may become a backup, keyed by who is adding it (`Origin`: `userChoice`, `restored`, `discovered`). It guards every add path: `SharedAppCoordinator.addDestination` and `replaceDestinations`, Mac drive discovery and the launch restore in `MacVolumeAccessModel`, queue replay, the readiness check, and the engine's own preflight (`SafetyValidator`).
  - Always refused: the startup disk root, anything under `/System`, the root of an internal volume with a system name (Recovery, "Recovery 2", Preboot, any letter case), the source's own volume root, and any folder on a removable source volume. When volume facts cannot be read, a target that looks to be on the source's volume is refused (fail closed).
  - A folder the user picks on the startup disk is allowed.
  - Launch restore also refuses temp folders and internal volume roots, but restores a network share's root. Discovery adds only whole external or removable volumes, never a system-named one or a network share.
  - `BackupTargetPolicyTests` and `BackupTargetPolicyRealVolumeTests` cover it.
- **`TransferReadiness`** (`Packages/BitMatchEngine/Sources/BitMatchEngine/TransferReadiness.swift`) says whether a copy may start and why not. It is pure: free space and writability are injected. `SharedAppCoordinator.transferReadiness` builds it from the selection, and `operationReadinessAssessment` is a view of it, used by `canStartOperation` (and so `startCurrentMode()`), `startProjectOperation()` and the Setup screen. A missing source or backup is a next step, not a blocker. Duplicate, protected, overlapping, unwritable or too-small backups block. A backup needs more than the source size plus `SafetyValidator.requiredHeadroomBytes` (1 GB) free, the margin the copy's own preflight uses.

With Project chosen on Setup (`SharedAppCoordinator.usesProjectWorkflow`), `startCurrentMode()` starts nothing until a project card is prepared.

`SafetyValidator.isProtectedSystemPath` (`Packages/BitMatchEngine/Sources/BitMatchEngine/File/SafetyValidator.swift`) refuses `/System`, `/Library`, `/usr`, `/bin`, `/sbin`, `/private`, `/var` and `/etc`, except the temp folder and, on iOS, `/var/mobile` and `/private/var/mobile`, where every Files-picker location lives.

## Live progress and results

Progress ticks and per-file rows are observed apart from the coordinator, so they never redraw a whole shell.

- **`LiveProgressFeed`** (`Shared/Core/ViewModels/LiveProgressFeed.swift`) holds the engine's latest `OperationProgress`. `SharedAppCoordinator.progress` reads and writes it and is not `@Published`. `TransferQueueSection` and the platform Compare views observe it; both Compare views build state through the shared `ComparePresentation.make(coordinator:)` adapter.
- **`LiveResultsFeed`** (`Shared/Core/ViewModels/LiveResultsFeed.swift`) holds the run's `ResultRow`s, one per file and backup. `SharedAppCoordinator.results` reads and writes it; a whole-list write (clear, or the engine's authoritative list) also announces itself on the coordinator. A live row arrives through `receiveLiveResult(_:)`, which updates only the feed. Finished queue rows, the journal and export read the same recorded rows.
- **`ProgressPresentationModel`** (`Shared/Core/ViewModels/ProgressPresentationModel.swift`) smooths progress for display. `SharedAppCoordinator.setupProgressPresentation()` feeds it at most every 120 ms and starts, pauses, resumes and stops its tracking from the operation state. Speed is an EMA over active time; paused time is left out.
- **Time left** comes only from observed copy speed: the copy bytes still to go (scanned source size times the number of backups, minus bytes copied) over the rate measured across a 10-second rolling window of active copying. Until two seconds of copying have been measured it reads "Estimating…" (`TransferProgressPresentation.estimatingTimeLeft`). With the planned work unknown or already copied, it shows nothing. There is no drive benchmark and no estimate before a transfer starts.

## Copy → verify pipeline

The copy and verify path is the same on every platform:

```
SharedAppCoordinator.startCurrentMode()  // Start and ⌘R on every platform; checks TransferReadiness
  → startOperation() / startProjectOperation()
  → CopyVerifyExecutor.execute(config:callbacks:)
    → platformManager.fileOperations.performFileOperation(...)   // TransferPipeline on both platforms
      → CardSource.enumerateRegularFiles                   // source manifest
      → SafetyValidator                                            // preflight
      → DestinationWriter.copyAllSafely                              // per destination
      → DestinationWriter.verifyPinnedDestinationFile                // per file, pipelined or sequential
    → ASCMHLGenerator.generateInitialHistory                       // optional, per destination
    → ReportExporter.export                                        // optional
```

### 1. SharedAppCoordinator (`Shared/Core/Services/SharedAppCoordinator.swift`)

`executeOperation(journalRecordID:)` runs these steps in order:

1. Requires a source and at least one destination.
2. Acquires platform access scopes for every selected URL.
3. Records the transfer in `LocalTransferJournal` (`enqueue`, then `markRunning`) before any copying. If this fails, the transfer does not start.
4. Runs `SafetyValidator.validateResolvedDestinationRoots`.
5. Builds a `CopyVerifyConfig` and calls the executor.
6. Afterwards, records the outcome in the journal with `finish`, `interrupt`, or `cancel`.

The executor's `onResult` callback streams live rows into `liveResults` through `receiveLiveResult(_:)`; `onAuthoritativeResults` then replaces them with the final list through `results`. `onStateChange` sets `operationState`.

### 2. CopyVerifyExecutor (`Shared/Core/Services/CopyVerifyExecutor.swift`)

`@MainActor`. It starts the services that run alongside the copy:

- `IOSBackgroundTaskService`: background task, idle timer, and Live Activity on iOS; a no-op stub on macOS
- `TransferKeepAwake` over `ProcessInfoSleepPreventer` (`Shared/Core/Services/TransferSleepPreventer.swift`): keeps the Mac from idle-sleeping until the operation ends
- `OperationTimingService`
- `ErrorReportingService`
- `OperationStateService`
- `ResultsOverflowService`: spills result rows to disk past 5,000 in memory and coalesces them to the latest row per file and destination

It then calls `performFileOperation`. On return, it:

1. Maps `FileOperation.results` into the authoritative `ResultRow` list.
2. Runs the optional photographer finalizer.
3. Writes ASC MHL histories, if enabled.
4. Exports the report, if enabled.

The completion is marked successful only if all of these hold:

- There is at least one result, and every row is a success status (`ResultRow.isSuccessStatus`, read through `ResultOutcome`).
- Photographer finalization, if configured, persisted and certified the card as locally safe.
- No ASC MHL handoff issue occurred.
- The verification mode is not Quick.
- A requested report exported without error.

Any failure is appended to the completion message.

### 3. TransferPipeline (`Packages/BitMatchEngine/Sources/BitMatchEngine/TransferPipeline.swift`)

This is the only `FileOperationsService` implementation. Both platform managers create one around their `FileSystemService` and `ChecksumEngine.shared`. Only one operation can run at a time.

For each operation, in order:

1. **Access.** Starts access scopes, then checks `validateFileAccess` on the source and each destination.
2. **Manifest.** `CardSource.enumerateRegularFiles` (`Packages/BitMatchEngine/Sources/BitMatchEngine/File/CardSource.swift`) walks the source once:
   - Hidden files are included; symlinks and non-regular files are skipped.
   - Volume metadata folders at the root are skipped: `.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems`, and `.DocumentRevisions-V100`.
   - Any traversal error fails the operation.
3. **Preflight.** Runs `SafetyValidator` (`Packages/BitMatchEngine/Sources/BitMatchEngine/File/SafetyValidator.swift`):
   - `validateResolvedDestinationRoots`: final output roots (destination plus the camera-label or recipe subfolders) must be unique, must not overlap the source, must not be nested in each other, and must not be a file or a symlink.
   - `performSafetyChecks`: the source exists and is a folder; the source tree has no unsafe relative paths and no names that collide under case-insensitive or Unicode-normalized comparison; each destination is unique, allowed by `BackupTargetPolicy`, not a protected system path, writable and free of symlinks; and each has more free space than the manifest size plus `requiredHeadroomBytes` (1 GB, the margin `TransferReadiness` uses).
   - A second free-space check, against the planned byte total, requires the size plus 100 MB.
4. **Per destination, in order:**
   - **Pin the root.** `PinnedDestinationDirectory.open` pins the output root by file descriptor, walking each component with `O_NOFOLLOW`. A safety-policy error aborts the whole operation. Any other error (for example, a disconnected drive) records every planned file as failed for that destination, and the operation moves on to the next destination.
   - **Copy.** `DestinationWriter.copyAllSafely` copies using a worker count of `min(4, max(1, cores/2))`.
   - **Verify.** Unless the mode is Quick, verification is pipelined by default: each copied file queues a verify task. The concurrency limit is `max(2, cores/2)`, and at most 200 tasks can be queued. Setting the `DisablePipelinedVerify` user default switches to one sequential pass per destination instead.
5. **Results.** `ResultStore` keeps one current `FileOperationResult` per source/destination pair. The final `FileOperation` carries these results.

`pauseOperation()` / `resumeOperation()` toggle a flag that is checked between file chunks and between files. `cancelOperation()` cancels the running task.

### 4. DestinationWriter (`Packages/BitMatchEngine/Sources/BitMatchEngine/File/DestinationWriter.swift`)

- **Writes.** Every destination write happens relative to the pinned directory descriptor, never through a path that is resolved again. Each file:
  1. Is written to `.bitmatch.tmp.<UUID>`, created with `O_EXCL | O_NOFOLLOW`, in 4 MB chunks.
  2. Is synced to disk, and its size is checked against the source.
  3. Is checked for a source change during the copy (size, modification date, file identity).
  4. Gets the source modification date.
  5. Is published without replacing anything (`PinnedDestinationDirectory.publishTemporaryFile`): `linkat` to the final name, then the temp file is removed. On exFAT and FAT, which have no hard links (`linkat` fails with `ENOTSUP`/`EOPNOTSUPP`), `publishByClaimingName` instead claims the final name with an exclusive create, checks the claim is still the empty file it made, and renames the verified temp file over it. Any other failure, including an existing file, fails the file. `ExFATDestinationTests` covers this.
- **Existing destination files.** An existing file is reused only if it matches the source size and every check for the verification mode (in Paranoid, the byte-by-byte comparison as well as SHA-256). Otherwise the file fails with a conflict and is never overwritten. In Quick mode, any existing file is a conflict.
- **Verification.** `verifyPinnedDestinationFile` reads the destination through the pinned descriptor. The source is hashed through the injected `ChecksumService` with `useCache: false`. The algorithms come from `VerificationMode.checksumTypes` (`Shared/Core/Models/SharedModels.swift`):

  | Mode | Verification | Existing-file reuse check |
  |---|---|---|
  | Quick | none (size only at copy time) | always a conflict |
  | Standard | SHA-256 | SHA-256 |
  | Thorough | SHA-256 + MD5 | SHA-256 + MD5 |
  | Paranoid | byte-by-byte comparison, plus SHA-256 (recorded for ASC MHL) | byte-by-byte comparison + SHA-256 |

### Checksums

- **`ChecksumEngine`** (`Packages/BitMatchEngine/Sources/BitMatchEngine/ChecksumEngine.swift`) does chunked MD5 (CryptoKit `Insecure.MD5`), SHA-1, and SHA-256, plus byte comparison.
- **`SharedChecksumCache`** (`Shared/Core/Services/ChecksumCache.swift`) is an actor-backed cache stored at `Caches/com.bitmatch.app/checksum_cache.json`. Entries last 1 hour, the cache holds at most 50,000 entries, and each key includes path, algorithm, size, modification time, and inode. The copy/verify path and Compare both bypass it (`useCache: false`).

## Compare

The public mode is **Check**; many source types retain their Compare names. It offers **Its saved checksums** and **Another folder**. `SavedChecksumCheck` discovers supported saved records, selects evidence per file and re-reads the selected folder. Contributing records are deduplicated by record URL, since one report or MHL can contain many files. The folder-to-folder path follows below. Both paths emit privacy-safe phase, count and terminal diagnostics correlated by run ID; exported differences can contain paths.

- **Entry point.** `SharedAppCoordinator.compareFolders()` calls `ComparisonCoordinator.compareFolders(left:right:verificationMode:onProgress:)` (`Shared/Core/Services/ComparisonCoordinator.swift`).
- **Callers.**
  - On Mac, `BitMatch/Views/CompareFoldersView.swift` starts it through `SharedAppCoordinator.startCurrentMode()`.
  - On iPhone and iPad, the `CompareFoldersView` adapter in `BitMatch-iPad/Views/ModularContentView.swift` (used by both layouts) calls `compareFolders()` directly.
- **Enumeration.** Both sides go through `FileSystemService.getFileList`, which is `CardSource.enumerateRegularFiles` on both platforms. It uses the same hidden-file, symlink, and volume-metadata rules as the copy manifest. Files are matched by relative path.
- **Ignored files.**
  - `isFinderMetadata` ignores `.DS_Store`, `Icon\r`, and `._*` on both sides.
  - `isOffloadManifest` ignores a top-level `ascmhl/` folder and root-level `*.mhl` / `*.mhl.md5` files, but only when they appear on the destination side alone.
- **Comparison of common files.**
  1. Sizes are compared first; a size difference is a mismatch.
  2. If sizes are equal, content is checked according to the mode:
     - Quick: size only
     - Standard: SHA-256
     - Thorough: SHA-256 + MD5
     - Paranoid: byte-by-byte comparison plus SHA-256
  - The checks per mode are `CompareCheckPlan` (`Shared/Core/Models/ComparePresentation.swift`), which both `ComparisonCoordinator` and the screen's wording read. Files are processed one at a time, with `useCache: false`.
- **Result.** `CompareStats` (in the engine, `Models/CompareStats.swift`) holds counts and sorted path lists: only in source, only in destination, and mismatched. `isClean` is true only when all three are empty. The result is thrown away if the folders or mode change while the compare is running.
- **Display.** Both apps show the result in `Shared/Views/CompareResultsView.swift`. It lists up to 200 paths per group and exports JSON or CSV through `CompareReportDocument`.

## ASC MHL

`ASCMHLGenerator` (`Packages/BitMatchEngine/Sources/BitMatchEngine/ASCMHLGenerator.swift`) writes a first-generation ASC MHL v2.0 history into each destination's resolved output root.

- **When it runs.** Only from `CopyVerifyExecutor`, after results are authoritative and before the report. All of these must hold:
  - `generateASCMHL` is on. It is a `SharedAppCoordinator` property stored in the `BitMatchGenerateASCMHL` user default, on by default.
  - The mode is not Quick.
  - Every source file has a successful, valid SHA-256-verified row for that destination.

  If a destination fails these checks, it gets no history, and the transfer completes with issues.
- **Checks before writing.**
  - Refuses to extend or replace an existing history: an `ascmhl` folder in, above, or below the root is an error.
  - Rejects unsafe or duplicate paths and symlinks.
  - Opens each file through a pinned descriptor with `O_NOFOLLOW`. It reuses verified SHA-256/MD5 readback evidence only on a filesystem with a real change time and matching descriptor identity, size and timestamps; otherwise it re-reads and requires SHA-256 to match the transfer. exFAT takes the re-read path. Progress includes this handoff work.
  - Refuses to write if the source and destination overlap.
- **Output.**
  - `ascmhl/0001_BitMatch_<UTC timestamp>Z.mhl`, with one MD5 hash per file.
  - `ascmhl/ascmhl_chain.xml`, which references the manifest by its C4 ID.

  Both files are written into a hidden staging folder, then published together with `renameatx_np(..., RENAME_EXCL)`. On unsupported filesystems such as exFAT, the fallback exclusively creates an empty `ascmhl` directory, checks its identity, and renames the staged directory over that claim. It cannot replace a nonempty history. An interruption can leave an empty reservation; retry refuses it rather than treating it as a complete history. Publication diagnostics record errno without paths.
- **Reference check.**
  - `Scripts/ascmhl/validate_reference.sh` builds a fixture with `Scripts/ascmhl/GenerateFixture.swift`.
  - It then validates the output against the official ascmitc/mhl XSDs and CLI, confirms that CLI can append a second generation, and confirms that a corrupted file fails verification.

## Reports

- **`ReportExporter.export`** (`Shared/Core/Services/ReportExporter.swift`): the per-transfer report. `CopyVerifyExecutor` calls it when `ReportPrefs.makeReport` is on.
  - Location: `<first destination>/Reports/` for Copy & Verify.
  - Always written: CSV and JSON.
  - Written when the full report is on: a checksum `.txt` list, and a PDF rendered from `Shared/Views/ReportView.swift` through `Shared/Views/ReportPDFRenderer.swift` (SwiftUI `ImageRenderer` into a PDF `CGContext`) on every platform.
- **`SharedReportGenerationService`** (`Shared/Core/Services/SharedReportGenerationService.swift`): the Master Report PDF and JSON, built from scanned transfer reports.
  - Screen: `Shared/Views/MasterReport/MasterReportScreen.swift` over `MasterReportModel` and `MasterReportPresentation` (`Shared/Core/Models/`): choose a drive or folder and a day (today by default), include transfers grouped by camera, then save or share.
  - Scanning: `Shared/Core/Services/ReportScanner.swift` on every platform (filenames, size limit, day, and what "verified" means). Each platform picks the folder its own way: an open panel on the Mac, the Files document picker (`IOSDriverScanner.chooseFolder`) on iOS. `scanReports` also returns the reports it skipped (too large or unreadable), which `SkippedReportsNotice` (`Shared/Views/`) names on every platform; a long list scrolls.
  - Saving: through a save panel on Mac (PDF plus a sibling JSON), or shared from a temporary folder on iOS. Success shows only after the write or share finished.
- **Other exports.** Transfers (history) and the outcome screen's Export, on every platform, write JSON or CSV through `TransferHistoryDocument` (`Shared/Core/Services/TransferHistoryDocument.swift`).

## Transfer journal and queue

`LocalTransferJournal` (`Packages/BitMatchEngine/Sources/BitMatchEngine/TransferJournal.swift`) is the durable transfer record on every platform.

- **Storage.**
  - A JSON array of `LocalTransferRecord` at `Application Support/BitMatch/transfer-history.json`.
  - Every change is written atomically before it is published.
  - An exclusive `flock` on `transfer-history.json.lock` prevents a second app instance from opening the journal.
- **Records.** Each record stores:
  - Source and destinations as `LocalTransferResource`: URL, bookmark, volume UUID, and resource ID
  - Verification mode, camera and report settings, the ASC MHL flag, and an optional project ID
  - State: `queued`, `running`, `interrupted`, `completed`, `issues`, or `cancelled`
  - The final `ResultRow`s
- **Outcomes.** `finish` records `issues` rather than `completed` for Quick mode, for an empty result list, or when any row is not a success.
- **Recovery.**
  - On load, any record still `running` becomes `interrupted`.
  - `requeue` creates a new record for a retry and keeps the old one.
  - `prepareToRun` resolves bookmarks and requires the same volume and resource identity as the original.
  - `reauthorize` lets the user reconnect a location, and rejects a different volume or folder.
- **The queue.** The journal also backs the local queue, driven by `SharedAppCoordinator`:
  - `startQueue()` / `stopQueueAfterCurrentTransfer()` start and stop it.
  - `processNextQueuedTransfer()` takes the oldest `queued` record with no project ID, loads its settings, and runs it through the same `executeOperation` path.
  - The queue stops when a transfer does not complete cleanly, and on cancel.
  - On iOS it runs only while the app is in the foreground; otherwise it pauses with a message.
- **UI.** Both apps show `Shared/Views/TransferLibraryView.swift` for queue, history, retry, reconnect, and export. Both shells show an interrupted-transfer banner.

### Remote backup queue (Mac only)

- **Components.** `RemoteBackupQueue`, `RemoteBackupCoordinator`, and `RemoteBackupProvider` are in `Shared/Core/Services/` but compile only on macOS. The SFTP implementation is `BitMatch/Core/Services/SFTPRemoteBackupProvider.swift`, which runs the system `ssh`, `sftp`, `ssh-keyscan`, and `ssh-keygen`. Credentials are stored in the Keychain (`BitMatch/Utilities/KeychainHelper.swift`).
- **Queue behavior.** Queue items and manifests persist through the photographer job store. The queue retries network errors with backoff, and never replaces an existing remote file.
- **Wiring.** `MacRemoteBackupController.makeDefault` builds and schedules the queue; `MacAppEnvironment.make()` calls it.
- **On iOS.** `SharedAppCoordinator` always uses `UnavailableRemoteProjectCoordinator` (`Shared/Core/Services/ProjectRemoteCoordinator.swift`), which records the destination choice and throws `remoteUploadsRequireMac`.

### Photographer job stores

- **Protocol.** `PhotographerJobStore` is defined in `Shared/Core/Services/ProjectStoreProtocol.swift`.
- **iOS store.** iOS uses `UserDefaultsPhotographerJobStore` (`Shared/Core/Services/UserDefaultsPhotographerJobStore.swift`), which is the `SharedAppCoordinator` default.
- **Mac store.** The Mac uses `CoreDataPhotographerJobStore` (`BitMatch/Core/Services/Photographer/PhotographerJobStore.swift`) on `BitMatchPersistenceController` (model `BitMatch/BitMatch.xcdatamodeld`). `MacAppEnvironment.make()` passes its job view model into `SharedAppCoordinator`, so the Mac has one.

## Platform managers

`PlatformManager` (`Packages/BitMatchEngine/Sources/BitMatchEngine/EngineProtocols.swift`) is the only platform seam the engine sees. It exposes:

- `fileSystem: FileSystemService`
- `checksum: ChecksumService`
- `fileOperations: FileOperationsService`
- `cameraDetection: CameraDetectionService`
- `supportsDragAndDrop`
- `presentAlert`, `presentError`, and `openURL`

| | `MacOSPlatformManager` (`Platforms/macOS/Services/`) | `IOSPlatformManager` (`Platforms/iOS/Services/`) |
|---|---|---|
| File system | `MacOSFileSystemService` (`BitMatch/Core/Services/Platform/`): `NSOpenPanel` pickers. `startAccessing` returns `true`, and `stopAccessing` does nothing. | `IOSFileSystemService`: `UIDocumentPickerViewController` folder picker (the delegate is retained). Uses security-scoped access at folder level, with per-file scopes for size and directory creation. |
| Checksum | `ChecksumEngine.shared` | `ChecksumEngine.shared` |
| File operations | `TransferPipeline` | `TransferPipeline` |
| Camera detection | `SharedCameraDetectionService` | `SharedCameraDetectionService` |
| Alerts | `NSAlert` (skipped under XCTest) | `UIAlertController` |
| Drag and drop | yes | no |

Both file system services list files through `CardSource`.

### Camera detection

- **One set of layout rules.** `CardLayoutClassifier` (`Shared/Core/Services/Camera/`) decides a card's brand from a bounded listing of its folder tree, brand-unique markers first. `CameraStructureDetector` (Mac auto-detect), the orchestrator and its folder-structure stage all use it, so they name the same brand.
- **Detection chain.** `SharedCameraDetectionService` first asks `CameraDetectionOrchestrator`. When the layout names a brand, the orchestrator only adds a model name, from that brand's reader (MEDIAPRO.XML, RAF header, ALE) or from Spotlight when it agrees with the brand. Otherwise it tries the remaining heuristic detectors in order and stops at the first match. A brand from the orchestrator is not overridden by the service's own folder-name and file-extension guesses. The card name used as the default destination folder follows one rule on every platform: a known model uses `CleanCameraNameService` on "brand model" (the Mac label, e.g. A7SIII), and a brand alone keeps the long-standing folder names (GOPRO, not that cleaner's GP). `CameraFolderNameTests` pins both.
- **Callers.** `SharedAppCoordinator` calls it when a source is chosen. Its `CameraLabelModel` suggests the label with `CameraNamingService` and remembers it per card with `CameraMemoryService`, on every platform.
- **Mac-only callers.** `CameraStructureDetector` is in `Shared/`, but only the Mac's `CameraCardDetectionService` calls it.

### Other Mac-only services (`BitMatch/Core/Services/`)

- `VolumeMonitorService` and `CameraCardDetectionService`: volume mount monitoring and card detection
- `UnreadableMediaMonitor`: watches Disk Arbitration for removable disks that appear with no file system macOS can read, and builds an `UnreadableMediaNotice` (Sony SxS cards: Sony's SxS UDF Driver; Sony AXS cards: Sony's AXS reader software; anything else: a generic notice). The Mac Setup screen shows it through `UnreadableMediaBanner` (`BitMatch/Views/CopyAndVerify/`). iOS has no equivalent: the Files app shows only what it can read.
- `DevModeManager`: the DEBUG tools behind the Developer menu
- `ErrorHandling/GlobalErrorHandler`
- `Logging/AppLogger`: forwards to `SharedLogger`

## Tests

The `BitMatchTests` unit tests run on macOS against the shared engine through `@testable import BitMatch`. One fake, `BitMatchTests/TestHelpers/FakeFileSystemService.swift`, stands in for `FileSystemService`; `TestHelpers/` also holds disposable real-folder fixtures and camera card layouts.

| Area | Test files |
|---|---|
| Pipeline | `SharedFileOperations*Tests`, `CopyVerifyExecutorIntegrityTests`, `SafetyValidatorTests`, `SourceTreeUnchangedTests`, `ExFATDestinationTests`, `ExistingDestinationReuseTests` |
| Operation state and verdict | `OperationStateSingleSourceTests`, `OperationStateMachineTests`, `ResultOutcomeTests`, `ResultStatusClassificationTests` |
| Choosing locations and readiness | `BackupTargetPolicyTests`, `BackupTargetPolicyRealVolumeTests`, `DestinationSelectionPolicyTests`, `TransferReadinessTests`, `ReadinessRuleTests` |
| Screen presentations | `SetupPresentationTests`, `SetupLocationsPresentationTests`, `TransferProgressPresentationTests`, `TransferOutcomePresentationTests`, `ComparePresentationTests`, `MasterReportModelTests`, `TransferLibraryPresentationTests` |
| Live progress and results | `ProgressPresentationFeedTests`, `LiveResultsFeedTests` |
| Mac shell | `MacAppEnvironmentTests`, `SharedCoordinatorMacParityTests`, `MacCameraAutoSourceTests`, `UnreadableMediaMonitorTests`, `UnreadableMediaNoticeTests` |
| Camera detection | `CameraCardLayoutDetectionTests`, `CameraDetectionServiceTests`, `CameraFolderNameTests` |
| Journal and queue | `LocalTransferJournalTests`, `LocalTransferQueueIntegrationTests` |
| Compare | `SharedCompareFlowTests`, `CompareIgnoredFilesTests` |
| ASC MHL | `ASCMHLGeneratorTests` |
| Verdict parity across platforms | `PlatformVerdictParityTests` |
| Fault injection and soak | `TransferFaultIntegrationTests`, `TransferSoakTests` |

- **Scripted harnesses.** `Scripts/run_apfs_fault_tests.sh` and `Scripts/run_soak_tests.sh` drive the fault and soak tests. `docs/HARDWARE_TESTING.md` covers physical-device fault testing.
- **iOS tests.** `BitMatch-iPadTests` holds a small iOS suite: the iOS storage-path rule (`IOSStoragePathTests`), and the iOS side of the progress, outcome and options presentations.
- **Workflow snapshots.** `WorkflowSnapshotTests` (both test targets) render the production `ContentView` at phone, iPad and Mac sizes with seeded data. They are skipped unless `BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS=1` is set.
