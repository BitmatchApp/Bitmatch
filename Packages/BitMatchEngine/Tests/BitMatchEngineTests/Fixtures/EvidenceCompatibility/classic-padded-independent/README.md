# Independent classic MHL padded-path fixture

This sanitized classic MHL 1.1 fixture was generated with `mhl-suite` 1.4.0 at upstream Git revision `9304aef7139403e8188d48ac2c653594ad589745` from `https://github.com/lucuma13/mhl-suite`. The upstream implementation is MIT licensed; its exact notice is retained in `UPSTREAM-MIT-LICENSE.txt` (SHA-256 `ad1c3e1134c9b2d0827268ce65540dd2d6ed57ae2978b6e939a663b134f0f821`). The separately authored Python/lxml writer is independent of the other fixture generators in this corpus.

The media is synthetic text, exactly 30 bytes: `synthetic padded-name payload` followed by LF. Its expected MD5 is `300d5c3d929f8697d3f916a449a51ead` and SHA-1 is `79da2a02fa18fccf3ae906fb0775119b14ebbd32`. The only filename is literally ` padded name.txt `, including one leading and one trailing ASCII space. The manifest preserves those spaces. The committed sanitized manifest SHA-256 is `3c4cf6a98e42b5b5a7f64af1c001a67e76315bf0fd2ceadf9f1e22fcf78d7feb`; its media SHA-256 is `eb4056c1426dbba6874fd07c8bced05b82451eb71adcc68f22c843b7c2199b4a`.

Generation used Python 3.12.15 and the hash-pinned runtime closure from the upstream `uv.lock` (including lxml 6.1.1); the pinned source was installed offline without dependencies after a hash-checked build-backend install. The resulting output passed the upstream verifier and schema command. It also validates against the primary classic MHL 1.1 XSD, SHA-256 `c1adcd2591069249c88f2fc1fabac81363e7572b952834cce66f72a264e4c703`.

Only creator username, hostname, and environment log were replaced with synthetic values. The original raw output remains private. The sanitized derivative retains the generated file path, size, date and digest claims. This fixture exercises content-digest and path parsing; it does not authenticate history, custody, or creator statements. The upstream classic schema requires positive file sizes and the writer does not emit empty-file records, so empty-file coverage is not claimed here.

## Reproduction record

The pinned `pyproject.toml` SHA-256 is `0323684799faf0236992bc5fb03e4784a697e42996350cc989bff154d68d2a75`; `uv.lock` is `9c15e47468d65692efbba17feed66f568ca51a8f0b23d4776a9bc0e2d9b1f4d9`. Runtime versions came from that lock. The generated pip requirements file, containing those locked archive hashes, had SHA-256 `0d640b335b347dc4b724d85928aaae3f21600ffdc5b1befd8800bfd1fd3b4824`.

The separate build backend used Hatchling 1.32.4, pluggy 1.6.0, tomlkit 0.15.2 and trove-classifiers 2026.9.21.13, with the already locked packaging/pathspec versions. Its hash-checked requirements receipt is `2b75731359f6167bfb7786b040a9ec95fd5cba50379bddfd704b98b16a061b0d`. No backend or dependency is part of the fixture or BitMatch runtime.

Create a disposable `MEDIA` directory containing only the exact payload and padded filename above. In the isolated installed environment, with the optional updater disabled:

```sh
NO_UPDATE_CHECK=1 python -m mhl_suite.cli.simple_mhl seal MEDIA -a md5,sha1
NO_UPDATE_CHECK=1 simple-mhl verify padded-independent.mhl -a md5,sha1
NO_UPDATE_CHECK=1 simple-mhl xsd-schema-check padded-independent.mhl
```

The last two commands apply to the sanitized manifest beside a copy of its payload. The raw generated manifest's SHA-256 was `71669b5bfeb65d0b9be268e89210d86d0e5349c8710dc47de20012af3412c806`. Sanitization replaced only `creatorinfo/username`, `creatorinfo/hostname` and `creatorinfo/log`, then serialized the XML; content claims stayed unchanged. Generation times differ on a new run, so whole-manifest byte reproducibility is not claimed. Primary schema provenance and the local signature-schema resolver are shared with the [original classic reference record](../classic-reference/README.md).
