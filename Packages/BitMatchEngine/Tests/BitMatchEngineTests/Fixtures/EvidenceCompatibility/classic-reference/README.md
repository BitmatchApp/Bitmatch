# Original-format MHL reference fixture

This tiny corpus is an independently generated **classic MHL 1.1** inventory.
It does not add classic-MHL support to BitMatch. Check currently discovers ASC
inventories under `ascmhl/`; standalone classic inventories are not discovered,
and classic records inside that evidence tree are explicitly unsupported.

The three media files are original synthetic text, under BitMatch's MIT license.
The inventory came from the original-format [reference CLI](https://github.com/pomfort/mhl-tool)
at revision `34f06f22ae965d12e49590adc301373d5ce611ff`, built from unchanged source.
Its exact MIT notice is retained in `REFERENCE-LICENSE.txt`. Only the generated
`name`, `username` and `hostname` creator fields were replaced with synthetic
values. The manifest was renamed to `classic-md5-sha1.mhl`. Paths, file sizes,
digest values and date fields are unchanged. This is a sanitized derivative,
not a byte-for-byte capture of the raw command output.

The [original specification](https://mediahashlist.org/mhl-specification/) links
the [v1.1 schema](https://mediahashlist.org/download/MediaHashList_v1_1.xsd).
Its SHA-256 is `c1adcd2591069249c88f2fc1fabac81363e7572b952834cce66f72a264e4c703`.
The imported [W3C signature schema](https://www.w3.org/TR/xmldsig-core/xmldsig-core-schema.xsd)
has SHA-256 `d102ad3df7664c307e0c2c776ba4a90513b1969974d8a940bae1a77f9f21e15d`.
These schema files are downloaded privately for validation, not redistributed.

## Generation

Build the pinned reference checkout outside this repository. On this Mac, the
unmodified 34 C sources built with Apple clang, the SDK's libxml2, system iconv
and the existing Homebrew OpenSSL 3 installation:

```sh
sdk=$(xcrun --show-sdk-path)
xcrun clang -O2 -D_GNU_SOURCE -Wno-deprecated-declarations \
  -I"$reference/src" -I"$sdk/usr/include/libxml2" \
  -I/opt/homebrew/opt/openssl@3/include \
  "$reference"/src/*/*.c "$reference"/src/generics/filesystem_handlers/*.c \
  "$reference"/src/mhl_verify/mhl_verification/*.c \
  -L/opt/homebrew/opt/openssl@3/lib -lcrypto -lxml2 -liconv -o "$mhl_cli"
python3 Scripts/ascmhl/create_classic_fixture.py "$reference" "$mhl_cli" /tmp/new-classic-fixture
```

The generator uses `mhl hash -t md5 sha1 MEDIA`, then passes those lines to
`mhl file -s -o MEDIA`. It sanitizes in disposable scratch and requires
`mhl verify -f MANIFEST` to succeed before copying the derivative to a new output
directory. Regeneration retains the tool's current dates, so it need not produce
byte-identical metadata. No application or reference implementation code is
copied into BitMatch's engine.

## Validation and limits

Run with Python `lxml`, the pinned checkout/CLI and the two downloaded schemas:

```sh
python3 Scripts/ascmhl/validate_classic_corpus.py \
  "$reference" "$mhl_cli" "$classic_xsd" "$xmldsig_xsd"
```

The runner validates the schema and exact original payloads, independently
checks all six digest/size records with Python MD5/SHA-1, and verifies the media
with the reference CLI. There are three paths and six records: that CLI emits a
separate `<hash>` entry for each algorithm on each path. Same-size corruption
must return 16, missing media 3 and truncated XML 11. All negative controls use
disposable copies; permanent fixture bytes must stay unchanged.

Swift tests independently check all six digests with CryptoKit and assert the
current unsupported/not-found boundary, including a valid ASC neighbour and
disposable SHA-1-only, size-only, future-version, truncated and traversal cases.
Generic hashes do not establish a BitMatch verification tier or safe-to-erase
verdict. This corpus does not cover classic history references, signatures,
XXHash encoding variants, empty files or every filename encoding. The older
reference CLI trimmed leading/trailing filename whitespace in an exploratory
sample; that sample is excluded from the passing corpus. Existing ASC fixtures
cover whitespace and Unicode independently. No history is extended or rewritten.
