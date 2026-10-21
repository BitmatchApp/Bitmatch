# Bounded Mac volume discovery — October 20, 2026

Mount enumeration, per-mount identity reads, classification and final live identity checks now run outside the main actor through a scheduler capped at two active probes and eight waiting probes. Snapshot requests coalesce in a reserved queue slot. Requests for one lexical mount share a serial group, so repeated checks of a stuck drive cannot consume both workers; another mount can bypass its waiting probes. Selected-source folders under the same `/Volumes/<mount>` use that group without resolving their paths on the main actor.

A blocked synchronous filesystem call keeps its worker until the operating system returns. Superseding a request retires its waiting continuation or queued work, not the kernel call. Generation, published mount and live identity checks reject late or replaced results. Pending initial source identity retains the visible selection but blocks automatic actions. A completed unavailable identity clears a previously baselined source. The device number is only a discovery fallback when a UUID is unavailable; it does not authorize a transfer by itself.

## Local evidence

The final focused `VolumeMonitorReconciliationTests` run passed **22 Swift Testing tests in one suite**, zero failures, in 0.729 seconds. It covered repeated rescans, bounded waiting work, a held mount snapshot with a healthy direct mount event, held identity reads, late replacement results, alias mapping, stale live validation, initial identity failure, known-source disappearance, rapid reselection and same-mount serialization with healthy-mount bypass.

Two deliberate production regressions were observed:

- Moving snapshot enumeration back onto the main actor failed the bounded responsiveness assertion in the earlier 20-test suite. An independent release watchdog prevented a permanent hang. The service was then restored byte-for-byte.
- Removing the scheduler's serial-group eligibility check failed `differentKeysInOneSerialGroupWaitWhileHealthyGroupBypasses` in the final 22-test suite. The service was restored byte-for-byte. The preceding final green run and this red run are retained separately.

The final combined Mac run passed 1,411 tests, skipped 34 and failed none (1,445 total), after both mutations were restored. The generic iPhone/iPad simulator build also succeeded for arm64 and x86_64. An earlier 1,404-pass/33-skip Mac result predates the serial-group follow-up and remains separate evidence. An independent read-only review of the final scheduler and source identity changes found no actionable issue. These are app-host and build gates; native/signed-app and physical card checks remain open.

Two initial compile failures in integration were corrected before these runs: optional Boolean continuation typing and an existing test that now needed to await asynchronous reconciliation. Source-model tests use dedicated monitors so separate latest-selection requests cannot supersede one another across tests.

## Remaining boundaries

Two genuinely blocked groups can occupy both workers. No timeout or cancellation claim implies an interrupted filesystem syscall, and per-call file-descriptor use has not been measured. Native Disk Arbitration/card removal, Dock behavior and signed-app interaction have not been observed for this patch. Shared automatic-enqueue safety/source-file preflight and the source setter's bookmark/identity work remain separate synchronous boundaries. The Mac auto-source readability call is addressed by the follow-up below. The broader blocked-drive TODO remains open; this change does not claim the whole discovery/preflight audit is complete.

## Auto-source readability follow-up

`MacCameraAutoSourceController` now runs `isReadableFile` through its own bounded scheduler: at most two active probes and a bounded coalesced queue, with one lexical mount serialized at a time. Repeated events replace queued checks. Running filesystem calls retain their slots until they return. A selected source, changed preferences, an active/terminal operation, a removed card or a new card identity at the same mount prevents an obsolete result from selecting a source. Source changes and detected-card removal retire pending work synchronously on the main actor. The separate source assignment/bookmark boundary remains open.

The scheduling group itself now uses pure lexical comparison rather than Foundation URL standardization. A test creates an owned symlink after taking the first group value and requires the group to remain stable. This is mount-path scheduling, not proof that every alias names an independent physical device.

A focused app-host run passed **39 tests, zero skips and zero failures**: 14 auto-source tests, 23 volume reconciliation tests and two History scratch-root tests. Auto-source controls include a healthy second mount while the first check is held, same-key coalescing, operator selection, changed preferences/terminal state, unmount and same-path remount. Probes use owned scratch folders or injected synthetic paths; no real removable card is touched by these tests. Initial test corrections replaced a scan with a mount event (only mount detection posts the notification), and compared canonical temporary-directory aliases rather than their spelling. An optional-return inference compile error was also corrected.

Two independent focused mutations then failed as intended: dispatching readability onto MainActor failed the direct main-thread assertion, and restoring URL standardization failed lexical group stability. Exactly two test functions ran, both failed, and both source files were restored byte-for-byte. The broader updated Mac run at `b30e844f` then passed 1,424 tests, skipped 34 and failed none (1,458 total). The updated iPhone/iPad simulator build also passed for arm64 and x86_64. Native card-event and signed-app walkthrough limits remain open.
