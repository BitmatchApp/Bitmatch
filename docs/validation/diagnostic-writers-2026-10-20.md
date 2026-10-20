# Diagnostics shared-folder validation — October 20, 2026

Separate stores could lose events while creating, appending or rotating the same files. An isolated run of the original source retained 393 of 401 events. That run flagged malformed records; an earlier private reproduction lost a record without flagging the loss. Neither reproduction establishes the cause of a reported transfer failure.

## Change

Cooperating stores lock the diagnostics directory inode while recording, rotating or copying an export snapshot. The store never replaces that directory. Independent handles and equivalent paths therefore share the lock without a global registry. JSON decoding and the separate system-evidence snapshot happen after unlocking.

Lock acquisition uses a 250 ms deadline. A failed write remains best-effort and attempts to leave a zero-byte `.recording-error` marker so another instance or a later launch discloses the loss. If export cannot acquire the lock, it returns `snapshotUnavailable: true` and `recordingHadErrors: true`, without reading an inconsistent ring. This deadline bounds lock acquisition, not filesystem I/O or total export time.

The event ring remains two files of at most 256 KiB each. The optional error marker contains no user data. Writes reject symlinks and nonregular files; export still decodes only allowlisted, structured events. Existing free-form logs remain private.

## Regression evidence

- Independent stores, including equivalent directory paths, retain all 401 numbered events with no errors.
- Two producers plus 80 concurrent exports exercise rotation; snapshots contain whole, ordered producer suffixes without duplicate events, and storage stays within the two-file limit.
- A separate process holding the actual directory lock makes recording and export stop waiting, discloses the unavailable snapshot, and preserves the dropped-write flag after reopening.
- First-write failure, symlink and FIFO cases preserve outside data and expose no footage names in exports.
- Focused tests: 20 XCTest and 3 Swift Testing cases passed, zero failures.
- Full engine gate: `bash test.sh engine-test` passed both frameworks: 210 XCTest passed, 43 skipped; 223 Swift Testing passed. Zero failures. Skips include opt-in hardware and stress cases.
- Full Mac app build/tests passed: 1,314 passed, 23 skipped, zero failures (1,337 total), using the `mac-test` job's Xcode arguments with private DerivedData and a retained result bundle.
- The shared iPhone/iPad simulator target built successfully using the `ipad-build` job's arguments. Existing warnings in untouched code remain; these are not warning-free build claims.
- A private Swift harness compiled the unchanged engine sources and launched two actual writer processes plus separate exporters. Three rounds each retained all 401 events without errors. A forced-rotation run submitted 8,001 events; 37 exports launched while writers were active passed consistency checks. The final two files were 1,824 bytes each under a 2,048-byte test limit, retaining the newest 16 events as intended.

Isolated guard removals produced assertion failures for lock acquisition, export acquisition, the lock deadline, the persistent error marker and no-follow writes. The concurrent rotation test alone passed an early-unlock mutation on one schedule; it is stress coverage, not deterministic proof of that interleaving. The separate-process test checks export lock acquisition deterministically.

## Limits

Advisory locks coordinate updated, cooperating writers. Old BitMatch versions and unrelated programs do not follow this protocol. The ring deliberately retains only recent events; the error marker is conservative and persists after recording recovers. If storage also refuses the marker, only the current instance can remember that failure. These tests do not diagnose issue #10 or #23, prove power-loss durability, or establish physical-device behavior on iPhone or iPad.
