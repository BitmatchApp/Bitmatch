# BitMatch Guide

## Queue, Recovery, and Handoff

Use **Add another card** under the source to queue the next card, right on the main screen. Open **History** from the toolbar to see what happened earlier. Each queued transfer keeps its own source, backups, and settings. The queue stops when something needs attention. A retry keeps the old attempt in history and checks the original folders before starting again; verified existing files can be reused after checking them.

On iPhone and iPad, keep BitMatch open while it works. iOS can interrupt a transfer; the saved attempt will be marked interrupted when you reopen the app. Project cards stay with their project and need review there before another ingest.

Notifications say when a card is safe to erase, when something needs you, and when the queue is done. Change them in Settings.

## ASC MHL

ASC MHL is on by default for verified copies. It adds another full read of each backup to create a compatible inventory. Existing ASC histories are left alone, with an issue shown instead of pretending they were extended. You can turn it off under **Advanced** when you don't need the handoff record.

If a retry encounters an existing history, **History → the transfer's details → Retry without ASC MHL** rechecks the copies without replacing that history. The one workflow BitMatch supports—verify locally, hand over an initial inventory, receiver validates—is written down in [SUPPORTED_WORKFLOW.md](validation/ascmhl/SUPPORTED_WORKFLOW.md); there is no chain-of-custody claim. See the [scope and validation](validation/ascmhl/README.md) too.

## Photographer Jobs

A wedding with two photographers, three cameras, and a pile of cards gets messy fast. Jobs keep it together. Pick a folder recipe, tell BitMatch whose card it is, and keep the original card contents intact.

For example:

```text
2026-09-06_Smith-Wedding/
└── Originals/
    └── Mike/
        └── Sony-A7IV/
            └── Card-001/
                └── [original card contents]
```

The dashboard keeps track of each card and its verified backups. Reports include where everything went, card fingerprints, RAW/JPEG companion counts, warnings, and failures. A card only becomes locally safe when the required number of exact local copies has been verified.

## Optional SFTP Backup — Mac

Have a server to back up to? Save an SFTP destination for the job and queue an upload once the local copy is verified. The upload reads that local backup, so it doesn't need to keep reading your camera card.

A few things to know:

- Authentication uses your SSH agent. You'll confirm the host key when connecting to a new host.
- The server needs SFTP **and SSH shell access**, with standard file utilities and hard-link support. An SFTP-only account won't do.
- **SHA-256 read-back** downloads the remote file to check it. That costs extra bandwidth and local temporary space.
- **Upload only** means **Uploaded · Unverified**. Getting it onto the server isn't proof that the contents match.
- iPad can keep the project's remote settings, but uploads run on Mac. S3 and WebDAV aren't available yet.

You can ignore SFTP entirely and keep everything local. No app analytics uploads. If you set up remote backup, your selected data goes to the server you chose.

## Before You Trust It With Your Footage

BitMatch reads the source without writing to it. It copies through temporary files and doesn't overwrite conflicting destination files. Checksum modes reuse an existing file only after verifying that it matches.

Source scanning rejects unreadable metadata, unsafe paths, and portable filename collisions. Hidden files and empty folders are preserved, except for designated macOS metadata folders at the volume root; symlink entries are skipped. Verification rejects files that change size or identity while being read. Completion screens and reports count failures and sidecars too.

**This is beta software from a one-person project.** I have not tested every camera, drive, filesystem, hub, or OS combination. Try it with disposable files before using it on a job. Keep the source card until every required backup finishes cleanly and you've checked the report. Keep another independent copy of anything you can't replace.

There are automated tests for changing source files, truncated reads, destination conflicts, cancellation, large manifests, and transfer faults. That doesn't mean every drive and hub has been tested. The [validation status](HARDWARE_COMPATIBILITY.md) shows what we actually ran, including failures and things we couldn't test. If you want to help, follow the [hardware testing procedure](HARDWARE_TESTING.md) and send a [hardware test report](https://github.com/BitmatchApp/Bitmatch/issues/new?template=hardware-test.yml).

Found a transfer problem? Include your app and OS versions, drives and filesystems, verification mode, and what you did. Strip private filenames and client info from shared reports.

The [latest release notes](https://github.com/BitmatchApp/Bitmatch/releases/latest) have the current fixes, build checks, and download checksum.

## Cards and Drives

- **Sony VENICE SxS and AXS cards (Mac).** macOS can't read SxS cards recorded in UDF until Sony's SxS UDF Driver is installed ([Apple support article](https://support.apple.com/en-us/101826)), or AXS cards without Sony's AXS memory card reader software. When a connected card can't be read, BitMatch shows a notice on the setup screen saying what it needs, instead of showing nothing.
- **exFAT backup drives** work from 0.1.7. In 0.1.4 through 0.1.6, every file copied to an exFAT drive failed ("Destination file appeared during copy"). Nothing was overwritten, but nothing was backed up either.
- **Your Mac's startup disk.** A folder on it, for example in your home folder, is a valid backup. The disk itself and macOS system volumes (including Recovery) are not, and BitMatch says why. BitMatch never adds a drive like that by itself.
- **iPad and iPhone.** Earlier builds refused every backup folder chosen in Files (On My iPad, iCloud Drive, an external drive) as a "system folder" on a real device. 0.1.7 fixes that. The fix has automated tests, but it has not been confirmed on a physical iPhone or iPad yet.

## Who It's For

YouTube creators, short film folks, wedding and event photographers, web commercials, Instagram ads, anyone who wants verified backups without another subscription.

Not for big budget shows or union shoots with a full DIT cart.

## Building and Tests

Xcode 16 or newer, with SDKs for the supported targets. CI uses Xcode 16.4.

1. Clone this repository and open `BitMatch.xcodeproj`.
2. Pick `BitMatch` for Mac or `BitMatch-iPad` for iPad or iPhone.
3. For an iPad or iPhone device build, set your development team in Signing & Capabilities.
4. Build and run.

Run tests from the repository root:

```bash
bash test.sh mac-test       # macOS unit and integration tests
bash test.sh mac-build      # macOS Debug build
bash test.sh ipad-build     # iPad simulator Debug build
bash test.sh ipad-test      # requires IOS_SIMULATOR_DESTINATION
bash test.sh release-builds # macOS and iPad Release builds
```

The CI workflow is included, but GitHub Actions is currently disabled. Run `mac-test` and `ipad-build` locally before submitting changes.

## FAQ

**Will it work with my camera?** Probably. I personally shoot Sony, so that's the path I've beaten on. Detection for the other brands is in there, but that isn't the same as testing every camera. Open an issue if yours gives you trouble.

**Does it work on iPad and iPhone?** Both are core targets. They use the Files app for folder access. Build from source for now, and keep the app open during transfers; remote uploads are a Mac task.

**Why open source?** So you can trust it. The code is here. Read it before you trust your footage to it.

See the [MIT license](../LICENSE).
