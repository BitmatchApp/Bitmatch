# BitMatch Guide

## Queue, Recovery, and Handoff

Choose the next source, backups, and settings, then use **Add to queue** while another transfer is running, right on the main screen. Open **History** from the toolbar to see what happened earlier. Each queued transfer keeps its own source, backups, and settings. The queue stops when something needs attention. A retry keeps the old attempt in history and checks the original folders before starting again; verified existing files can be reused after checking them.

On iPhone and iPad, keep BitMatch open while it works. iOS can interrupt a transfer; the saved attempt will be marked interrupted when you reopen the app. Project cards stay with their project and need review there before another ingest.

Notifications say when a card is safe to erase, when something needs you, and when the queue is done. Change them in Settings.

## How Verification Works

Copying a file and checking it are separate jobs. BitMatch reads the card, writes each backup, then reads the destination bytes back. A matching checksum is evidence that those bytes matched when they were checked; a copy finishing or a filename appearing isn't enough.

- **Quick** copies and checks sizes. It doesn't verify contents and never marks the card safe to erase.
- **Standard** hashes the source while copying and reads every backup back with SHA-256.
- **Thorough** also reads the source again, using SHA-256 and MD5 to check for changes during the transfer.
- **Paranoid** adds a byte-by-byte comparison with the source as well as SHA-256.

An existing file is reused only after the selected verification checks establish that it matches. Conflicting files are never overwritten. A failed, cancelled or interrupted attempt keeps its partial results and stays unsafe. A retry is a new attempt, not permission to trust the old one.

“Safe to erase” requires complete verified coverage on every required backup, plus any requested handoff/report steps. Two folders on the same physical drive aren't independent backups. Quick, missing files and intentional AppleDouble exclusions cannot earn a whole-card safe verdict. Keep the source until you've reviewed the results; a successful check doesn't promise that a drive can never fail later.

PDF, CSV, JSON and ASC MHL describe the recorded work. They don't perform another verification just because you export them. Master Report summarizes saved records; **Check** reads the media again. Clip previews are optional report decoration and never proof of integrity.

## AppleDouble Companions

BitMatch preserves files by default, including hidden `._` companions that macOS uses for metadata on drives such as exFAT. Those can contain resource forks and Finder metadata; they're not always disposable.

If you need a copy without them, open **Advanced → Exclude AppleDouble companion files**. BitMatch checks the file structure, shows the count, and lets you review the list before starting. A `._` filename alone isn't enough: unrecognized files and camera sidecars stay in the copy. If that list changes before Start, the transfer refuses to run until you review the source again.

The option follows the transfer into the queue and history. Reports list the exclusions, and ASC MHL describes the selected destination files. **Keep the source:** “selected files verified” does not mean the whole card is backed up or safe to erase. Existing destination metadata is left alone, including companions macOS creates itself. This option doesn't repair conflicting files or filter an existing checksum inventory during Check.

## Check Existing Backups

Choose **Check**, then pick the folder or drive you want to check. Use **Its saved checksums** when BitMatch finds supported records, such as a BitMatch JSON report or an ASC MHL inventory. It reads the files again and compares them with those records; the original card does not need to be connected.

Use **Another folder** to compare two copies instead. Standard compares contents with SHA-256; Quick checks sizes only. The results separate changed files from files missing or extra in the other folder. An extra file alone does not mean the matching files are damaged. Check does not copy, delete, or repair anything.

The differences export includes filenames and paths. For a bug report without those details, use **History → Export diagnostics…** instead.

## Reports

Transfer reports record the results for each destination. PDF, CSV, and JSON exports are available on Mac, iPad, and iPhone. **Master Report** scans a selected folder or drive for saved transfer reports for a chosen day and combines them into a PDF and JSON summary. It summarizes those records; it does not re-verify the media. Use **Check** for that.

## ASC MHL

ASC MHL is on by default for verified copies. It creates an inventory someone else can use to check the backup. This may need another full read of the backup, including on exFAT; the handoff progress stays active while that happens. On supported filesystems, BitMatch can reuse the verified readback hashes after checking that the files have not changed. Existing ASC histories are left alone, with an issue shown instead of pretending they were extended. You can turn it off under **Advanced** when you don't need the handoff record.

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

Found a problem? Follow the [diagnostics guide](DIAGNOSTICS.md), include the exact error, and say whether you were using Copy & Verify or Check. Include your app and OS versions, drives and filesystems, verification mode, and what you did. Strip private filenames and client info from screenshots and transfer reports before sharing them.

The [latest release notes](https://github.com/BitmatchApp/Bitmatch/releases/latest) have the current fixes, build checks, and download checksum.

## Cards and Drives

- **Sony VENICE SxS and AXS cards (Mac).** If macOS sees a connected card but cannot read it, BitMatch shows a setup notice with driver guidance when it recognizes the card. A copied folder of Sony files passing a test is not the same as testing the original card and reader; that hardware still needs its own check.
- **exFAT backup drives.** Use the latest release: recent updates fixed copy publication and ASC MHL handoff on exFAT. macOS can also create hidden companion files on these drives. If an existing companion differs from the source, BitMatch refuses to overwrite it and explains the conflict. Keep the source and review the results.
- **Your Mac's startup disk.** A folder on it, for example in your home folder, is a valid backup. The disk itself and macOS system volumes (including Recovery) are not, and BitMatch says why. BitMatch never adds a drive like that by itself.
- **iPad and iPhone.** Pick folders through Files and keep BitMatch open during transfers. Cloud files must be downloaded locally first. Automated tests and simulator builds cover the shared workflow, but physical-device storage and backgrounding still need testing.

## Who It's For

YouTube creators, short film folks, wedding and event photographers, web commercials, Instagram ads, anyone who wants verified backups without another subscription.

Not for big budget shows or union shoots with a full DIT cart.

## Building and Tests

Use Xcode 26.3 or newer, with SDKs for the supported targets. See the [development guide](../DEVELOPMENT.md) for toolchain, simulator, and local test setup.

1. Clone this repository and open `BitMatch.xcodeproj`.
2. Pick `BitMatch` for Mac or `BitMatch-iPad` for iPad or iPhone.
3. For an iPad or iPhone device build, set your development team in Signing & Capabilities.
4. Build and run.

Run tests from the repository root:

```bash
bash test.sh engine-test    # shared transfer engine tests
bash test.sh mac-test       # macOS unit and integration tests
bash test.sh mac-build      # macOS Debug build
bash test.sh ipad-build     # iPad simulator Debug build
bash test.sh ipad-test      # requires IOS_SIMULATOR_DESTINATION
bash test.sh release-builds # macOS and iPad Release builds
```

Run the relevant tests locally before submitting changes. Shared-code changes need `mac-test` and `ipad-build`; changes to the engine also need `engine-test`. Keep test failures and skipped hardware checks separate from passing results.

## FAQ

**Will it work with my camera?** Probably. I personally shoot Sony, so that's the path I've beaten on. Detection for the other brands is in there, but that isn't the same as testing every camera. Open an issue if yours gives you trouble.

**Does it work on iPad and iPhone?** Both are core targets. They use the Files app for folder access. Build from source for now, and keep the app open during transfers; remote uploads are a Mac task.

**Why open source?** So you can trust it. The code is here. Read it before you trust your footage to it.

See the [MIT license](../LICENSE).

## PDF clip previews and History

Turn on **Settings → Reports → Include clip thumbnails in PDFs** to add small previews to new PDF reports. It starts off. Previews come from verified backup files after transfer verification; Quick copies do not supply verified previews. MOV, MP4 and M4V are supported when Apple's decoder can read them. Proprietary or unreadable clips remain in the file list without an image.

In **History**, expand a transfer and choose **Export report → PDF report** or **PDF with clip previews**. The original card does not need to be connected. Previews need an accessible original backup location whose saved folder identity still matches. Missing or changed-size backup files are skipped. The report retains the saved outcome and says that no new verification was performed; an image shows backup contents at report time, not proof that the backup is still unchanged.

Preview generation is sequential, limited to 200 clips and a 30-second collection budget, with a two-second wait per clip. Images are at most 256 × 144 pixels and 64 KB each. There is no persistent preview cache, and images are never added to diagnostic exports. Cancellation stops the report request; unavailable previews do not change verification or card safety.
