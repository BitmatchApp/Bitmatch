#!/usr/bin/env python3
"""Independently validate BitMatch FAT-v1 publication + official ASC extension.

Requires the pinned ASC checkout installed in the active Python 3.11+ venv.
All negative controls run on disposable copies; original corpus is read-only.
"""
import argparse
import hashlib
import pathlib
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

PIN = '0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference', type=pathlib.Path)
args = parser.parse_args()
reference = args.reference.resolve()
assert subprocess.check_output(['git', '-C', str(reference), 'rev-parse', 'HEAD'], text=True).strip() == PIN
assert not subprocess.check_output(['git', '-C', str(reference), 'status', '--porcelain', '--untracked-files=no'], text=True).strip()
sys.path.insert(0, str(reference))
from lxml import etree
from click.testing import CliRunner
from ascmhl.cli.update import Updater
with patch.object(Updater, '_get_latest_version', return_value=None):
    from ascmhl.cli.ascmhl import mhltool_cli
    from ascmhl.cli.ascmhl_debug import mhldebugtool_cli
from ascmhl.hasher import C4

source = pathlib.Path(__file__).resolve().parents[2] / 'Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/EvidenceCompatibility/reference/bitmatch-fat-extended'
def snapshot(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
before = snapshot(source)
runner = CliRunner()
with tempfile.TemporaryDirectory(prefix='bitmatch-fat-chain-reference-') as temporary:
    root = pathlib.Path(temporary) / 'media'
    shutil.copytree(source, root)
    history = root / 'ascmhl'
    assert (root / 'Camera A/clip.txt').is_file()
    assert all(str(p.relative_to(root)).isascii() for p in root.rglob('*')), 'Synthetic derivative filenames must remain Git-portable ASCII'
    chain = etree.parse(str(history / 'ascmhl_chain.xml'))
    etree.XMLSchema(etree.parse(str(reference / 'xsd/ASCMHLDirectory__combined.xsd'))).assertValid(chain)
    schema = etree.XMLSchema(etree.parse(str(reference / 'xsd/ASCMHL.xsd')))
    entries = chain.findall('{urn:ASC:MHL:DIRECTORY:v2.0}hashlist')
    assert len(entries) == 2
    for index, entry in enumerate(entries, 1):
        assert int(entry.attrib['sequencenr']) == index
        name = entry.findtext('{urn:ASC:MHL:DIRECTORY:v2.0}path')
        schema.assertValid(etree.parse(str(history / name)))
        hasher = C4(); hasher.update((history / name).read_bytes())
        assert hasher.string_digest() == entry.findtext('{urn:ASC:MHL:DIRECTORY:v2.0}c4')
    print('PASS schemas, two ordered generations and reference C4')
    status = (history / 'BITMATCH_HISTORY_STATUS.txt').read_bytes()
    opening = b'BitMatch ASC MHL publication v1\nINCOMPLETE until a valid COMPLETE record follows. Keep the source.\n'
    assert status.startswith(opening)
    word, name, size, digest, chain_size, chain_digest = status[len(opening):].decode().strip().split(' ')
    assert word == 'COMPLETE'
    manifest = (history / name).read_bytes()
    assert len(manifest) == int(size) and hashlib.sha256(manifest).hexdigest() == digest
    c4 = C4(); c4.update(manifest)
    original_chain = (f'<?xml version="1.0" encoding="UTF-8"?>\n'
                      f'<ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">\n'
                      f'  <hashlist sequencenr="1"><path>{name}</path><c4>{c4.string_digest()}</c4></hashlist>\n'
                      f'</ascmhldirectory>\n').encode()
    assert len(original_chain) == int(chain_size) and hashlib.sha256(original_chain).hexdigest() == chain_digest
    assert entries[0].findtext('{urn:ASC:MHL:DIRECTORY:v2.0}path') == name
    print('PASS immutable original FAT-v1 completion witness')
    for label, cli, arguments in [('media verification', mhldebugtool_cli, ['verify', '-v', str(root)]),
                                  ('inventory diff', mhltool_cli, ['diff', str(root)])]:
        result = runner.invoke(cli, arguments)
        assert result.exit_code == 0, result.output
        print('PASS official ' + label)
    second = entries[1].findtext('{urn:ASC:MHL:DIRECTORY:v2.0}path')
    second_bytes = (history / second).read_bytes()
    (history / second).write_bytes(second_bytes + b'changed')
    result = runner.invoke(mhltool_cli, ['diff', str(root)])
    assert result.exit_code != 0, 'Reference accepted a modified inventory'
    print('PASS reference rejects modified appended inventory')
assert snapshot(source) == before
print('PASS original fixture untouched; pinned reference ' + PIN)
