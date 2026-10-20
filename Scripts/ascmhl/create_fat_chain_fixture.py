#!/usr/bin/env python3
"""Create a public, privacy-sanitized derivative of an ASCMHLFixture sample.

Run in the pinned reference Python 3.11+ venv. Input must be a synthetic,
initial-only BitMatch FAT sample; output must not exist. Input is never edited.
The initial witness is rebuilt ONLY during fixture creation, before the official
ASC tool appends generation two. BitMatch's reader never reseals a history.
"""
import argparse
import hashlib
from xml.sax.saxutils import escape
import pathlib
import re
import subprocess
import sys
import unicodedata
from unittest.mock import patch

PIN = '0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('reference', type=pathlib.Path)
parser.add_argument('initial', type=pathlib.Path)
parser.add_argument('output', type=pathlib.Path)
args = parser.parse_args()
reference, source, output = args.reference.resolve(), args.initial.resolve(), args.output.resolve()
assert subprocess.check_output(['git', '-C', str(reference), 'rev-parse', 'HEAD'], text=True).strip() == PIN
assert not subprocess.check_output(['git', '-C', str(reference), 'status', '--porcelain', '--untracked-files=no'], text=True).strip()
sys.path.insert(0, str(reference))
from lxml import etree
from click.testing import CliRunner
from ascmhl.cli.update import Updater
with patch.object(Updater, '_get_latest_version', return_value=None):
    from ascmhl.cli.ascmhl import mhltool_cli
from ascmhl.hasher import C4

opening = b'BitMatch ASC MHL publication v1\nINCOMPLETE until a valid COMPLETE record follows. Keep the source.\n'
status = (source / 'ascmhl/BITMATCH_HISTORY_STATUS.txt').read_bytes()
assert status.startswith(opening)
word, name, size, digest, chain_size, chain_digest = status[len(opening):].decode().strip().split(' ')
assert word == 'COMPLETE' and re.fullmatch(r'0001_BitMatch_FAT_\d{4}-\d{2}-\d{2}_\d{6}Z\.mhl', name)
original = (source / 'ascmhl' / name).read_bytes()
original_chain = (source / 'ascmhl/ascmhl_chain.xml').read_bytes()
assert len(original) == int(size) and hashlib.sha256(original).hexdigest() == digest
assert len(original_chain) == int(chain_size) and hashlib.sha256(original_chain).hexdigest() == chain_digest
xml = etree.fromstring(original)
namespace = {'m': 'urn:ASC:MHL:v2.0'}
paths = xml.findall('m:hashes/m:hash/m:path', namespace)
assert len(paths) == 1
path = paths[0].text
assert unicodedata.normalize('NFC', path) == 'Camera A/clip & café.txt'
media = (source / path).read_bytes()
assert media == b'BitMatch interoperability test\n', 'Only original ASCMHLFixture media is allowed'
# Preserve writer formatting while replacing the one machine-specific field.
manifest, replacements = re.subn(rb'<hostname>[^<]+</hostname>', b'<hostname>bitmatch-fixture-host</hostname>', original)
assert replacements == 1
# exFAT presents the source filename decomposed on macOS, while Git may store
# it composed. Use ASCII only in this synthetic derivative so a fresh checkout
# is portable; production recorded paths and existing Unicode corpus stay intact.
portable_path = 'Camera A/clip.txt'
recorded = escape(path).encode()
assert manifest.count(recorded) == 1
manifest = manifest.replace(recorded, portable_path.encode())
hasher = C4(); hasher.update(manifest)
chain = (f'<?xml version="1.0" encoding="UTF-8"?>\n'
         f'<ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">\n'
         f'  <hashlist sequencenr="1"><path>{name}</path><c4>{hasher.string_digest()}</c4></hashlist>\n'
         f'</ascmhldirectory>\n').encode()
completion = opening + f'COMPLETE {name} {len(manifest)} {hashlib.sha256(manifest).hexdigest()} {len(chain)} {hashlib.sha256(chain).hexdigest()}\n'.encode()
output.mkdir(parents=True, exist_ok=False)
(output / portable_path).parent.mkdir(parents=True)
(output / portable_path).write_bytes(media)
(output / 'ascmhl').mkdir()
(output / 'ascmhl' / name).write_bytes(manifest)
(output / 'ascmhl/ascmhl_chain.xml').write_bytes(chain)
(output / 'ascmhl/BITMATCH_HISTORY_STATUS.txt').write_bytes(completion)
(output / 'added.txt').write_bytes(b'Added by the independent ASC tool after privacy sanitization\n')
with patch('platform.node', return_value='bitmatch-fixture-host'):
    result = CliRunner().invoke(mhltool_cli, ['create', '-h', 'md5', '-i', '._*', str(output)])
assert result.exit_code == 0, result.output
assert (output / 'ascmhl/BITMATCH_HISTORY_STATUS.txt').read_bytes() == completion
print('PASS privacy-sanitized derivative; official generation two preserves initial witness')
