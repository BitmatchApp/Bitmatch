# Large-file memory follow-up

Issue #23 reports BitMatch reaching about 55 GB of application memory during a transfer. The report alone does not identify the app version or stage. The findings below are real local bugs, but they do not establish which path the reporter hit.

## Confirmed paths

- **ASC MHL generation:** on filesystems such as exFAT, BitMatch rereads the verified destination because the filesystem cannot supply a reliable change time for readback reuse. The synchronous 4 MiB read/hash loop retained Foundation buffers across chunks. This loop has shipped since 0.2.1. Its read, SHA-256 and MD5 updates now run inside one autorelease pool per chunk. Cancellation, uncached destination reads, progress, file-stability checks and history publication are unchanged.
- **Saved Check with XXH64 evidence:** the separate 1 MiB XXH64 read loop had the same retention. Its read and hash update now share a per-chunk pool. MD5 and SHA-256 Check already use pooled `ChecksumEngine` reads. This path does not run during an ordinary copy/verify transfer.

Both regressions use 512 MiB sparse files, verify the actual engine operation, and are opt-in so that physical-footprint assertions run in an isolated test host:

```sh
BITMATCH_MHL_MEMORY_TEST=1 arch -arm64 swift test --package-path Packages/BitMatchEngine -c release --build-system native --filter ASCMHLMemoryTests --no-parallel
BITMATCH_CHECK_MEMORY_TEST=1 arch -arm64 swift test --package-path Packages/BitMatchEngine -c release --build-system native --filter SavedChecksumMemoryTests --no-parallel
```

Before the fixes, the MHL test failed at 10 → 521 MiB (511 MiB growth); after, it passed at 10 → 10 MiB while reading all 128 chunks and publishing the manifest and chain. The XXH64 Check test failed at 5 → 521 MiB (516 MiB retained at completion); its final isolated run passed at 5 → 9 MiB and still reported the deliberately mismatched checksum as changed. The MHL figure is the peak sampled after each chunk; the Check figure is the footprint reported at the end of checking the file.

The existing mounted-exFAT Standard copy → verification → MHL handoff test also passes with the patch. It exercises the real exFAT driver but uses small media. The sparse-file memory tests exercise large logical reads on APFS; the MHL test forces the exFAT reread policy. None of these tests reproduces the reporter's physical drive, footage, or 55 GB workload. The next diagnostic export should identify the version and last stage reached.

Local validation after both fixes: the full serial engine suite passed (126 XCTest cases, 17 intentional opt-in skips, zero failures; 151 Swift Testing cases passed). The explicit mounted-exFAT handoff test passed. The Mac app test build passed (1,099 passed, 13 skipped, zero failed), and the iPad/iPhone simulator build succeeded. The two isolated memory tests passed under their respective flags. Logs and the Mac result summary are in the local ignored `dist/validation/issue23-memory/` directory.
