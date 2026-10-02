# Synthetic transfer matrix

The matrix uses disposable mounted APFS, journaled HFS+, exFAT and case-sensitive APFS images. Source and backup images are separate. It checks source hashes before/after transfers, destination hashes, terminal verdicts, report exports and ASC MHL handoff. Disk images exercise the real filesystem drivers, not USB controllers or physical drive failure.

## Run

```sh
bash Scripts/test-transfer-regression-matrix.sh
BITMATCH_EXTENDED_MATRIX=1 bash Scripts/test-transfer-regression-matrix.sh
bash Scripts/test-filesystem-fault-matrix.sh
bash Scripts/test-full-transfer-matrix.sh
MATRIX_FOCUS=collision bash Scripts/test-full-transfer-matrix.sh
MATRIX_KEY=exfat-exfat-Standard-1-3 bash Scripts/test-full-transfer-matrix.sh
```

Extended runs need macOS, Xcode, several minutes and space for disposable sparse images. Run Mac test jobs sequentially when sharing DerivedData. `MATRIX_DERIVED_DATA` can select a separate directory. Scripts detach their owned images without force and remove them only after successful detach. Busy images are retained with an explicit path.

## Coverage and October 1, 2026 results

| Suite | Coverage | Result |
| --- | --- | --- |
| Full executor | 4 source × 4 backup filesystems × 4 verification modes × 1/2 backups × MHL/report options; initial + repeat | 512 combinations / 1,024 operations completed; 27 combinations had 49 assertion failures |
| Mounted faults/payloads | 48 fault conditions + 6 payload conditions per filesystem | 44 XCTest methods / 216 scenarios passed across four filesystems |
| Filename collisions | Two distinct case-sensitive names onto four filesystems, four modes | 16 cases passed after correcting the test to honor the existing conservative manifest policy |
| Seeded soak | 100 iterations, seed 20261001, nine files, two backups | Passed; 1,800 independently hash-checked outputs |
| Issue #10 filesystem pair | Journaled HFS+ source → exFAT backup, full executor/MHL/report path | 26 selected tests passed |
| Regular engine suite | Includes verifier interruption regression in sequential and pipelined paths | 106 XCTest methods, 15 opt-in skips, zero failures; 123 Swift Testing tests passed |
| Mac app / iPad | Full Mac tests; iPad simulator build | Passed |

Fixtures include empty files/directories, tiny files, 64 MiB files, 1,000-file cards, 24-level nesting, Unicode, spaces, hidden metadata and AppleDouble files. Faults include destination removal/replacement, conflicting files, incomplete histories, truncated media, write/flush/close/publication errors, readback errors, cancellation before start and cancellation thrown during copy/verification. Errors are injected through existing engine hooks; disks are not physically unplugged or filled to simulate ENOSPC.

## Confirmed fix

A verifier that throws `CancellationError` without cancelling its parent previously had its interruption swallowed in the pipelined path, or recorded as an ordinary file error in the sequential path. The pipeline now propagates that interruption in both paths. A focused regression covers Standard, Thorough and Paranoid; mounted tests established failure before the fix and success afterward. This is a separate confirmed defect, not proof of the issue #10 reporter's cause.

## Open finding

The broad executor run intermittently refused publication of AppleDouble sidecars when an exFAT source was copied onto an exFAT backup. This also occurred when the exFAT backup was the second destination after HFS+. The destination sidecar appeared during publication or already existed when Quick mode attempted it. BitMatch refused overwrite, retained an unsafe terminal verdict, and withheld complete MHL history for the failed backup. Source and destination byte-hash assertions did not fail.

27 combinations failed the all-success expectation. A selected rerun of `exfat-exfat-Standard-1-3` passed. The source fixture has macOS provenance metadata and real AppleDouble files; whether the collision originates in app behavior or external filesystem metadata activity is unresolved. Do not suppress sidecars, overwrite them, weaken verdicts, or mark this matrix fully green. `MATRIX_INITIAL_FAILURE` records failed initial rows on future runs; XCTest's exit status is authoritative, not the number of combinations completed.

Local raw evidence is retained under `dist/validation/transfer-matrix-20261001` and `dist/validation/fault-matrix-20261001-210325`. The individual filter above is provided to aid further reproduction.

Uncovered conditions include physical dock/cable disconnection, real power loss, SMB/NAS/cloud providers, files larger than 4 GiB, real out-of-space disks, extended thermal/throttling runs and iOS background suspension. Mounted images cannot reproduce the reporter's hardware chain exactly.
