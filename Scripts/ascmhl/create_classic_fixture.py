#!/usr/bin/env python3
"""Generate an original-media classic MHL fixture with a pinned reference CLI.

No reference source is copied into BitMatch. Output must not exist. The three
personal creator fields are replaced; inventory paths/digests remain untouched.
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REFERENCE_COMMIT = '34f06f22ae965d12e49590adc301373d5ce611ff'
PAYLOADS = {
    'Camera A/clip & cafe.txt': b'Classic MHL independent fixture\n',
    'support file.txt': b'Whitespace is part of this filename.\n',
    'sidecar.xml': b'<clip>synthetic</clip>\n',
}


def require_reference(reference):
    revision = subprocess.check_output(['git', '-C', str(reference), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REFERENCE_COMMIT:
        raise RuntimeError('Wrong classic MHL reference revision')
    if subprocess.check_output(['git', '-C', str(reference), 'status', '--porcelain', '--untracked-files=no']):
        raise RuntimeError('Classic MHL reference source was modified')


def main():
    if len(sys.argv) != 4:
        raise SystemExit('Usage: create_classic_fixture.py REFERENCE_CHECKOUT MHL_CLI NEW_OUTPUT')
    reference, cli, output = (pathlib.Path(value).resolve() for value in sys.argv[1:])
    require_reference(reference)
    if output.exists():
        raise RuntimeError('Output must not exist')
    # Raw creator data stays in disposable scratch even if generation fails.
    with tempfile.TemporaryDirectory(prefix='bitmatch-classic-generate-') as temporary:
        prepared = pathlib.Path(temporary) / 'prepared'
        media = prepared / 'media'
        media.mkdir(parents=True)
        for name, data in PAYLOADS.items():
            file = media / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
        hashes = subprocess.check_output([str(cli), 'hash', '-t', 'md5', 'sha1', str(media)])
        subprocess.run([str(cli), 'file', '-s', '-o', str(media)], input=hashes, check=True, capture_output=True)
        manifests = list(media.glob('*.mhl'))
        if len(manifests) != 1:
            raise RuntimeError('Expected exactly one classic inventory')
        generated = manifests[0]
        text = generated.read_text(encoding='utf-8')
        for tag, value in [('name', 'BitMatch fixture'), ('username', 'fixture'), ('hostname', 'bitmatch-fixture-host')]:
            text, count = re.subn(r'<' + tag + r'>.*?</' + tag + r'>', '<' + tag + '>' + value + '</' + tag + '>', text)
            if count != 1:
                raise RuntimeError('Expected exactly one creator field: ' + tag)
        generated.write_text(text, encoding='utf-8')
        generated.rename(media / 'classic-md5-sha1.mhl')
        subprocess.run([str(cli), 'verify', '-f', str(media / 'classic-md5-sha1.mhl')], check=True, capture_output=True)
        (prepared / 'REFERENCE-LICENSE.txt').write_bytes((reference / 'LICENSE').read_bytes())
        shutil.copytree(prepared, output)
    print('PASS: 3 original files, 6 digest records; sanitized reference output verified')


if __name__ == '__main__':
    main()
