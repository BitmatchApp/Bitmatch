# ASC MHL interoperability

BitMatch creates **initial ASC MHL 2.0 destination inventories**. This is a deliberately limited first implementation, not full chain-of-custody management.

Each inventoried destination file must match the SHA-256 recorded by the successful copy operation. On supported filesystems, unchanged pinned readback evidence can supply the SHA-256 and MD5; otherwise the destination is streamed again. exFAT deliberately takes the fresh-read path. SHA-256 is not an ASC MHL 2.0 hash field and is never relabeled as one. These new destination records use `in-place` and `original`: they do not claim an inherited source-side MD5 verification history. The manifest lives in `ascmhl/` with a C4-protected `ascmhl_chain.xml`.

Only the listed verified files are covered. No directory or root completeness hashes are claimed. Existing destination files or reports outside the transfer inventory remain outside this record; the reference tool's whole-folder `diff` will identify such additional files. The executor refuses to generate a destination record when its results contain failed or missing files; it does not shorten the inventory to successful rows. A fully verified destination may receive its record even if another destination failed. Cancellation is propagated rather than reported as successful record generation. Record-generation issues are shown separately from the unchanged copy results.

Existing, nested, and ancestor ASC histories are refused and preserved, including histories copied from a source. BitMatch does not append, merge, flatten or import inherited histories. Check can validate supported inventory chains read-only, as described below. It never writes to the source. Use the official ASC tooling for those workflows until BitMatch supports and tests them. MD5 here serves interoperability and accidental-corruption checking; SHA-256 remains the independent copy verification check.

When the caller supplies its source URL, source and destination descriptors are pinned and checked for equal, ancestor, or descendant relationships before reads, staging writes, and publication. Descriptor-resolved paths catch ancestor symlinks that lead into the source.

Publication uses a pinned destination directory descriptor and no-follow file opens. Filesystems supporting exclusive directory rename publish a synchronized private stage with `RENAME_EXCL`; failures leave that private stage untouched. FAT-family volumes instead claim `ascmhl` exclusively and write through its pinned descriptor. They retain `BITMATCH_HISTORY_STATUS.txt`: BitMatch Check requires its completed record to match the exact initial manifest and chain bytes, and refuses interrupted or altered histories. The FAT manifest filename is distinct so a missing status cannot turn a partial new history into apparently valid legacy evidence. Missing, changed, duplicate, unsafe-path and symbolic-link entries are rejected before publication. Cancellation is checked during reads and publication. When fresh readback is needed, generating the record adds a full destination read, so this work can materially extend completion time on slow storage. Paranoid transfers no longer automatically emit the old proprietary MHL companions; optional handoff records are generated centrally through this ASC implementation.

The pinned official ASC CLI accepts a completed exFAT-generated history with the extra BitMatch status file, verifies its bytes, and can append a second generation. BitMatch Check preserves that status as an immutable **initial** completion witness. It can accept a supported externally extended chain only when its initial manifest and the exact original v1 single-generation chain still match that witness, and every current generation passes the read-only checks below. The status is never rewritten or resealed. FAT32, physical-drive power loss and other vendors' readers have not been validated here.

## Independent validation

Validated 2026-09-08 against the official [ASC reference implementation](https://github.com/ascmitc/mhl) at commit `0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687`, using its published schemas. The specification is maintained in [ascmitc/mhl-specification](https://github.com/ascmitc/mhl-specification).

The repeatable harness builds a Swift package executable linked to the actual engine generator, creates real nested media with an ampersand and accented filename, and checks:

- Manifest and chain against the official XSDs.
- File bytes with `ascmhl-debug verify`; inventory with `ascmhl diff`.
- Appending a second generation with official `ascmhl create`, then verifying again.
- Every chain C4 digest with the reference implementation's C4 hasher.
- Independent verification rejects deliberately modified media.

Run from the project directory after installing the official reference package in a Python 3.11+ environment:

```sh
Scripts/ascmhl/validate_reference.sh /path/to/ascmitc/mhl /path/to/venv/bin
```

[Recorded output](reference-validation.txt) includes the expected corruption error followed by the passing negative-control assertion. This is synthetic interoperability evidence, not validation against other offload and DIT tools, a DIT's production media, or physical iOS storage. Those acceptance checks remain outstanding.

## October 2026 compatibility corpus

The reference checks were rerun on October 10, 2026 at the same pinned reference revision. A permanent corpus now covers official-tool MD5/XXH64 records, two generations, C4-only unsupported evidence, nested inventories and unusual filenames, plus saved-report compatibility and damaged-input regressions. [Findings and current validation](../../EVIDENCE_COMPATIBILITY_VALIDATION.md).

Check verifies recorded file contents. With an `ascmhl_chain.xml`, it also checks supported chain records: exact ASC namespace/shape, contiguous ordered sequence numbers, safe same-directory manifest basenames, complete inventory coverage and every C4 digest. Custom and Unicode basenames are supported; case-variant chain filenames on a case-sensitive filesystem are refused rather than treated as legacy evidence. Reads are cancellable and bounded to 4 MiB per chain, 64 MiB per inventory and 4,096 generations. File and directory identities plus byte fingerprints are rechecked before and after media hashing, so a stale discovery cannot authorize a changed chain. Generation order takes precedence over different computers' creation clocks.

The chain check does **not** verify directory/root hashes, interpret `<previousPath>` rename lineage or child-history references, authenticate a history, or establish complete custody. In particular, a valid older external chain cannot prove that an unanchored tail generation was never removed before discovery. Those limits remain explicit in Check. Legacy inventories without chains retain the file-content-only verdict; malformed, missing referenced, truncated, reordered, duplicated, unsafe or unsupported chain evidence is refused. BitMatch reports retain precedence and acquire no ASC-chain claim.

On October 19, 2026, the real engine generated an initial history on a disposable mounted exFAT image and the pinned ASC CLI appended generation two on that volume using `create -h md5 -i '._*'`. Its original FAT completion status remained byte-identical; schemas, C4, media verification and diff passed. `reference/bitmatch-fat-extended` is a **sanitized derivative**, not the byte-for-byte mounted sample: the machine hostname was replaced and the synthetic media filename mapped to ASCII, the synthetic initial v1 witness was rebuilt during fixture creation, and the official CLI independently appended generation two to that sanitized copy. The rebuilt witness stayed byte-identical through that extension. The ASCII-only derivative avoids macOS exFAT decomposition versus Git composition differences; existing independent Unicode fixtures and production path handling are unchanged. This fixture-only operation never occurs in Check. The explicit metadata pattern does not change BitMatch's narrower production AppleDouble policy. `Scripts/ascmhl/validate_fat_chain_fixture.py` repeats the independent checks in disposable copies. This does not add classic-MHL discovery or history writes/extensions.
