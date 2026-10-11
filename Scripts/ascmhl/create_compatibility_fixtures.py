#!/usr/bin/env python3
"""Generate tiny, original media + ASC CLI fixtures. Run in the reference venv.

The output must not exist. No camera footage or third-party media is used.
The hostname is replaced before generation; no private production data is saved.
"""
import pathlib
import sys
from unittest.mock import patch
from click.testing import CliRunner
from ascmhl.cli.ascmhl import mhltool_cli

output = pathlib.Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=False)
runner = CliRunner()

def create(root, algorithm):
    with patch('platform.node', return_value='bitmatch-fixture-host'):
        result = runner.invoke(mhltool_cli, ['create', '-h', algorithm, str(root)])
    if result.exit_code:
        raise RuntimeError(result.output) from result.exception

for algorithm in ['md5', 'xxh64', 'c4']:
    root = output / algorithm
    (root / 'Camera A').mkdir(parents=True)
    (root / 'Camera A' / 'clip & café.txt').write_bytes(b'Original synthetic clip payload\n')
    (root / 'Camera A' / ' padded name.txt ').write_bytes(b'Whitespace is part of this filename\n')
    (root / 'empty.bin').write_bytes(b'')
    create(root, algorithm)
    if algorithm == 'md5':
        (root / 'added.txt').write_bytes(b'Added in the second generation\n')
        create(root, algorithm)
print('Created original ASC CLI fixtures:', output)
