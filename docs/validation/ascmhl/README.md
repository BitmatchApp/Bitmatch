# ASC MHL interoperability

BitMatch creates **initial ASC MHL 2.0 destination inventories**. This is a deliberately limited first implementation, not full chain-of-custody management.

Each inventoried destination file is streamed again and checked against the SHA-256 recorded by the successful copy operation. The same read produces an MD5 digest for the ASC record. SHA-256 is not an ASC MHL 2.0 hash field and is never relabeled as one. These new destination records use `in-place` and `original`: they do not claim an inherited source-side MD5 verification history. The manifest lives in `ascmhl/` with a C4-protected `ascmhl_chain.xml`.

Only the listed verified files are covered. No directory or root completeness hashes are claimed. Existing destination files or reports outside the transfer inventory remain outside this record; the reference tool's whole-folder `diff` will identify such additional files. The executor refuses to generate a destination record when its results contain failed or missing files; it does not shorten the inventory to successful rows. A fully verified destination may receive its record even if another destination failed. Cancellation is propagated rather than reported as successful record generation. Record-generation issues are shown separately from the unchanged copy results.

Existing, nested, and ancestor ASC histories are refused and preserved, including histories copied from a source. BitMatch does not yet append, merge, flatten, import, or validate inherited histories. It never writes to the source. Use the official ASC tooling for those workflows until BitMatch supports and tests them. MD5 here serves interoperability and accidental-corruption checking; SHA-256 remains the independent copy verification check.

When the caller supplies its source URL, source and destination descriptors are pinned and checked for equal, ancestor, or descendant relationships before reads, staging writes, and publication. Descriptor-resolved paths catch ancestor symlinks that lead into the source.

Publication uses a pinned destination directory descriptor, no-follow file opens, exclusive staging writes, and an exclusive directory rename. Missing, changed, duplicate, unsafe-path and symbolic-link entries are rejected before publication. Cancellation is checked during reads and before publication. Generating the record adds a full destination read, so this work can materially extend completion time on slow storage. Paranoid transfers no longer automatically emit the old proprietary MHL companions; optional handoff records are generated centrally through this ASC implementation.

## Independent validation

Validated 2026-09-08 against the official [ASC reference implementation](https://github.com/ascmitc/mhl) at commit `0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687`, using its published schemas. The specification is maintained in [ascmitc/mhl-specification](https://github.com/ascmitc/mhl-specification).

The repeatable harness compiles the actual shared Swift generator, creates real nested media with an ampersand and accented filename, and checks:

- Manifest and chain against the official XSDs.
- File bytes with `ascmhl-debug verify`; inventory with `ascmhl diff`.
- Appending a second generation with official `ascmhl create`, then verifying again.
- Every chain C4 digest with the reference implementation's C4 hasher.
- Independent verification rejects deliberately modified media.

Run from the project directory after installing the official reference package in a Python 3.11+ environment:

```sh
Scripts/ascmhl/validate_reference.sh /path/to/ascmitc/mhl /path/to/venv/bin
```

[Recorded output](reference-validation.txt) includes the expected corruption error followed by the passing negative-control assertion. This is synthetic interoperability evidence, not validation against Hedge/OffShoot, ShotPut, Silverstack, a DIT's production media, or physical iOS storage. Those acceptance checks remain outstanding.
