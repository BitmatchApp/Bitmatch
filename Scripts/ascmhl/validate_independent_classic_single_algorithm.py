#!/usr/bin/env python3
"""Strictly validate the committed independent classic-MHL single-algorithm fixtures offline.

Each variant directory holds writer-generated output from the pinned
mhl-suite revision beside byte-identical synthetic media. The md5-only and
sha1-only manifests are supported BitMatch reader input; the size-only and
xxh64 manifests pin the exact unsupported record shapes that must fail closed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import xml.etree.ElementTree as ET


FIXTURE = (Path(__file__).resolve().parents[2] / "Packages/BitMatchEngine/Tests/BitMatchEngineTests/Fixtures"
           / "EvidenceCompatibility/classic-single-algorithm")
LICENSE_NAME = "UPSTREAM-MIT-LICENSE.txt"
LICENSE_SHA256 = "ad1c3e1134c9b2d0827268ce65540dd2d6ed57ae2978b6e939a663b134f0f821"
PRIMARY_XSD_SHA256 = "c1adcd2591069249c88f2fc1fabac81363e7572b952834cce66f72a264e4c703"
SIGNATURE_XSD_SHA256 = "d102ad3df7664c307e0c2c776ba4a90513b1969974d8a940bae1a77f9f21e15d"
SIGNATURE_XSD_URL = "http://www.w3.org/TR/xmldsig-core/xmldsig-core-schema.xsd"
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_SMALL_FILE_BYTES = 1024 * 1024
MAX_FIXTURE_FILES = 32
MAX_INVENTORY_FILES = 16
MAX_TREE_ENTRIES = 128
MAX_DIRECTORY_DEPTH = 8
EXPECTED_MEDIA = {
    "clip one.mov": {"size": 34, "sha256": "83e51127d79df2add3318c3f0d95e256b1df51b2ac140c34f31bf7742d3d14fd",
                     "md5": "bdb6d9e8bf3290710359905a3a4b0606",
                     "sha1": "a4851f5a8f75a4c5225f726f3194ea6ce6e50e5b",
                     "xxhash64be": "0f48ffc52e98319c"},
    "Reel A/two.mov": {"size": 36, "sha256": "194292fb3512224186277938d6b57777688c5d2abf7b631cf51623442ae18a0e",
                       "md5": "d5e836a4b7fbcfc4e08b0c8c379c94b2",
                       "sha1": "0e6219cd57f714cb4075bf786f18e82072c91a0b",
                       "xxhash64be": "fc8f3359f1d82da9"},
    "café test.mov": {"size": 33, "sha256": "d7ab03d4191a9be029d0e8965dfab5a6ee98976ef1005ba5250bf2ddb83dec0a",
                     "md5": "35136dce1d8f244f7c7328a199de1b89",
                     "sha1": "65df625d123c324bb8f46804d96edee17b6f4e58",
                     "xxhash64be": "1a8f434ffe4e3e57"},
}
VARIANTS = {
    # variant directory: (manifest name, manifest SHA-256, digest element or None)
    "md5-only": ("md5-only.mhl", "09962ebb488b7ef762c0384dc792fd41aea6423fd971243d28ddb1f4163b5286", "md5"),
    "sha1-only": ("sha1-only.mhl", "c8c86ed1c5f07f98b4ce03ebf7c9320e81c1ce82ec51d23f6f369d8d8d005526", "sha1"),
    "size-only": ("size-only.mhl", "054b35d387989d84daea076e65bc8ef55659b2a0b12fc3aa99fafe695f27b492", None),
    "xxh64": ("xxh64.mhl", "043bb99d1035bfc47f5c7888e21c78bd67d0dfdfdeb266b466e0bffe79d7ef89", "xxhash64be"),
}


class FixtureValidationError(ValueError):
    """The fixture or a manifest presented to the validator is invalid."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def snapshot(root: Path) -> dict[str, str]:
    """Hash the small regular files in this fixture without following links."""
    if root.is_symlink() or not root.is_dir():
        raise FixtureValidationError(f"fixture root is not a real directory: {root}")
    result: dict[str, str] = {}
    entries = 0
    pending = [(root, 0)]
    while pending:
        directory, depth = pending.pop()
        for path in directory.iterdir():
            entries += 1
            if entries > MAX_TREE_ENTRIES:
                raise FixtureValidationError("fixture exceeds the 128-entry traversal limit")
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise FixtureValidationError(f"fixture contains a symbolic link: {relative!r}")
            if stat.S_ISREG(mode):
                if len(result) >= MAX_FIXTURE_FILES:
                    raise FixtureValidationError("fixture exceeds the 32-file limit")
                if path.lstat().st_size > MAX_SMALL_FILE_BYTES:
                    raise FixtureValidationError(f"fixture file exceeds the 1 MiB limit: {relative!r}")
                result[relative] = sha256(_read_small_file(path))
            elif stat.S_ISDIR(mode):
                if depth >= MAX_DIRECTORY_DEPTH:
                    raise FixtureValidationError("fixture exceeds the 8-directory-depth limit")
                pending.append((path, depth + 1))
            else:
                raise FixtureValidationError(f"fixture contains a non-regular file: {relative!r}")
    return result


def _read_small_file(path: Path) -> bytes:
    """Read a fixture-sized file with a hard byte cap."""
    with path.open("rb") as source:
        data = source.read(MAX_SMALL_FILE_BYTES + 1)
    if len(data) > MAX_SMALL_FILE_BYTES:
        raise FixtureValidationError(f"file exceeds the 1 MiB limit: {path.name!r}")
    return data


def _text(parent: ET.Element, tag: str) -> str:
    matches = parent.findall(tag)
    if len(matches) != 1 or matches[0].text is None or len(matches[0]) != 0 or matches[0].attrib:
        raise FixtureValidationError(f"expected exactly one nonempty <{tag}> element")
    if matches[0].tail is not None and matches[0].tail.strip():
        raise FixtureValidationError(f"unexpected text after <{tag}> element")
    return matches[0].text


def _element_only(parent: ET.Element, expected_tags: list[str], allowed_attributes=None) -> None:
    if parent.attrib != (allowed_attributes or {}) or (parent.text is not None and parent.text.strip()):
        raise FixtureValidationError("unexpected attributes or text in element-only XML container")
    if [child.tag for child in parent] != expected_tags:
        raise FixtureValidationError("unexpected child elements in XML container")
    if any(child.tail is not None and child.tail.strip() for child in parent):
        raise FixtureValidationError("unexpected text between XML child elements")


def _check_path(name: str) -> None:
    if (not name or "\x00" in name or "\\" in name or name.startswith("/")
            or re.match(r"^[A-Za-z]:", name)):
        raise FixtureValidationError("unsafe manifest path")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts) or PurePosixPath(name).is_absolute():
        raise FixtureValidationError("unsafe manifest path")
    if len(parts) - 1 > MAX_DIRECTORY_DEPTH:
        raise FixtureValidationError("manifest path exceeds the 8-directory-depth limit")


def parse_variant_manifest(data: bytes, digest_tag: str | None) -> list[dict[str, object]]:
    """Parse one writer-generated manifest, enforcing its exact record shape."""
    if len(data) > MAX_MANIFEST_BYTES:
        raise FixtureValidationError("manifest exceeds the 1 MiB validation limit")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise FixtureValidationError("manifest is not strict UTF-8") from error
    if "\x00" in text:
        raise FixtureValidationError("manifest contains a NUL byte")
    declaration = re.match(r"\s*<\?xml\s+[^?]*\?>", text, flags=re.IGNORECASE)
    if declaration is None or not re.search(r"\bencoding\s*=\s*(['\"])UTF-8\1", declaration.group(0), re.IGNORECASE):
        raise FixtureValidationError("manifest must declare UTF-8 XML encoding")
    if re.search(r"<!\s*(?:DOCTYPE|ENTITY)\b", text, flags=re.IGNORECASE):
        raise FixtureValidationError("DTD and entity declarations are not supported")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as error:
        raise FixtureValidationError(f"malformed XML: {error}") from error
    if root.tag != "hashlist" or root.attrib != {"version": "1.1"}:
        raise FixtureValidationError("expected an unnamespaced classic MHL 1.1 hashlist")
    children = list(root)
    if not children or children[0].tag != "creatorinfo":
        raise FixtureValidationError("expected creatorinfo before hash records")
    _element_only(children[0], ["username", "hostname", "tool", "startdate", "finishdate", "log"])
    records = children[1:]
    if not records or any(record.tag != "hash" or record.attrib for record in records):
        raise FixtureValidationError("expected only unadorned hash records after creatorinfo")
    parsed = []
    for record in records:
        tags = [child.tag for child in record]
        if digest_tag is None:
            if tags != ["file", "size", "lastmodificationdate", "null", "hashdate"]:
                raise FixtureValidationError(f"size-only record has unexpected shape: {tags!r}")
            nulls = record.findall("null")
            if len(nulls) != 1 or nulls[0].attrib or list(nulls[0]):
                raise FixtureValidationError("expected exactly one empty <null> element")
            if nulls[0].text is not None and nulls[0].text.strip():
                raise FixtureValidationError("<null> element must carry no digest text")
        else:
            if tags != ["file", "size", "lastmodificationdate", digest_tag, "hashdate"]:
                raise FixtureValidationError(f"record has unexpected shape: {tags!r}")
        _element_only(record, tags)
        _text(record, "hashdate")
        _text(record, "lastmodificationdate")
        name = _text(record, "file")  # Preserve significant spaces and non-ASCII names.
        _check_path(name)
        size_text = _text(record, "size")
        if not re.fullmatch(r"[0-9]+", size_text):
            raise FixtureValidationError("size must be a decimal integer")
        entry: dict[str, object] = {"path": name, "size": int(size_text)}
        if digest_tag is not None:
            value = _text(record, digest_tag)
            pattern = {"md5": r"[0-9a-f]{32}", "sha1": r"[0-9a-f]{40}",
                       "xxhash64be": r"[0-9a-f]{16}"}[digest_tag]
            if not re.fullmatch(pattern, value):
                raise FixtureValidationError(f"invalid lowercase {digest_tag} digest")
            entry[digest_tag] = value
        parsed.append(entry)
    return parsed


def verify_variant(variant: str, manifest_name: str, digest_tag: str | None) -> list[dict[str, object]]:
    """Check one variant's manifest against its relative media files."""
    directory = FIXTURE / variant
    if directory.is_symlink() or not directory.is_dir():
        raise FixtureValidationError(f"variant is not a real directory: {variant!r}")
    data = _read_small_file(directory / manifest_name)
    if sha256(data) != VARIANTS[variant][1]:
        raise FixtureValidationError(f"sanitized manifest hash mismatch: {variant}/{manifest_name}")
    records = parse_variant_manifest(data, digest_tag)
    if len(records) > MAX_INVENTORY_FILES:
        raise FixtureValidationError(f"inventory exceeds the 16-file limit: {variant!r}")
    seen: set[str] = set()
    for record in records:
        relative = str(record["path"])
        if relative in seen:
            raise FixtureValidationError(f"duplicate path: {relative!r}")
        seen.add(relative)
        expected = EXPECTED_MEDIA.get(relative)
        if expected is None:
            raise FixtureValidationError(f"unexpected recorded path: {relative!r}")
        if record["size"] != expected["size"]:
            raise FixtureValidationError(f"size mismatch for {relative!r}")
        media = directory / PurePosixPath(relative)
        if media.is_symlink() or not media.is_file():
            raise FixtureValidationError(f"media is not a real file: {relative!r}")
        content = _read_small_file(media)
        if sha256(content) != expected["sha256"]:
            raise FixtureValidationError(f"media SHA-256 mismatch for {relative!r}")
        if digest_tag in ("md5", "sha1"):
            if hashlib.new(digest_tag, content).hexdigest() != record[digest_tag]:
                raise FixtureValidationError(f"{digest_tag.upper()} mismatch for {relative!r}")
        if digest_tag == "xxhash64be":
            try:
                import xxhash
            except ImportError as error:
                raise FixtureValidationError("xxhash is required to check xxh64 records") from error
            if xxhash.xxh64(content).hexdigest() != record[digest_tag]:
                raise FixtureValidationError(f"XXH64 mismatch for {relative!r}")
        if digest_tag is not None and record[digest_tag] != expected[digest_tag]:
            raise FixtureValidationError(f"manifest claim differs from the pinned record for {relative!r}")
    if seen != set(EXPECTED_MEDIA):
        raise FixtureValidationError(f"inventory coverage mismatch: {sorted(seen)!r}")
    actual: set[str] = set()
    entries = 0
    pending = [(directory, 0)]
    while pending:
        current, depth = pending.pop()
        for path in current.iterdir():
            entries += 1
            if entries > MAX_TREE_ENTRIES:
                raise FixtureValidationError("variant exceeds the 128-entry traversal limit")
            mode = path.lstat().st_mode
            relative = path.relative_to(directory).as_posix()
            if stat.S_ISLNK(mode):
                raise FixtureValidationError(f"variant contains a symbolic link: {relative!r}")
            if stat.S_ISREG(mode):
                if relative != manifest_name:
                    actual.add(relative)
            elif stat.S_ISDIR(mode):
                if depth >= MAX_DIRECTORY_DEPTH:
                    raise FixtureValidationError("variant exceeds the 8-directory-depth limit")
                pending.append((path, depth + 1))
            else:
                raise FixtureValidationError("variant contains a non-regular filesystem object")
    if actual != set(EXPECTED_MEDIA):
        raise FixtureValidationError(f"media coverage mismatch: {sorted(actual)!r}")
    return records


def validate_fixture(fixture: Path = FIXTURE) -> dict[str, object]:
    """Validate the committed fixture's exact provenance pins and content."""
    global FIXTURE
    saved, FIXTURE = FIXTURE, fixture
    try:
        before = snapshot(fixture)
        try:
            top = {path.split("/")[0] for path in before}
            if top != {"README.md", LICENSE_NAME, *VARIANTS}:
                raise FixtureValidationError(f"unexpected fixture top level: {sorted(top)!r}")
            license_key = LICENSE_NAME
            if before[license_key] != LICENSE_SHA256:
                raise FixtureValidationError("upstream MIT license hash mismatch")
            total_bytes = 0
            for variant, (manifest_name, _, digest_tag) in VARIANTS.items():
                records = verify_variant(variant, manifest_name, digest_tag)
                total_bytes += sum(int(record["size"]) for record in records)
            return {"fixture": str(fixture), "variants": sorted(VARIANTS),
                    "files_per_variant": len(EXPECTED_MEDIA), "bytes_per_variant": total_bytes // len(VARIANTS),
                    "license_sha256": LICENSE_SHA256}
        finally:
            if snapshot(fixture) != before:
                raise FixtureValidationError("validator modified the fixture")
    finally:
        FIXTURE = saved


def validate_with_pinned_schemas(fixture: Path, primary_xsd: Path, signature_xsd: Path) -> str:
    """Validate every variant manifest with explicitly pinned local schemas."""
    primary_bytes = _read_small_file(primary_xsd.resolve(strict=True))
    signature_bytes = _read_small_file(signature_xsd.resolve(strict=True))
    if sha256(primary_bytes) != PRIMARY_XSD_SHA256:
        raise FixtureValidationError("primary classic MHL schema hash mismatch")
    if sha256(signature_bytes) != SIGNATURE_XSD_SHA256:
        raise FixtureValidationError("XML signature schema hash mismatch")
    try:
        from lxml import etree
    except ImportError as error:
        raise FixtureValidationError("lxml is required for optional schema validation") from error

    class Resolver(etree.Resolver):
        def resolve(self, url, public_id, context):
            if url == SIGNATURE_XSD_URL:
                return self.resolve_string(signature_bytes, context, base_url=SIGNATURE_XSD_URL)
            raise FixtureValidationError("schema requested an unpinned external dependency: " + url)

    parser = etree.XMLParser(no_network=True, load_dtd=False, resolve_entities=False)
    parser.resolvers.add(Resolver())
    schema = etree.XMLSchema(etree.fromstring(primary_bytes, parser))
    for variant, (manifest_name, _, _) in VARIANTS.items():
        schema.assertValid(etree.fromstring(_read_small_file(fixture / variant / manifest_name), parser))
    return "pinned classic MHL 1.1 schema"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--primary-xsd", type=Path, help="optional locally supplied classic MHL 1.1 XSD")
    parser.add_argument("--signature-xsd", type=Path, help="optional locally supplied XML signature XSD")
    args = parser.parse_args()
    if bool(args.primary_xsd) != bool(args.signature_xsd):
        parser.error("--primary-xsd and --signature-xsd must be supplied together")
    result = validate_fixture()
    if args.primary_xsd:
        result["schema_check"] = validate_with_pinned_schemas(FIXTURE, args.primary_xsd, args.signature_xsd)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
