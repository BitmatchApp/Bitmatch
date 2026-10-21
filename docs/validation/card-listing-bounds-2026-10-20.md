# Camera layout listing bounds — October 20, 2026

`CardListing.scan` now obtains each directory's entries from a shallow iterator instead of materializing its whole child array before applying the entry limit. The existing breadth-first traversal, four-level depth limit, 20,000-entry limit, hidden-file policy and camera layout rules remain. Cancellation and the entry cap are checked before requesting another yielded entry. Directory symlinks are not traversed.

This is an advisory camera-layout scan, not transfer enumeration or verification. It does not change the selected file set or erase verdict. The cap limits requested/yielded entries; it does not establish a deadline for filesystem calls or Foundation's internal work. A blocked read still cannot be forcibly cancelled. The broader policy for avoiding recursive classification of unselected mounts remains open.

## Local checks

The focused camera layout suite passed **31 Swift Testing tests**, zero failures, in 0.872 seconds. New controls cover the exact iterator-request limit, cancellation within one wide directory, the depth boundary and directory-symlink traversal. Existing camera-layout tests also passed.

Removing only the inner-loop cancellation check produced the intended regression: the controlled iterator requested eight entries instead of two, and the listing retained eight files instead of two. The 31-test suite failed with those two assertions. The classifier was restored byte-for-byte afterward.

The final combined Mac suite then passed **1,411 tests**, skipped 34 and failed none (1,445 total). The generic iPhone/iPad simulator build also succeeded for arm64 and x86_64. Those are local app-host/build results, not physical mobile or camera-card validation. No new UI, physical-device, signed-app or field-incident claim follows from this slice.
