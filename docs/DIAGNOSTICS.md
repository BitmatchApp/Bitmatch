# If a transfer or Check goes wrong

Keep the source card. Open **History → Export diagnostics…** and save the JSON file. If BitMatch closed, reopen it first. Attach the file to your [bug report](https://github.com/BitmatchApp/Bitmatch/issues), along with:

- The exact error or a screenshot, and whether you were using **Copy & Verify** or **Check**.
- Roughly when it happened, your app and OS versions, and the verification mode.
- The source and backup drives, their filesystems if you know them, and any card reader or dock in between.
- For a large transfer, the approximate total size, largest file size, and your Mac's memory capacity.

The export contains recent transfer and Check phases, numerical progress, filesystem types, error codes, cancellation origins, app/OS versions and random operation IDs. Events also include process memory use when available. It does **not** contain footage names, paths, production labels, bookmarks, checksums or the full transfer history. Nothing is uploaded automatically.

**Optional Apple crash and hang evidence:** In Settings → Diagnostics, **Save local crash and hang evidence** is off by default on Mac, iPhone and iPad. If you turn it on, BitMatch asks Apple's MetricKit for crash and main-thread hang reports and saves only a small summary when Apple delivers one. The diagnostics export can then include the report period, app version/build, numeric crash codes or hang duration, and up to eight attributed stack frames as binary UUIDs and offsets. It never includes Apple's raw payload, stack names, absolute addresses, exception messages or footage details. At most 16 summaries are retained locally. Turning the setting off or choosing **Clear saved crash evidence** deletes the local summaries and prevents delayed Apple callbacks from restoring them. If deletion fails, Settings warns you and collection stays off until removal succeeds. An export already being prepared or one you saved is a separate copy; delete that file yourself if you no longer want to keep it. BitMatch never uploads this evidence automatically.

Apple may deliver a report after a later app launch, or no report at all. This does not guarantee evidence for an out-of-memory termination, force quit, sudden power loss or a blocked background worker. The export does not claim that a MetricKit report belongs to a particular BitMatch transfer; compare its period and app version with the transfer events and any system report. An empty `systemEvidence` array is not evidence of a clean exit.

BitMatch keeps an opt-in/clear time in app preferences as well as the private evidence folder. It accepts a report only when its **entire reporting period begins after that time**. Apple's reports can cover a broad period, so the first ambiguous period after enabling or clearing may be skipped. If BitMatch cannot save the time or remove stale evidence, collection stays off rather than storing a report with uncertain consent.

If the device refuses **every** consent write and deletion at once, a later launch cannot prove that an earlier Clear happened. Settings warns about the failed deletion while the app is open. Retry after storage works, or remove the local `BitMatch/CrashEvidence` folder yourself. This is why a failed Clear is never reported as successful.

MetricKit delivery for BitMatch's Developer ID/notarized Mac distribution has not yet been demonstrated. A signed Mac pilot is required before treating this as a dependable field diagnostic. This feature does not establish the causes of [issue #10](https://github.com/BitmatchApp/Bitmatch/issues/10) or [issue #23](https://github.com/BitmatchApp/Bitmatch/issues/23).

The transfer-event record keeps at most two 256 KiB files. Export soon after the problem, before later activity replaces the older events. Export also limits its input reads: an oversized, unreadable or unsupported file is listed in `rejectedInputs` by its fixed current/previous slot and reason, while valid events from the other file remain available. Malformed individual records are counted separately in `incompleteRecords`. Either case sets `recordingHadErrors`; an absent history file is normal. These flags never change the result of a transfer.

Screenshots, transfer reports and Check's differences export can contain names and paths. Review those separately before sharing them; they are not the same as the diagnostics export.

## What the record can tell us

- Whether the last recorded transfer work was copying, verification, ASC MHL or report export.
- Which verification jobs started, opened their destination, finished hashing and completed, with an outcome for each. Jobs use numbers instead of filenames; long reads add a breadcrumb every 8 GiB.
- Whether numerical progress was still advancing. General progress is sampled when updates arrive, at most once every ten seconds; it is not a heartbeat during a blocked read.
- Whether Check was listing or checking files, its counts and its recorded outcome.
- Whether process memory use was growing. This is a resource-pressure clue, not proof that macOS terminated the app.
- Whether cancellation came from Cancel, the menu, closing the window, quitting, or a parent task. Authoritative-result identity guards have their own reason codes.
- Whether ASC MHL publication returned a filesystem error, including the exFAT exclusive-rename fallback.
- Which engine and app events belong to the same operation, including after an app restart.

A missing terminal event does **not** prove a crash or explain a hardware disconnect. A blocked filesystem call cannot emit a fresh event. Crash reports, if macOS creates one, and a controlled test with the affected hardware may still be needed. The export supplements the saved transfer verdict; it never replaces verification or makes a partial transfer safe to erase.
