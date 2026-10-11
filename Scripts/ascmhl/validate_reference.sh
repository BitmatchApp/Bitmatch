#!/bin/bash
# Usage: validate_reference.sh /path/to/ascmitc/mhl /path/to/venv/bin
# Requires the official ASC CLI installed in that environment and Apple Swift.
set -euo pipefail
reference="${1:?Pass a checkout of https://github.com/ascmitc/mhl}"
cli="${2:?Pass the directory containing ascmhl and ascmhl-debug}"
project="$(cd "$(dirname "$0")/../.." && pwd)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/bitmatch-ascmhl-check.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT
swift run --package-path "$project/Packages/BitMatchEngine" --build-system native --jobs 4 ASCMHLFixture "$workspace/media"
"$cli/ascmhl-debug" xsd-schema-check -xsd "$reference/xsd/ASCMHL.xsd" "$workspace/media/ascmhl/"*.mhl
"$cli/ascmhl-debug" xsd-schema-check -df -xsd "$reference/xsd/ASCMHLDirectory__combined.xsd" "$workspace/media/ascmhl/ascmhl_chain.xml"
"$cli/ascmhl-debug" verify -v "$workspace/media"
"$cli/ascmhl" diff "$workspace/media"
"$cli/ascmhl" create -h md5 "$workspace/media"
"$cli/ascmhl-debug" verify -v "$workspace/media"
# Verify the chain against the official C4 implementation, including the appended generation.
"$cli/python" - "$workspace/media" <<'PY'
import pathlib, sys
from lxml import etree
from ascmhl.hasher import C4
root = pathlib.Path(sys.argv[1]) / 'ascmhl'
chain = etree.parse(str(root / 'ascmhl_chain.xml'))
ns = {'m': 'urn:ASC:MHL:DIRECTORY:v2.0'}
entries = chain.findall('m:hashlist', ns)
assert len(entries) == 2
for entry in entries:
    name = entry.findtext('m:path', namespaces=ns)
    hasher = C4()
    hasher.update((root / name).read_bytes())
    assert hasher.string_digest() == entry.findtext('m:c4', namespaces=ns)
print('PASS: official schemas, byte verification, chain C4, and next-generation interoperability')
PY
# Permanent external-tool fixtures: validate without rewriting their histories.
corpus="$project/Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/EvidenceCompatibility/reference"
for algorithm in md5 xxh64 c4; do
    fixture="$corpus/$algorithm"
    for manifest in "$fixture/ascmhl/"*.mhl; do
        "$cli/ascmhl-debug" xsd-schema-check -xsd "$reference/xsd/ASCMHL.xsd" "$manifest"
    done
    "$cli/ascmhl-debug" xsd-schema-check -df -xsd "$reference/xsd/ASCMHLDirectory__combined.xsd" "$fixture/ascmhl/ascmhl_chain.xml"
    "$cli/ascmhl-debug" verify -v "$fixture"
    "$cli/ascmhl" diff "$fixture"
done
echo 'PASS: permanent MD5, XXH64 and C4 corpus validated independently'

# Corruption must be detected by the independent reference verifier.
printf 'corrupted' > "$workspace/media/Camera A/clip & café.txt"
if "$cli/ascmhl-debug" verify "$workspace/media"; then
    echo 'FAIL: reference verifier accepted changed media' >&2
    exit 1
fi
echo 'PASS: reference verifier rejects modified media'
