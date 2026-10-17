#!/usr/bin/env python3
"""Generate tiny, original media + ASC CLI fixtures. Run in the reference venv.

The output must not exist. No camera footage or third-party media is used.
The hostname is replaced before generation; no private production data is saved.
"""
import pathlib
import argparse
from unittest.mock import patch
from click.testing import CliRunner
from ascmhl.cli.update import Updater

# Fixture creation is offline; suppress the CLI's automatic update request.
with patch.object(Updater, '_get_latest_version', return_value=None):
    from ascmhl.cli.ascmhl import mhltool_cli

datasets = ['md5', 'xxh64', 'c4', 'sha1', 'xxh128', 'xxh64-boundaries', 'md5-renames']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=pathlib.Path)
parser.add_argument('--datasets', nargs='+', choices=datasets, default=datasets)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
runner = CliRunner()

def create(root, algorithm, detect_renaming=False):
    arguments = ['create', '-h', algorithm]
    if detect_renaming:
        arguments.append('-dr')
    arguments.append(str(root))
    with patch('platform.node', return_value='bitmatch-fixture-host'):
        result = runner.invoke(mhltool_cli, arguments)
    if result.exit_code:
        raise RuntimeError(result.output) from result.exception

for dataset in args.datasets:
    algorithm = {'xxh64-boundaries': 'xxh64', 'md5-renames': 'md5'}.get(dataset, dataset)
    root = output / dataset
    if dataset == 'md5-renames':
        # Only the reference tool creates the two manifests and chain. Both
        # generations describe original, tiny synthetic media bytes.
        (root / 'Reel A').mkdir(parents=True)
        (root / 'Reel B').mkdir()
        (root / 'Reel A' / 'clip one.mov').write_bytes(b'Synthetic clip one\n')
        (root / 'Reel A' / 'sidecar.xml').write_bytes(b'<sidecar/>\n')
        (root / 'Reel B' / 'clip two.mov').write_bytes(b'Synthetic clip two\n')
        create(root, algorithm)
        (root / 'Reel A' / 'clip one.mov').rename(root / 'Reel A' / 'clip renamed.mov')
        (root / 'Reel B').rename(root / 'Reel C')
        create(root, algorithm, detect_renaming=True)
        continue
    if dataset == 'xxh64-boundaries':
        root.mkdir()
        for size in [0, 1, 31, 32, 33, 255, 256, 257, 1025]:
            (root / f'bytes-{size:04d}.bin').write_bytes(bytes(index % 251 for index in range(size)))
        create(root, algorithm)
        continue
    (root / 'Camera A').mkdir(parents=True)
    (root / 'Camera A' / 'clip & café.txt').write_bytes(b'Original synthetic clip payload\n')
    (root / 'Camera A' / ' padded name.txt ').write_bytes(b'Whitespace is part of this filename\n')
    (root / 'empty.bin').write_bytes(b'')
    create(root, algorithm)
    if algorithm == 'md5':
        (root / 'added.txt').write_bytes(b'Added in the second generation\n')
        create(root, algorithm)
print('Created original ASC CLI fixtures:', output)
