#!/usr/bin/env python3
"""Validate the permanent ASC corpus on Linux or macOS, without Apple Swift.

Run with the pinned reference checkout installed in a Python 3.11+ venv:
    python Scripts/ascmhl/validate_corpus.py /path/to/ascmitc/mhl
This checks external-tool fixtures, not BitMatch's Swift implementation.
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

REFERENCE_COMMIT = '0fb61f1e4c7c1c3ff422449aa6f091ce0d3b7687'
DATASETS = ('md5', 'xxh64', 'c4', 'sha1', 'xxh128', 'xxh64-boundaries', 'md5-renames')


def snapshot(root):
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=pathlib.Path)
    args = parser.parse_args()
    reference = args.reference.resolve()
    commit = subprocess.check_output(['git', '-C', str(reference), 'rev-parse', 'HEAD'], text=True).strip()
    if commit != REFERENCE_COMMIT:
        raise RuntimeError(f'Expected ASC reference {REFERENCE_COMMIT}, found {commit}')
    # Load exactly the checked-out code; installed venv supplies its dependencies.
    if subprocess.check_output(['git', '-C', str(reference), 'status', '--porcelain', '--untracked-files=no'], text=True).strip():
        raise RuntimeError('Reference checkout has tracked modifications')
    sys.path.insert(0, str(reference))
    from click.testing import CliRunner
    from lxml import etree
    from ascmhl.cli.update import Updater
    # The reference CLI starts an online update check at import. Disable only
    # that check so validation needs no internet and never contacts a service.
    with patch.object(Updater, '_get_latest_version', return_value=None):
        from ascmhl.cli.ascmhl import mhltool_cli
        from ascmhl.cli.ascmhl_debug import mhldebugtool_cli
    from ascmhl.hasher import C4

    project = pathlib.Path(__file__).resolve().parents[2]
    corpus = project / 'Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/EvidenceCompatibility/reference'
    before = snapshot(corpus)
    checks = []
    runner = CliRunner()
    inventory_schema = etree.XMLSchema(etree.parse(str(reference / 'xsd/ASCMHL.xsd')))
    chain_schema = etree.XMLSchema(etree.parse(str(reference / 'xsd/ASCMHLDirectory__combined.xsd')))

    def invoke(label, cli, arguments, expected=0, required_output=()):
        result = runner.invoke(cli, arguments)
        if result.exit_code != expected:
            raise RuntimeError(f'{label}: expected exit {expected}, got {result.exit_code}\n{result.output}') from result.exception
        if any(text not in result.output for text in required_output):
            raise RuntimeError(f'{label}: missing expected diagnostic\n{result.output}')
        checks.append(label)

    with tempfile.TemporaryDirectory(prefix='bitmatch-reference-corpus-') as temporary:
        work = pathlib.Path(temporary)
        for dataset in DATASETS:
            root = work / dataset
            shutil.copytree(corpus / dataset, root)
            history = root / 'ascmhl'
            for manifest in sorted(history.glob('*.mhl')):
                inventory_schema.assertValid(etree.parse(str(manifest)))
                checks.append(f'{dataset}: inventory XSD {manifest.name}')
            chain = etree.parse(str(history / 'ascmhl_chain.xml'))
            chain_schema.assertValid(chain)
            checks.append(f'{dataset}: chain XSD')
            entries = chain.findall('{urn:ASC:MHL:DIRECTORY:v2.0}hashlist')
            if len(entries) != (2 if dataset in ('md5', 'md5-renames') else 1):
                raise RuntimeError(f'{dataset}: unexpected generation count')
            for entry in entries:
                name = entry.findtext('{urn:ASC:MHL:DIRECTORY:v2.0}path')
                hasher = C4()
                hasher.update((history / name).read_bytes())
                if hasher.string_digest() != entry.findtext('{urn:ASC:MHL:DIRECTORY:v2.0}c4'):
                    raise RuntimeError(f'{dataset}: invalid chain C4 for {name}')
            checks.append(f'{dataset}: generation count and chain C4')
            if dataset == 'md5-renames':
                namespace = '{urn:ASC:MHL:v2.0}'
                latest = etree.parse(str(sorted(history.glob('*.mhl'))[-1]))
                moved_files = {
                    (entry.findtext(namespace + 'path'), entry.findtext(namespace + 'previousPath'))
                    for entry in latest.findall('.//' + namespace + 'hash')
                    if entry.find(namespace + 'previousPath') is not None
                }
                moved_directories = {
                    (entry.findtext(namespace + 'path'), entry.findtext(namespace + 'previousPath'))
                    for entry in latest.findall('.//' + namespace + 'directoryhash')
                    if entry.find(namespace + 'previousPath') is not None
                }
                if moved_files != {
                    ('Reel A/clip renamed.mov', 'Reel A/clip one.mov'),
                    ('Reel C/clip two.mov', 'Reel B/clip two.mov'),
                } or moved_directories != {('Reel C', 'Reel B')}:
                    raise RuntimeError('md5-renames: missing file or directory rename lineage')
                checks.append('md5-renames: file and directory lineage')
            invoke(f'{dataset}: original bytes', mhldebugtool_cli, ['verify', '-v', str(root)])
            invoke(f'{dataset}: original paths', mhltool_cli, ['diff', str(root)])
            # Mutate only disposable copies, restoring a pristine case each time.
            for fault, expected in [('changed', 11), ('missing', 10), ('renamed', 21),
                                    ('extra', 21), ('manifest-modified', 31), ('manifest-missing', 33)]:
                damaged = work / f'{dataset}-{fault}'
                shutil.copytree(root, damaged)
                media = next(p for p in sorted(damaged.rglob('*'))
                             if p.is_file() and 'ascmhl' not in p.relative_to(damaged).parts and p.stat().st_size > 0)
                command = 'verify'
                cli = mhldebugtool_cli
                if fault == 'changed':
                    content = bytearray(media.read_bytes())
                    content[0] ^= 0xff
                    media.write_bytes(content)
                elif fault == 'missing':
                    media.unlink()
                elif fault == 'renamed':
                    media.rename(media.with_name('renamed.bin'))
                elif fault == 'extra':
                    (damaged / 'unrecorded.txt').write_bytes(b'new file\n')
                    command, cli = 'diff', mhltool_cli
                else:
                    manifest = sorted((damaged / 'ascmhl').glob('*.mhl'))[0]
                    if fault == 'manifest-missing':
                        manifest.unlink()
                    else:
                        manifest.write_bytes(manifest.read_bytes() + b'\n')
                required = ('found new file', 'missing file(s)') if fault == 'renamed' else ()
                invoke(f'{dataset}: rejects {fault}', cli, [command, str(damaged)], expected, required)
            if dataset == 'md5-renames':
                damaged = work / 'md5-renames-directory-moved-again'
                shutil.copytree(root, damaged)
                (damaged / 'Reel C').rename(damaged / 'Reel D')
                invoke('md5-renames: rejects unrecorded directory move', mhltool_cli,
                       ['diff', str(damaged)], 10, ('found new file', 'missing file(s)'))

    if snapshot(corpus) != before:
        raise RuntimeError('Validation modified the permanent corpus')
    checks.append('permanent corpus unchanged')
    print(json.dumps({'reference_commit': commit, 'scope': 'external ASC corpus only; no Swift or hardware tests',
                      'passed': len(checks), 'checks': checks}, indent=2))


if __name__ == '__main__':
    main()
