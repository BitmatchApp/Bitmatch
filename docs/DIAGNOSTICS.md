# If a transfer stops unexpectedly

Keep the source card. Open **History → Export diagnostics…** and save the JSON file. You can do this after restarting BitMatch. Attach that file to your bug report, along with roughly when the problem happened and the drives, dock and verification mode you were using.

The export contains recent transfer phases, numerical progress, filesystem types, error codes, cancellation origins, app/OS versions and random operation IDs. It does **not** contain footage names, paths, production labels, bookmarks, checksums or the full transfer history. Nothing is uploaded automatically.

The local record keeps at most two 256 KiB files. Export soon after the problem, before later transfers replace the older events. A recording failure is reported in the export; diagnostics never change the result of a transfer.

## What the record can tell us

- Whether the last recorded work was copying, verification, ASC MHL or report export.
- Whether numerical progress was still advancing. Progress is sampled when updates arrive, at most once every ten seconds; it is not a heartbeat during a blocked read.
- Whether cancellation came from Cancel, the menu, closing the window, quitting, or a parent task. Authoritative-result identity guards have their own reason codes.
- Whether ASC MHL publication returned a filesystem error, including the exFAT exclusive-rename fallback.
- Which engine and app events belong to the same operation, including after an app restart.

A missing terminal event does **not** prove a crash or explain a hardware disconnect. A blocked filesystem call cannot emit a fresh event. Crash reports, if macOS creates one, and a controlled test with the affected hardware may still be needed. The export supplements the saved transfer verdict; it never replaces verification or makes a partial transfer safe to erase.
