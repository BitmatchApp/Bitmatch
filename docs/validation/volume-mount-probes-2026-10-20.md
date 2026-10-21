# Bounded Mac volume discovery — October 20, 2026

Mount enumeration, per-mount identity reads, classification and final live identity checks now run outside the main actor through a scheduler capped at two active probes and eight waiting probes. Snapshot requests coalesce in a reserved queue slot. Requests for one lexical mount share a serial group, so repeated checks of a stuck drive cannot consume both workers; another mount can bypass its waiting probes. Selected-source folders under the same `/Volumes/<mount>` use that group without resolving their paths on the main actor.

A blocked synchronous filesystem call keeps its worker until the operating system returns. Superseding a request retires its waiting continuation or queued work, not the kernel call. Generation, published mount and live identity checks reject late or replaced results. Pending initial source identity retains the visible selection but blocks automatic actions. A completed unavailable identity clears a previously baselined source. The device number is only a discovery fallback when a UUID is unavailable; it does not authorize a transfer by itself.

## Local evidence

The final focused `VolumeMonitorReconciliationTests` run passed **22 Swift Testing tests in one suite**, zero failures, in 0.729 seconds. It covered repeated rescans, bounded waiting work, a held mount snapshot with a healthy direct mount event, held identity reads, late replacement results, alias mapping, stale live validation, initial identity failure, known-source disappearance, rapid reselection and same-mount serialization with healthy-mount bypass.

Two deliberate production regressions were observed:

- Moving snapshot enumeration back onto the main actor failed the bounded responsiveness assertion in the earlier 20-test suite. An independent release watchdog prevented a permanent hang. The service was then restored byte-for-byte.
- Removing the scheduler's serial-group eligibility check failed `differentKeysInOneSerialGroupWaitWhileHealthyGroupBypasses` in the final 22-test suite. The service was restored byte-for-byte. The preceding final green run and this red run are retained separately.

An earlier combined Mac run passed 1,404 tests, skipped 33 and failed none. That run predates the serial-group follow-up; it is not the final full-suite gate for this patch. An independent read-only review of the final scheduler and source identity changes found no actionable issue. Final combined Mac/iOS gates remain pending at this record's revision.

Two initial compile failures in integration were corrected before these runs: optional Boolean continuation typing and an existing test that now needed to await asynchronous reconciliation. Source-model tests use dedicated monitors so separate latest-selection requests cannot supersede one another across tests.

## Remaining boundaries

Two genuinely blocked groups can occupy both workers. No timeout or cancellation claim implies an interrupted filesystem syscall, and per-call file-descriptor use has not been measured. Native Disk Arbitration/card removal, Dock behavior and signed-app interaction have not been observed for this patch. Shared automatic-enqueue safety/source-file preflight and the Mac auto-source readability check remain separate synchronous boundaries. The broader blocked-drive TODO remains open; this change does not claim the whole discovery/preflight audit is complete.
