# Independent classic MHL single-algorithm fixtures

Four sanitized classic MHL 1.1 inventories from `mhl-suite` 1.4.0 at upstream
Git revision `9304aef7139403e8188d48ac2c653594ad589745` from
`https://github.com/lucuma13/mhl-suite`. This is the same separately authored
Python/lxml writer behind the [padded-path fixture](../classic-padded-independent/README.md),
used here for the remaining supported single-digest shapes. The upstream
implementation is MIT licensed; its exact notice is retained in
`UPSTREAM-MIT-LICENSE.txt` (SHA-256
`ad1c3e1134c9b2d0827268ce65540dd2d6ed57ae2978b6e939a663b134f0f821`).

Each variant directory holds identical original synthetic media plus its own
writer-generated manifest:

- `md5-only/md5-only.mhl` — one MD5 record per file (supported).
- `sha1-only/sha1-only.mhl` — one SHA-1 record per file (supported).
- `size-only/size-only.mhl` — size records with a `<null>` element and no
  digest (unsupported by the BitMatch reader; explicit fail-closed control).
- `xxh64/xxh64.mhl` — `<xxhash64be>` records (unsupported by the BitMatch
  reader; explicit fail-closed control).

The media is original synthetic text under BitMatch's MIT license:

| File | Bytes | MD5 | SHA-1 | SHA-256 |
| --- | ---: | --- | --- | --- |
| `clip one.mov` | 34 | `bdb6d9e8bf3290710359905a3a4b0606` | `a4851f5a8f75a4c5225f726f3194ea6ce6e50e5b` | `83e51127d79df2add3318c3f0d95e256b1df51b2ac140c34f31bf7742d3d14fd` |
| `Reel A/two.mov` | 36 | `d5e836a4b7fbcfc4e08b0c8c379c94b2` | `0e6219cd57f714cb4075bf786f18e82072c91a0b` | `194292fb3512224186277938d6b57777688c5d2abf7b631cf51623442ae18a0e` |
| `café test.mov` | 33 | `35136dce1d8f244f7c7328a199de1b89` | `65df625d123c324bb8f46804d96edee17b6f4e58` | `d7ab03d4191a9be029d0e8965dfab5a6ee98976ef1005ba5250bf2ddb83dec0a` |

The three paths exercise a filename space, a nested directory and a
non-ASCII name as emitted by the writer. All four media copies are
byte-identical across variants.

Committed sanitized manifest SHA-256 values:

- `md5-only/md5-only.mhl`: `09962ebb488b7ef762c0384dc792fd41aea6423fd971243d28ddb1f4163b5286`
- `sha1-only/sha1-only.mhl`: `c8c86ed1c5f07f98b4ce03ebf7c9320e81c1ce82ec51d23f6f369d8d8d005526`
- `size-only/size-only.mhl`: `054b35d387989d84daea076e65bc8ef55659b2a0b12fc3aa99fafe695f27b492`
- `xxh64/xxh64.mhl`: `043bb99d1035bfc47f5c7888e21c78bd67d0dfdfdeb266b466e0bffe79d7ef89`

Only creator username, hostname and environment log were replaced with
synthetic values. The original raw output remains private. The raw generated
manifest SHA-256 values were `9d5302c8320367d02769a117b32beef20b1bf5f028088df28e60ccd85002ef92`
(md5), `b469259fd0e6fbceef71430af453a930936dc658d58d3cd78f2be5db35684baa`
(sha1), `c1e1bbfad8812ee9db94fd3542dcfec103c75f7c72229ca5b153f5f2fca591df`
(size-only) and `0cd64152ca1352ac2e66318008c33d54adf0e91657587b8661be14fdc1bb931f`
(xxh64). Paths, file sizes, dates and digest claims are unchanged. Generation
times differ on a new run, so whole-manifest byte reproducibility beyond the
committed sanitized copies is not claimed. This fixture exercises
content-digest parsing and the supported/unsupported record boundary; it does
not authenticate history, custody or creator statements.

## Generation

Python 3.12.15 with the hash-pinned runtime closure from the upstream
`uv.lock` (lxml 6.1.1, xxhash 3.8.1, packaging 26.2, pathspec 1.1.1,
pyuca 1.2, rich 15.0.0, click 8.4.2); the pinned source was installed
without dependencies after an explicit hatchling install. The pinned
`pyproject.toml` SHA-256 is `0323684799faf0236992bc5fb03e4784a697e42996350cc989bff154d68d2a75`
and `uv.lock` is `9c15e47468d65692efbba17feed66f568ca51a8f0b23d4776a9bc0e2d9b1f4d9`.

Create a disposable `src/` directory containing exactly the three payloads
above (including the nested `Reel A/` directory and the UTF-8 `café`
filename), copy it once per variant, and seal inside each copy with the
updater disabled:

```sh
NO_UPDATE_CHECK=1 python -m mhl_suite.cli.simple_mhl seal . -a md5
NO_UPDATE_CHECK=1 python -m mhl_suite.cli.simple_mhl seal . -a sha1
NO_UPDATE_CHECK=1 python -m mhl_suite.cli.simple_mhl seal . -a null
NO_UPDATE_CHECK=1 python -m mhl_suite.cli.simple_mhl seal . -a xxh64
```

Then check each sanitized manifest beside a copy of its payloads:

```sh
NO_UPDATE_CHECK=1 simple-mhl verify md5-only.mhl -a md5
NO_UPDATE_CHECK=1 simple-mhl verify sha1-only.mhl -a sha1
NO_UPDATE_CHECK=1 simple-mhl verify size-only.mhl -S
NO_UPDATE_CHECK=1 simple-mhl verify xxh64.mhl -a xxh64
NO_UPDATE_CHECK=1 simple-mhl xsd-schema-check <manifest>
```

All four intact manifests returned exit 0 for both commands. Each also
validates against the primary classic MHL 1.1 XSD (SHA-256
`c1adcd2591069249c88f2fc1fabac81363e7572b952834cce66f72a264e4c703`)
with the W3C signature schema (SHA-256
`d102ad3df7664c307e0c2c776ba4a90513b1969974d8a940bae1a77f9f21e15d`)
resolved locally. Disposable-copy negatives with the upstream verifier:
same-size content corruption fails with exit 11 (`hash mismatch`), and
missing media fails with exit 10 (`missing file`); both were observed on
the md5 and sha1 variants. The upstream verifier accepts the size-only
and xxh64 manifests, while the BitMatch reader explicitly rejects those
record shapes; that disagreement is the intended fail-closed boundary,
not a defect in either tool.

## Limits

The writer refuses to seal empty files (`cannot seal empty file`), so
empty-file coverage remains synthetic-reader-only and is not claimed from
this writer. The writer emits UTF-8 without a byte-order mark, so BOM
handling is likewise not covered by writer output. Manifest dates and
content claims are as generated; no custody or copy-history claim is made.
Primary-schema provenance and the local signature-schema resolver are
shared with the [original classic reference record](../classic-reference/README.md).
