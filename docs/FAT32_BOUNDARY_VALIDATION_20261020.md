# FAT32 single-file boundary validation

These opt-in engine tests exercise the actual macOS FAT32 driver through fresh disposable sparse disk images. They fill a gap left by `testFAT32LargeFileLimitKeepsOtherBackupVerified`, which already checks a 4 GiB + 1 byte file against FAT32 and a successful second backup.

Run on an APFS host with at least 8 GiB free:

```sh
BITMATCH_FAT32_BOUNDARY=1 swift test \
  --package-path Packages/BitMatchEngine --jobs 4 \
  --disable-swift-testing --filter MountedFAT32BoundaryTests
```

The two cases use separate 7 GiB FAT32 images, mounted under a new marked temporary directory. They never format, eject or write to selected physical drives. An ordinary run without the environment variable skips both tests.

- **4,294,967,295 bytes:** Standard copy and destination verification, independent source/destination SHA-256 equality, ASC MHL publication, Saved Check for both recorded files, and an identical retry which preserves the published history and destination content.
- **4,294,967,296 bytes:** a native filesystem `ftruncate` probe must reject the size with `EFBIG`; the actual transfer must also fail with `EFBIG`, refuse a complete MHL plan and a green verdict, retain an incomplete transfer marker, and preserve earlier media and history through a retry. If partial destination bytes remain, the retry must preserve them. Saved Check may still verify the earlier, smaller history; the partial file must remain outside that recorded inventory.

The successful retry repeats the copy/verification pipeline and checks that its existing history stayed unchanged; it does not invoke a second MHL publication. The initial successful handoff and the oversized retries' rejected MHL plans are tested separately.

The source files are sparse APFS fixtures with distinct bytes at the beginning, middle and final byte. Full SHA-256, size and modification-date checks establish that the source remains unchanged after the operations. The test deliberately adds the large file only while preparing the owned fixture, before capturing its source baseline. This is logical-size coverage, not evidence of camera-media throughput, real HDD or dock behavior, sudden power loss, or every FAT32 implementation.

Cleanup normally detaches only the image proven to back the exact owned mount. Successful fixtures are removed after ownership and mount checks. Failed fixtures and command logs are retained, with normal detachment attempted. No force detachment is used.

## Local result, October 20

The final native Apple Silicon Debug run passed both cases with zero failures and zero skips in 68.983 seconds. A preceding corrected run also passed both cases in 71.273 seconds; these are two repeated runs of two unique cases. The default opt-out run skipped exactly two tests with zero failures. Actual source hashes matched before and after each case, all three sentinels survived, and the mount table confirmed no owned image remained mounted. Successful fixtures were removed after normal detachment.

The initial attempt failed both cases during tiny-fixture setup because the selected backup folder had not been created. Those failures are retained separately and are not passing coverage or product failures. The corrected harness creates that folder before invoking the engine. No production change was needed.
