# Remote boundary inventory

Every `SharedAppCoordinator` member the Copy & Verify, Progress, Outcome, Transfers (History and queue) and transfer-related Settings screens observe or call, produced from:

```
grep -rhoE "coordinator\.[a-zA-Z_]+" Shared/Views BitMatch/Views BitMatch-iPad --include='*.swift' | sort | uniq -c | sort -rn
```

and checked per file. `RemoteSurface` (`Shared/Core/Remote/RemoteSurface.swift`) contains exactly the rows marked **yes**. Compare, Check and Master Report are local-only in this release; their members are **no**.

Wording used when not supported:

- "local-only" = Compare, Check or Master Report; shown as unavailable when remote.
- "local UI" = Mac/iPad presentation state of the screen itself; each device keeps its own.
- "derived" = computed from yes members or from the snapshot a later slice defines; not part of the protocol.
- "later slice" = needs its own remote design (pickers, notifications, import/export).

## Corrections to the brief's member list

All 18 read members and 19 intents exist on the coordinator under the brief's names. Signature corrections only:

- `pauseOperation` takes `reason: PauseInfo.PauseReason` (default `.userRequested`). A defaulted parameter does not satisfy a no-argument requirement, so the protocol declares `pauseOperation(reason:)`.
- `cancelOperation(ifCurrentTargetID:origin:)` has a defaulted parameter; the protocol declares it in full.
- `ejectQueueSource` returns `String?` and takes `using ejector:`.
- `ejectQueueSource` exists only on macOS (`#if os(macOS)`), so it sits inside the same conditional in the protocol.
- Added for the command executor (Task 6): `verificationMode` as `{ get set }`, and `ejectingQueueSourceIDs` (macOS), so a remote eject can tell "already unmounting" from success.
- Source and backup choice (final review): the protocol has the Setup screen's own prepared intents, `chooseSourcePrepared(_:worker:jobKey:)` and `addBackupsPrepared(_:worker:jobKey:)` (from `SetupLocationSelection`, `Shared/Views/Setup/CoordinatorSetupLocations.swift`; the coordinator forwards to them), and `selectionWorker`, the drive worker they run on. They apply the staged-card check, `DestinationSelectionPolicy.evaluateSource` / `evaluateBackup` off the main actor, the project lock and a compare-and-swap; a refusal they return becomes `hostRefused`. `applyPreparedSource` and `addDestination(_:origin:facts:)`, which Task 6 used, left the protocol: the first called alone skips those rules, the second reads volume facts on the main actor and skips `evaluateBackup`. Of the brief's 19 intents, 18 are in the protocol; `addDestination` is the exception.
- `setDestinations` compares the backups as a set: their order is not part of the remote contract.
- Added for the snapshot builder (Task 7): `transferReadiness` (read), so the snapshot's readiness wording comes from the shared `OperationReadinessAssessment` and the selection revision bumps when source preparation leaves `.analysing`; and `cancellationTargetID` (read, `activeStartID ?? stateService.currentOperationId`), the ID a remote `cancel` must carry. Both already exist on the coordinator under these names. Also `queueSessionRecordOrder` (read), the queue's run order, which the snapshot publishes and whose waiting cards `moveQueuedTransfer` indexes; the coordinator's stored property went from `private` to `private(set)` for it.
- `queueIsRunning`, `queueMessage`, `queueSessionRecordIDs`, `queuePausedRecordID` are `private(set)`; `transferJournal` and `generalSettings` are `let`. All are `{ get }`.
- `currentOperation` and `timingService` are not referenced as `coordinator.x` by any view; they are kept (brief) as the Progress state source.

## Observed state and intents

| Member | Screens | Kind | Remote-supported |
|---|---|---|---|
| reportSettings | Setup, Preferences, ModularContent, MasterReport | read | yes |
| destinationURLs | Setup (iPad, Mac), Queue | read | yes |
| isOperationInProgress | Setup, ActionBar, ModularContent, PhoneContent, Preferences, Progress adapters | read | yes |
| sourceURL | Setup, CopyAndVerify, ProjectSetupCard, Progress adapters | read | yes |
| currentMode | Content, Setup, HeaderTabs, ActionBar, ModularContent, PhoneContent | read | yes |
| verificationMode | Setup, Preferences, ModularContent, Queue, CompareFolders | read-write | yes (`{ get set }`: a remote `setVerificationMode` assigns it, then calls `saveVerificationMode()`) |
| photographerJobViewModel | Setup, CopyAndVerify, MacSetup, ModularContent, Preferences, ProjectSetupCard, RemoteBackupDestination | read | no (later slice: project workflow is edited on the Mac) |
| transferJournal | ModularContent, PhoneContent, TransferLibrary, Progress adapters, Queue | read | yes |
| queuePresentation | AdaptiveQueuePresentation, Content, Queue | read | no (derived from transferJournal and queue state) |
| usesProjectWorkflow | Setup | read | yes |
| cameraLabelSettings | Setup, CopyAndVerify, ModularContent, Preferences | read | no (later slice: label settings stay per device) |
| editingSetupTransferID | AdaptiveQueuePresentation, Setup, Queue | read | no (local UI: draft editing) |
| queueIsRunning | AdaptiveQueuePresentation, Setup, ModularContent, PhoneContent, Queue | read | yes |
| selectionWorker | Setup | read | yes (the drive worker the prepared source and backup intents run on; a remote `selectSource` or `setDestinations` passes it) |
| liveProgress | AdaptiveQueuePresentation, ActionBar, ModularContent, Progress adapters, Queue, CompareFolders | read | no (derived from stateService and timingService) |
| stagedSetupTransfers | Setup | read | no (local UI: draft staging) |
| sourceFolderInfo | Setup | read | no (derived from source analysis on the Mac) |
| showsOutcomeSummary | ModularContent, PhoneContent | read | no (derived from stateService) |
| operationState | ModularContent, Progress adapters | read | no (derived from stateService) |
| switchMode | Setup, HeaderTabs | intent | no (local UI: the iPad switches its own tab) |
| showError | Setup, ActionBar | intent | no (local UI) |
| rightURL | ModularContent, CompareFolders | read | no (local-only: Compare) |
| leftURL | ModularContent, CompareFolders | read | no (local-only: Compare) |
| isProjectRunInProgress | Setup, ProjectSetupCard | read | no (derived from usesProjectWorkflow and isOperationInProgress) |
| cancelOperation | CompareFolders, ActionBar, ModularContent, Queue | intent | yes (`cancelOperation(ifCurrentTargetID:origin:)`; the origin-only form and Compare's use are local-only) |
| cancellationTargetID | ActionBar | read | yes (published in the snapshot as the ID `cancel` carries) |
| cameraLabels | Setup, MacSetup, ProjectSetupCard | read | no (later slice) |
| removeQueuedTransfer | Setup, TransferLibrary, Queue | intent | yes |
| appleDoubleSelection | Setup, ModularContent, Preferences | read | no (later slice: setting stays per device) |
| transferNotifier | ModularContent, NotificationPermissionBanner, Preferences | read | no (later slice: notifications are per device) |
| resumeOperation | ActionBar, Queue | intent | yes |
| queuePausedRecordID | ModularContent, PhoneContent, Queue | read | yes |
| pauseOperation | ActionBar, Queue | intent | yes (`pauseOperation(reason:)`) |
| moveQueuedTransfer | Setup, Queue | intent | yes (`moveQueuedTransfer(id:to:)`) |
| isModeSwitchLocked | HeaderTabs | read | no (local UI) |
| generateASCMHL | Setup, ModularContent, Queue | read | yes |
| enqueueSelectionPrepared | Setup, ActionBar | intent | yes |
| enableNotificationsFromPrompt | ModularContent, NotificationPermissionBanner, Preferences | intent | no (later slice: notifications are per device) |
| destinationVolumeNames | Setup | read | no (derived from destinationURLs) |
| canImportTransferSettings | TransferSettings | read | no (later slice: import and export) |
| canEnqueueSelection | Setup | read | no (derived from readiness) |
| stateService | ActionBar, Queue | read | yes |
| startSetupTransfersPrepared | Setup, ActionBar | intent | yes |
| startQueue | Queue | intent | yes |
| skipPausedCardAndContinue | Queue | intent | yes |
| saveVerificationMode | ModularContent, Preferences | intent | yes |
| runningOneTimeTransfer | Queue | read | no (derived from queue state) |
| retryTransferPrepared | TransferLibrary, Queue | intent | yes |
| reauthorizationStatusPrepared | TransferLibrary | read | no (Mac-only: reauthorization needs the Mac's drives) |
| queueRunCommandEnabled | Queue | read | no (derived from queue state) |
| queueMessage | TransferLibrary, Progress adapters | read | yes |
| pickFolderForSource | CopyAndVerify | intent | no (local UI: the system picker runs on the device it opens on) |
| moveQueuedTransferToTop | TransferLibrary, Queue | intent | yes |
| lastCompareEnd | ModularContent, PhoneContent | read | no (local-only: Compare) |
| isReplayingQueuedTransfer | ModularContent, Preferences | read | no (derived from queue state) |
| isCommittingSelection | ActionBar | read | no (local UI) |
| generalSettings | ModularContent, Preferences | read | yes. Later slices must filter the snapshot: only `queueNewCardsAutomatically` and `autoEjectWhenSafe` are remote-editable; notification, sound and update settings stay Mac-local |
| isAnalysingSource | Setup | read | no (derived from source analysis) |
| errorCount | Progress adapters | read | no (derived from stateService) |
| editSetupTransferPrepared | Setup, Queue | intent | no (local UI: draft editing) |
| demoQueueAutoOpen | Content | read | no (local UI: demo) |
| clearFinishedQueueRows | Queue | intent | yes |
| checkAgainst | CompareFolders, ModularContent | intent | no (local-only: Compare and Check) |
| applyPreparedDestinations | Setup | intent | no (the compare-and-swap inside `addBackupsPrepared`, which is yes) |
| warningCount | Progress adapters | read | no (derived from stateService) |
| transferReadiness | Setup | read | yes (snapshot readiness wording and status; its change bumps the selection revision) |
| startSetupTransfers | Setup | intent | no (superseded by `startSetupTransfersPrepared`) |
| startCurrentMode | Setup | intent | no (local UI dispatcher over the intents above) |
| showsNotificationPermissionPrompt | NotificationPermissionBanner | read | no (later slice: per device) |
| showAlert | CopyAndVerify | intent | no (local UI) |
| selectRightFolder | ModularContent | intent | no (local-only: Compare) |
| selectLeftFolder | ModularContent | intent | no (local-only: Compare) |
| results | Progress adapters | read | no (derived from stateService) |
| removePausedCardFromQueue | Queue | intent | yes |
| removeFinishedQueueRow | Queue | intent | yes |
| removeDestinationFolder | CopyAndVerify | intent | yes |
| reauthorizeTransferPrepared | TransferLibrary | intent | no (Mac-only: reauthorization needs the Mac's drives) |
| queueSessionStarted | Queue | read | no (derived from queueSessionRecordIDs) |
| queueSessionRecordIDs | Queue | read | yes |
| progressPresentation | Progress adapters | read | no (derived) |
| progress | Progress adapters | read | no (derived from stateService) |
| presentedSourceURL | Progress adapters | read | no (derived from sourceURL) |
| presentedDestinationURLs | Progress adapters | read | no (derived from destinationURLs) |
| presentedDestinationNames | Progress adapters | read | no (derived from destinationURLs) |
| portableTransferSettingsForExport | TransferSettings | read | no (later slice: import and export) |
| pickFoldersForBackups | CopyAndVerify | intent | no (local UI: system picker) |
| pendingTransferSettingsImportWarning | TransferSettings | read | no (later slice) |
| outcomeRecord | Progress adapters | read | no (derived from transferJournal) |
| operationReadinessAssessment | Setup | read | no (derived) |
| operationDuration | Progress adapters | read | no (derived from timingService) |
| markQueueTransferReviewed | Queue | intent | yes |
| isInBackground | Progress adapters | read | no (local UI: the device's own lifecycle) |
| hasUnresolvedQueueRecords | Setup | read | no (derived from transferJournal) |
| hasErrors | Progress adapters | read | no (derived from stateService) |
| hasCriticalErrors | Progress adapters | read | no (derived from stateService) |
| enqueueSelection | Setup | intent | no (superseded by `enqueueSelectionPrepared`) |
| enqueueInlineCardPrepared | Queue | intent | no (later slice) |
| ejectQueueSource | MacQueue | intent | yes (macOS only) |
| ejectingQueueSourceIDs | MacQueue (through queuePresentation) | read | yes (macOS only: `ejectQueueSource` returns nil both on success and for a card already unmounting, so a remote eject reads this first) |
| detectedCamera | Setup (locations) | read | yes |
| destinationIndependence | Setup | read | no (derived) |
| destinationCapacity | Setup (locations) | read | no (derived) |
| declineNotificationsFromPrompt | NotificationPermissionBanner | intent | no (later slice: per device) |
| cancelSetupTransferEdit | Setup (locations) | intent | no (local UI: draft editing) |
| backgroundTimeRemainingSeconds | Progress adapters | read | no (local UI: the device's own lifecycle) |
| autoEjectWhenSafe | Queue | read | yes, via `generalSettings.autoEjectWhenSafe` (the coordinator property forwards to it; not a separate protocol member) |
| queueNewCardsAutomatically (auto-queue) | Queue, Preferences | read | yes, via `generalSettings.queueNewCardsAutomatically` |
| applyPreparedSource | Setup (locations) | intent | no (the compare-and-swap inside `chooseSourcePrepared`, which is yes; called alone it skips the Setup screen's rules) |
| alreadyBackedUpLine | Setup | read | no (derived) |
| addDestination | CopyAndVerify | intent | no (reads volume facts on the main actor and skips `evaluateBackup`; a remote `setDestinations` adds through `addBackupsPrepared`) |
| chooseSourcePrepared | Setup (locations, through `SetupLocationSelection`) | intent | yes (`chooseSourcePrepared(_:worker:jobKey:)`; a remote `selectSource`) |
| addBackupsPrepared | Setup (locations, through `SetupLocationSelection`) | intent | yes (`addBackupsPrepared(_:worker:jobKey:)`; the adds of a remote `setDestinations`) |

Members in the protocol but not seen in a view as `coordinator.x`: `currentOperation`, `timingService` (Progress state source, reached through the services). Both exist on the coordinator.
