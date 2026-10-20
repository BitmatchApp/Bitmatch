# Seeded host soak and many-file stress

This extends the existing engine harness on disposable host storage. It does
not use selected physical drives, app UI, reports or MHL, and does not reproduce
issue #23.

The soak now checks the actual source inventory and SHA-256 values before and
after each transfer, including its three directories. It requires the exact
18 destination paths, successful Standard readback and independent destination
hashes. Failed assertions, incomplete iterations or cancellation prevent a
passed receipt and preserve the current fixture. Format-2 receipts retain
partial progress. Explicit marked fixture bases keep script-owned inputs inside
the disposable work directory; setting `TMPDIR` alone did not relocate
Foundation's temporary directory on this Mac.

The public runner previously selected an app test that had moved into the
engine package. It now builds the Release engine tests with four jobs and runs
one explicit XCTest. A read-only observer validates the direct worker's PID,
executable and process identity, samples physical footprint at a requested
10 ms interval, and requests SIGINT at 1 GiB or its deadline. It never force
kills. Sampling and OS calls can wait; brief peaks can be missed. These are
sampled guardrails, not hard latency limits or a leak proof.

## Actual results

- One soak XCTest completed **256/256 iterations**, seed **20261020** through
  **20261275**, in 26.548 seconds. There were zero test failures or skips.
  All 256 low-byte payload patterns occurred once. The fixed layout contains
  eight 256 KiB files and one small hidden metadata file; this is bounded
  byte-pattern coverage, not unlimited random filenames or workload diversity.
- The run checked **2,304 source hashes before**, **2,304 after**, and
  **4,608 destination hashes** across two backups per iteration. Directory
  inventories stayed unchanged. Sampled worker peak was **11.41 MiB** across
  1,869 samples, without a threshold or missing-sample failure.
- The first runner validator falsely rejected that successful run because
  buffered Swift stdout split an XCTest pass line. The exact selected
  class/method token and complete format-2 receipt were revalidated with the
  corrected parser; the 256 payloads were not rerun. Original failure metadata
  and the later revalidation receipt are both retained privately.
- The final complete script passed a separate two-iteration run: one actual
  XCTest, no skips/failures, 18 source hashes before/after and 36 destination
  hashes. Its sampled peak was 9.46 MiB. This validates the final explicit
  fixture-base and cleanup path.
- The existing many-tiny-file case at scale four passed one actual XCTest in
  86.859 seconds: **20,009 verified results**, deep paths, 255-byte names,
  Unicode forms, hidden files and zero-byte content. Independent post-run
  checks matched **20,009 source hashes and 20,009 destination hashes** against
  the declared generation bytes, with 65 matching directories. This case had
  no independent pre-transfer hash pass. The source test attribute remained;
  the destination correctly omitted it. Sampled peak was **144.72 MiB** across
  6,115 samples.
- A prior many-file attempt was intentionally interrupted with SIGINT to release
  the shared CPU slot. It is retained as an interrupted attempt, not a passing
  test or an application failure. Timing observations share the host with
  other validation work and are not performance promises.
- Five fixture tests and one source-mutation XCTest passed. The new checks
  reject unmarked fixture bases, preserve parent sentinels, and detect same-size
  source mutation, unexpected files and a missing empty directory. Three Python
  test methods also passed, including 15 negative log/receipt variants for
  zero tests, skips, failures, wrong selection, duplicates and partial coverage.

No production code changed. Successful disposable media was removed after
hash validation; failed/interrupted evidence remains private. Raw logs include
local fixture paths and should be reviewed before sharing.
