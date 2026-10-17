# exFAT/FAT media-file publication design

This is the design for the exFAT/FAT media-file publication-race change.
Source cards remain read-only; a media file that BitMatch did not create is
never replaced or removed.

## What is measured

On a disposable mounted exFAT image, each of these calls preserved an existing
sentinel (`EEXIST`, errno 17), but failed against a vacant **file** name with
`ENOTSUP` (errno 45):

| Call | Vacant target | Existing target |
| --- | --- | --- |
| `renameatx_np(..., RENAME_EXCL)` | `ENOTSUP` | `EEXIST`; unchanged |
| `linkat` | `ENOTSUP` | `EEXIST`; unchanged |
| `clonefileat(..., CLONE_NOFOLLOW)` | `ENOTSUP` | `EEXIST`; unchanged |

The image was detached and deleted. The former `publishByClaimingName` path
had two separate deterministic red tests on APFS with the fallback forced:
replacing the empty claim immediately before `renameat` loses the other
writer's bytes, and replacing it immediately before failure cleanup loses
those bytes through `unlinkat`. These tests demonstrate the race in the code;
they do not establish that a customer has hit either race.

Without a supported late atomic no-replace operation, exFAT cannot provide
all three properties at once: a normal final name that stays invisible until
fully written, no replacement of a concurrent writer's name, and cleanup of
only the file BitMatch owns. The fallback chooses no replacement and honest
incomplete-output evidence. Its normal final name may be visible while bytes
are still being written.

## On-disk attempt marker

For each exFAT/FAT destination root and transfer attempt, create exactly one
visible, warning-oriented status file directly under the pinned root:

`BITMATCH_TRANSFER_STATUS_<random UUID>.txt`

The name is generated independently of the transfer ID. Before creating it,
reject or regenerate any exact collision with the source manifest. Create it
using descriptor-relative `openat(O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC)`. The
file starts with a strict magic/version and an explicit warning, the
transfer-attempt UUID and a random marker UUID, followed by numbered,
checksummed status records. It holds no footage names or paths. `incomplete`
is the first status. Write and flush
the marker, then fsync the destination-root directory. Only after both flushes
succeed may a final media name be created. If either flush fails, no final
media name is created. Never remove or rename the marker automatically.
For newly created output-root or nested folders on this direct-write path,
fsync each parent after `mkdirat` before writing media beneath the new name.
If a parent sync fails, that destination remains failed for the attempt.
These calls request durability from macOS and the drive; they cannot prove how
a particular device behaves after sudden power loss.

BitMatch retains the open marker descriptor for that attempt and appends
statuses through it. A torn, missing, malformed, or unreadable record is
interpreted as incomplete, never complete. A marker is a warning/recovery
signal, **not** proof of copied or verified bytes. A file result and safe
verdict still require the existing independent readback, exact selected-file
coverage, ASC MHL/report work and durable transfer journal outcome.

The marker only records file-evidence status, not a whole-transfer safe
verdict:

1. `incomplete`: created and flushed before any direct final-name output.
2. `filesVerified`: append/fsync only when every selected file for this
   destination has a valid independent readback result and exact coverage.
3. `copyCompleteUnverified`: Quick mode only; never safe to erase.
A copy or readback failure leaves `incomplete` as the last valid status. Later
MHL, report or journal failure can leave `filesVerified` while the whole
attempt remains unsafe. A failed append or torn record also leaves it unsafe.

A successful `filesVerified` marker cannot turn a failed report, missing MHL,
cancelled run or failed journal commit into success. Conversely, an unreadable
or incomplete marker for the **current** attempt blocks a safe verdict, even
when readback results exist; the output's state would otherwise contradict
BitMatch's evidence. Previous attempt markers stay immutable and may still
say `incomplete` after a new attempt recovers the files.

Marker names have an exact UUID shape and strict content format. Do not
blanket-filter `._*`, `.bitmatch*`, or an arbitrary hidden file from selected
source coverage. If a source file happens to have the chosen marker name,
choose another UUID before writing. Existing unrelated names are never
overwritten. The destination's final coverage check may enumerate marker
files; it must still check every selected source-relative path exactly and
must not use marker presence to excuse a missing or unexpected selected row.

## Final file and recovery

On exFAT/FAT, once the durable marker exists, create each new final media
name with `openat(O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC)` below a pinned parent.
Keep that descriptor through the copy; set `F_NOCACHE`, write chunks, preserve
required metadata, flush the file, and sync its parent directory. Never
plain-rename a temporary file over a claimed final name. Never pathname-unlink
the final file after an error or cancellation. Leave uncertain partial bytes
in place, marked by the attempt status and an unsafe History result. A
replacement of the final name while the descriptor is open must fail the
attempt's identity/coverage checks; BitMatch must not delete or replace the
new occupant. APFS's current hard-link publication path remains separate.
The retained marker is checked immediately before each direct final-name
create, at the start of a file, and at 256 MiB write intervals. A missing or
changed marker stops further writes at the next check, and final coverage
checks it again. A deliberate deletion between checks cannot be made atomic
with a write on this filesystem; do not treat the marker as proof of complete
media.

An unknown filesystem that rejects hard links fails closed with an actionable
message. It does not fall back to the old claim-and-rename path. This change
closes the confirmed final-name races. Existing cleanup of random
`.bitmatch.tmp.*` names on the APFS/hard-link path is best-effort: Darwin has
no atomic unlink-if-owned primitive, so a deliberate replacement of a temp
name at the exact cleanup boundary remains a separate design problem. Do not
describe this change as a universal namespace-race proof.

The existing ASC MHL directory fallback is separate from media-file
publication. On exFAT it preserves a nonempty valid history, but a concurrent
writer could substitute an empty directory at its claim boundary. That
directory race needs its own ownership design and regression work; this media
protocol does not close it.

The separate named-readback identity fix landed in PR #51 before this change.
The reader checks that the public name still identifies its open file, and
final coverage compares the current named file with the file used for
readback. This identity proof must remain ahead of status advancement; the
exFAT marker cannot substitute for it.

On a new run or retry, a final name that already exists is never overwritten.
Standard/Thorough/Paranoid may reuse it only after the existing whole-file
source/destination proof and the normal independent readback. The result's
existing `wasReused` flag and "already existed and were verified" wording
describe that proof; a distinct "rechecked after an incomplete attempt" label
remains future UX work. Quick mode refuses existing-file reuse. A short or
mismatched file remains untouched and unsafe; guide the operator to choose a
new destination folder or resolve the old output manually. The earlier
History attempt remains interrupted/failed even if a later one succeeds.

If the final name is absent, a new attempt may create its own marker and then
its own O_EXCL final file. An old marker remains as evidence of its old run.
The app may inspect prior marker records to explain recovery, but may not
trust them to skip verification. A marker moved or replaced by an external
actor is detected where possible through its retained descriptor and pinned
path identity; a hostile actor replacing it at the exact moment of a process
death cannot be fully defeated without a filesystem transaction. This marker
policy targets ordinary interruption and accidental concurrent file writes,
while no-overwrite of media names holds through O_EXCL.

## Regression matrix before merge

| Scenario | Required observation |
| --- | --- |
| Claim swapped just before old `renameat` | Red on current code; replacement bytes survive new code. |
| Claim swapped just before old cleanup | Red on current code; replacement bytes survive new code. |
| Marker creation/flush fails | No normal final media name created. |
| Crash/cancel after durable marker, before final create | Marker remains incomplete; no final file. |
| Crash/cancel during direct final write | Partial file and incomplete marker remain; no green result. |
| Crash after file flush, before readback/status | Existing file is rechecked, not silently treated as complete. |
| Final name swapped during direct write/readback | Other writer's bytes survive; result fails closed. |
| Existing mismatched or short file | No overwrite or delete; clear unsafe History/retry guidance. |
| Existing matching file in Standard | Independent whole-file proof, reused/recovered note, new attempt only may succeed. |
| Existing file in Quick | Reuse refused. |
| Same source name as a would-be marker | Exact source file still selected; marker name regenerated or setup fails safely. |
| Corrupt/torn/missing current marker | Never a safe verdict. |
| Mounted exFAT and APFS transfers | exFAT direct final FD, APFS hard-link path, full readback, MHL/report, cancellation and journal coverage. Mounted FAT32 transfer and sync behavior remain a follow-up because this Mac could not attach FAT images. |
| Deliberately swapped random temp name on APFS | Characterize separately; do not claim a conditional-unlink guarantee. |

The original two red cases now exercise direct-final publication boundaries.
Mounted exFAT file and root-directory flushes, full Standard readback and ASC
MHL handoff passed on the test Mac. FAT32 remains untested here because this
Mac's `hdiutil` returned “Device not configured” while creating or attaching
FAT images, before the test could reach the filesystem. This is a test-host
limitation, not evidence that FAT32 supports or rejects these sync calls.
