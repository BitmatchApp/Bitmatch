# If a transfer or Check goes wrong

Keep the source card. Open **History → Export diagnostics…** and save the JSON file. If BitMatch closed, reopen it first. Attach the file to your [bug report](https://github.com/BitmatchApp/Bitmatch/issues), along with:

- The exact error or a screenshot, and whether you were using **Copy & Verify** or **Check**.
- Roughly when it happened, your app and OS versions, and the verification mode.
- The source and backup drives, their filesystems if you know them, and any card reader or dock in between.
- For a large transfer, the approximate total size, largest file size, and your Mac's memory capacity.

The export contains recent transfer and Check phases, numerical progress, filesystem types, error codes, cancellation origins, app/OS versions and random operation IDs. Events also include process memory use when available. It does **not** contain footage names, paths, production labels, bookmarks, checksums or the full transfer history. Nothing is uploaded automatically.

The local record keeps at most two 256 KiB files. Export soon after the problem, before later activity replaces the older events. A recording failure is reported in the export; diagnostics never change the result of a transfer.

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
