# Independent Offloader ASC MHL fixture

The files in `media/` were generated with the MIT-licensed
[Offloader](https://github.com/owenpkent/offloader) writer at commit
`e01a0eb034fd0056ae4a3385b187c70ba96d2a49`. Its license is retained here.
The media is synthetic and includes an empty file and a non-ASCII filename.

The writer's `write_manifest` function was called directly with synthetic job
and destination entries, MD5 digests calculated with Python `hashlib`, and
fixed dates of 2026-01-01 UTC. Its hostname provider returned `synthetic`.
Directory hashes and ignore patterns were disabled for this inventory. The
writer generated both the manifest and C4 chain, and neither was edited after
generation. The writer was invoked under Python 3.9 although its project
declares Python 3.10 or newer.

SHA-256 pins:

- `media/ascmhl/0001_media_2026-01-01_000000Z.mhl` — `46a9b6463a131c7757b77cd8fc040f3d821d8f2cebb92a0c26180d10d3b3ff2d`
- `media/ascmhl/ascmhl_chain.xml` — `78eb93edba2843a4ddaf7be6b964e875477cb1224434d82807cf96b38a0e9939`
- `media/empty.mov` — `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `media/café clip.txt` — `ece6540bbdc38058ec2c1dca3fd0ea64b03512cff800e9ad2c953ba9bdbfa568`

The BitMatch reader check, writer verifier and external schema validation have
not yet been run. The fixture covers content and chain records, not directory
hashes, lineage or authenticity.
