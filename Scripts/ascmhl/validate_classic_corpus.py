#!/usr/bin/env python3
"""Read-only classic MHL corpus checks using primary schemas/reference CLI.

Requires lxml. Schemas are caller-supplied private downloads, not vendored.
All corruption controls run in disposable copies. This does not test or enable
classic-MHL support in BitMatch's ASC-only saved-checksum reader.
"""
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

from lxml import etree
from create_classic_fixture import PAYLOADS, REFERENCE_COMMIT, require_reference

SCHEMA_SHA256 = 'c1adcd2591069249c88f2fc1fabac81363e7572b952834cce66f72a264e4c703'
SIGNATURE_SCHEMA_SHA256 = 'd102ad3df7664c307e0c2c776ba4a90513b1969974d8a940bae1a77f9f21e15d'
SIGNATURE_SCHEMA_URL = 'http://www.w3.org/TR/xmldsig-core/xmldsig-core-schema.xsd'


def snapshot(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


def main():
    if len(sys.argv) != 5:
        raise SystemExit('Usage: validate_classic_corpus.py REFERENCE_CHECKOUT MHL_CLI MHL_XSD XMLDSIG_XSD')
    reference, cli, schema_path, signature_path = (pathlib.Path(value).resolve() for value in sys.argv[1:])
    checks = []
    require_reference(reference)
    checks.append('pinned unmodified classic reference source')
    project = pathlib.Path(__file__).resolve().parents[2]
    corpus = project / 'Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures/EvidenceCompatibility/classic-reference'
    before = snapshot(corpus)
    if (corpus / 'REFERENCE-LICENSE.txt').read_bytes() != (reference / 'LICENSE').read_bytes():
        raise RuntimeError('Reference MIT notice changed')
    checks.append('reference MIT notice retained exactly')
    for path, expected in [(schema_path, SCHEMA_SHA256), (signature_path, SIGNATURE_SCHEMA_SHA256)]:
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Unexpected primary schema bytes: ' + path.name)
        checks.append('pinned primary schema: ' + path.name)

    class Resolver(etree.Resolver):
        def resolve(self, url, public_id, context):
            if url == SIGNATURE_SCHEMA_URL:
                return self.resolve_filename(str(signature_path), context)
            raise RuntimeError('Unexpected external schema dependency: ' + url)

    parser = etree.XMLParser(no_network=True, load_dtd=False, resolve_entities=False)
    parser.resolvers.add(Resolver())
    schema = etree.XMLSchema(etree.fromstring(schema_path.read_bytes(), parser))
    media = corpus / 'media'
    manifest = media / 'classic-md5-sha1.mhl'
    tree = etree.fromstring(manifest.read_bytes(), parser)
    schema.assertValid(tree)
    checks.append('original-format v1.1 inventory XSD')
    hashes = tree.findall('hash')
    if len(hashes) != 6 or {h.findtext('file') for h in hashes} != set(PAYLOADS):
        raise RuntimeError('Incomplete classic inventory')
    if {str(p.relative_to(media)) for p in media.rglob('*') if p.is_file()} != set(PAYLOADS) | {'classic-md5-sha1.mhl'}:
        raise RuntimeError('Unexpected classic fixture file')
    for name, expected in PAYLOADS.items():
        if (media / name).read_bytes() != expected:
            raise RuntimeError('Original synthetic payload changed')
    checks.append('exact original-media inventory coverage')
    for entry in hashes:
        name = entry.findtext('file')
        data = (media / name).read_bytes()
        digest_elements = [child for child in entry if child.tag in ('md5', 'sha1')]
        if len(digest_elements) != 1 or int(entry.findtext('size')) != len(data):
            raise RuntimeError('Invalid digest or size record')
        digest = digest_elements[0]
        if hashlib.new(digest.tag, data).hexdigest() != digest.text:
            raise RuntimeError('Independent digest mismatch')
        checks.append('Python ' + digest.tag.upper() + ' and size: ' + name)
    if sorted(child.tag for entry in hashes for child in entry if child.tag in ('md5', 'sha1')) != ['md5'] * 3 + ['sha1'] * 3:
        raise RuntimeError('Unexpected digest coverage')
    invalid = etree.fromstring(manifest.read_bytes(), parser)
    invalid.find('hash/md5').text = 'bad'
    if schema.validate(invalid):
        raise RuntimeError('Schema accepted a malformed digest')
    checks.append('primary schema rejects malformed digest')
    for kind in ['sha1-only', 'size-only']:
        variant = etree.fromstring(manifest.read_bytes(), parser)
        for entry in list(variant.findall('hash')):
            if kind == 'sha1-only' and entry.find('md5') is not None:
                variant.remove(entry)
            elif kind == 'size-only':
                for digest in list(entry):
                    if digest.tag in ('md5', 'sha1'):
                        digest.tag = 'null'
                        digest.text = None
        schema.assertValid(variant)
        checks.append('primary schema accepts unsupported-in-BitMatch ' + kind + ' variant')

    with tempfile.TemporaryDirectory(prefix='bitmatch-classic-corpus-') as temporary:
        for kind, expected in [('original', 0), ('changed-same-size', 16), ('missing', 3), ('truncated', 11)]:
            root = pathlib.Path(temporary) / kind
            shutil.copytree(media, root)
            record = root / manifest.name
            if kind == 'changed-same-size':
                file = root / 'sidecar.xml'
                file.write_bytes(b'X' + file.read_bytes()[1:])
            elif kind == 'missing':
                (root / 'sidecar.xml').unlink()
            elif kind == 'truncated':
                record.write_bytes(record.read_bytes()[:-30])
            result = subprocess.run([str(cli), 'verify', '-f', str(record)], capture_output=True)
            if result.returncode != expected:
                raise RuntimeError('Unexpected reference result for ' + kind + ': ' + str(result.returncode))
            checks.append('classic reference ' + kind + ': exit ' + str(expected))
    if snapshot(corpus) != before:
        raise RuntimeError('Validation changed the permanent corpus')
    checks.append('permanent corpus unchanged')
    print(json.dumps({'reference_commit': REFERENCE_COMMIT,
                      'scope': 'classic reference inventory/boundary corpus; no BitMatch classic support, hardware or history writes',
                      'passed': len(checks), 'checks': checks}, indent=2))


if __name__ == '__main__':
    main()
