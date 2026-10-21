#!/usr/bin/env python3
"""Strictly validate the committed independent classic MHL fixture offline.

The permanent fixture is pinned to its sanitized manifest and upstream license.
Optional schema checks use only local XSD files whose hashes are pinned below.
"""

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
           / "EvidenceCompatibility/classic-padded-independent")
MEDIA_NAME = " padded name.txt "
MEDIA_BYTES = b"synthetic padded-name payload\n"
MEDIA_SHA256 = "eb4056c1426dbba6874fd07c8bced05b82451eb71adcc68f22c843b7c2199b4a"
MEDIA_MD5 = "300d5c3d929f8697d3f916a449a51ead"
MEDIA_SHA1 = "79da2a02fa18fccf3ae906fb0775119b14ebbd32"
MANIFEST_NAME = "padded-independent.mhl"
MANIFEST_SHA256 = "3c4cf6a98e42b5b5a7f64af1c001a67e76315bf0fd2ceadf9f1e22fcf78d7feb"
LICENSE_NAME = "UPSTREAM-MIT-LICENSE.txt"
LICENSE_SHA256 = "ad1c3e1134c9b2d0827268ce65540dd2d6ed57ae2978b6e939a663b134f0f821"
PRIMARY_XSD_SHA256 = "c1adcd2591069249c88f2fc1fabac81363e7572b952834cce66f72a264e4c703"
SIGNATURE_XSD_SHA256 = "d102ad3df7664c307e0c2c776ba4a90513b1969974d8a940bae1a77f9f21e15d"
SIGNATURE_XSD_URL = "http://www.w3.org/TR/xmldsig-core/xmldsig-core-schema.xsd"
EXPECTED_ROOT_FILES = {"README.md", LICENSE_NAME, MANIFEST_NAME, MEDIA_NAME}
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_SMALL_FILE_BYTES = 1024 * 1024
MAX_FIXTURE_FILES = 16
MAX_INVENTORY_FILES = 16
MAX_TREE_ENTRIES = 128
MAX_DIRECTORY_DEPTH = 8


class FixtureValidationError(ValueError):
    """The fixture or a manifest presented to the validator is invalid."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def snapshot(root: Path) -> dict[str, str]:
    """Hash the small regular files in this fixture without following links."""
    if root.is_symlink() or not root.is_dir():
        raise FixtureValidationError(f"fixture root is not a real directory: {root}")
    result: dict[str, str] = {}
    directories = {"."}
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
                    raise FixtureValidationError("fixture exceeds the 16-file limit")
                if path.lstat().st_size > MAX_SMALL_FILE_BYTES:
                    raise FixtureValidationError(f"fixture file exceeds the 1 MiB limit: {relative!r}")
                result[relative] = sha256(_read_small_file(path))
            elif stat.S_ISDIR(mode):
                if depth >= MAX_DIRECTORY_DEPTH:
                    raise FixtureValidationError("fixture exceeds the 8-directory-depth limit")
                directories.add(relative)
                pending.append((path, depth + 1))
            else:
                raise FixtureValidationError(f"fixture contains a non-regular file: {relative!r}")
    if directories != {"."}:
        raise FixtureValidationError("fixture must not contain nested directories")
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


def parse_manifest(data: bytes) -> list[dict[str, object]]:
    """Parse the supported UTF-8 classic 1.1 inventory shape, rejecting DTDs."""
    if len(data) > MAX_MANIFEST_BYTES:
        raise FixtureValidationError("manifest exceeds the 1 MiB validation limit")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise FixtureValidationError("manifest is not strict UTF-8") from error
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
    _element_only(root, ["creatorinfo", "hash"], {"version": "1.1"})
    creator, record = list(root)
    _element_only(record, ["file", "size", "lastmodificationdate", "md5", "sha1", "hashdate"])
    for tag in ("lastmodificationdate", "hashdate"):
        _text(record, tag)

    name = _text(record, "file")  # Preserve significant leading/trailing spaces.
    size_text = _text(record, "size")
    if not re.fullmatch(r"[1-9][0-9]*", size_text):
        raise FixtureValidationError("size must be a positive decimal integer")
    digests = {algorithm: _text(record, algorithm) for algorithm in ("md5", "sha1")}
    if not re.fullmatch(r"[0-9a-f]{32}", digests["md5"]):
        raise FixtureValidationError("invalid lowercase MD5 digest")
    if not re.fullmatch(r"[0-9a-f]{40}", digests["sha1"]):
        raise FixtureValidationError("invalid lowercase SHA-1 digest")
    # Validate the creator block's simple text-only shape; the permanent fixture
    # pins all values separately, while synthetic controls can use synthetic text.
    _element_only(creator, ["username", "hostname", "tool", "startdate", "finishdate", "log"])
    if any(list(item) or item.attrib or (item.tail is not None and item.tail.strip()) for item in creator):
        raise FixtureValidationError("invalid creator metadata shape")
    if any(item.text is None for item in creator):
        raise FixtureValidationError("creator metadata fields must contain text")
    if (not name or "\x00" in name or "\\" in name or name.startswith("/")
            or re.match(r"^[A-Za-z]:", name)):
        raise FixtureValidationError("unsafe manifest path")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts) or PurePosixPath(name).is_absolute():
        raise FixtureValidationError("unsafe manifest path")
    if len(parts) - 1 > MAX_DIRECTORY_DEPTH:
        raise FixtureValidationError("manifest path exceeds the 8-directory-depth limit")
    return [{"path": name, "size": int(size_text), **digests}]


def verify_inventory(data: bytes, media_root: Path) -> list[dict[str, object]]:
    """Check a tiny synthetic inventory against its relative media files.

    This helper is bounded for the committed fixture and small parser controls;
    it is not a general-purpose hostile-filesystem validator.
    """
    if media_root.is_symlink() or not media_root.is_dir():
        raise FixtureValidationError("media root must be a real directory")
    root = media_root.resolve(strict=True)
    records = parse_manifest(data)
    if len(records) > MAX_INVENTORY_FILES:
        raise FixtureValidationError("inventory exceeds the 16-file limit")
    recorded: set[str] = set()
    for record in records:
        relative = str(record["path"])
        if relative in recorded:
            raise FixtureValidationError(f"duplicate path: {relative!r}")
        recorded.add(relative)
        if int(record["size"]) > MAX_SMALL_FILE_BYTES:
            raise FixtureValidationError(f"media file exceeds the 1 MiB limit: {relative!r}")
        path = root
        for component in relative.split("/"):
            path = path / component
            try:
                mode = path.lstat().st_mode
            except OSError as error:
                raise FixtureValidationError(f"missing media path: {relative!r}") from error
            if stat.S_ISLNK(mode):
                raise FixtureValidationError(f"symbolic-link media is unsupported: {relative!r}")
        if not stat.S_ISREG(mode):
            raise FixtureValidationError(f"media path is not a regular file: {relative!r}")
        if path.lstat().st_size > MAX_SMALL_FILE_BYTES:
            raise FixtureValidationError(f"media file exceeds the 1 MiB limit: {relative!r}")
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(root):
            raise FixtureValidationError(f"media path escapes its root: {relative!r}")
        content = _read_small_file(path)
        if len(content) != record["size"]:
            raise FixtureValidationError(f"size mismatch for {relative!r}")
        for algorithm in ("md5", "sha1"):
            if hashlib.new(algorithm, content).hexdigest() != record[algorithm]:
                raise FixtureValidationError(f"{algorithm.upper()} mismatch for {relative!r}")

    actual: set[str] = set()
    actual_directories = {"."}
    entries = 0
    pending = [(media_root, 0)]
    while pending:
        directory, depth = pending.pop()
        for path in directory.iterdir():
            entries += 1
            if entries > MAX_TREE_ENTRIES:
                raise FixtureValidationError("media root exceeds the 128-entry traversal limit")
            mode = path.lstat().st_mode
            relative = path.relative_to(media_root).as_posix()
            if stat.S_ISLNK(mode):
                raise FixtureValidationError(f"media contains a symbolic link: {relative}")
            if stat.S_ISREG(mode):
                if len(actual) >= MAX_INVENTORY_FILES:
                    raise FixtureValidationError("media root exceeds the 16-file limit")
                actual.add(relative)
            elif stat.S_ISDIR(mode):
                if depth >= MAX_DIRECTORY_DEPTH:
                    raise FixtureValidationError("media root exceeds the 8-directory-depth limit")
                actual_directories.add(relative)
                pending.append((path, depth + 1))
            else:
                raise FixtureValidationError("media contains a non-regular filesystem object")
    if actual != recorded:
        raise FixtureValidationError(f"inventory coverage mismatch: recorded={sorted(recorded)!r}, actual={sorted(actual)!r}")
    expected_directories = {"."}
    for relative in recorded:
        parent = PurePosixPath(relative).parent
        while str(parent) != ".":
            expected_directories.add(parent.as_posix())
            parent = parent.parent
    if actual_directories != expected_directories:
        raise FixtureValidationError("media root contains an empty or unlisted directory")
    return records


def validate_fixture(fixture: Path = FIXTURE) -> dict[str, object]:
    """Validate the committed fixture's exact provenance pins and content."""
    before = snapshot(fixture)
    try:
        if set(before) != EXPECTED_ROOT_FILES:
            raise FixtureValidationError(f"unexpected fixture files: {sorted(before)!r}")
        if before[LICENSE_NAME] != LICENSE_SHA256:
            raise FixtureValidationError("upstream MIT license hash mismatch")
        if before[MANIFEST_NAME] != MANIFEST_SHA256:
            raise FixtureValidationError("sanitized manifest hash mismatch")
        media_path = fixture / MEDIA_NAME
        media = _read_small_file(media_path)
        if media != MEDIA_BYTES or sha256(media) != MEDIA_SHA256:
            raise FixtureValidationError("synthetic media bytes or SHA-256 mismatch")
        with tempfile.TemporaryDirectory(prefix="bitmatch-independent-classic-media-") as temporary:
            media_root = Path(temporary)
            shutil.copyfile(media_path, media_root / MEDIA_NAME)
            records = verify_inventory(_read_small_file(fixture / MANIFEST_NAME), media_root)
        expected = [{"path": MEDIA_NAME, "size": len(MEDIA_BYTES), "md5": MEDIA_MD5, "sha1": MEDIA_SHA1}]
        if records != expected:
            raise FixtureValidationError("manifest claims differ from the pinned fixture record")
        return {"fixture": str(fixture), "files": len(records), "bytes": len(media),
                "manifest_sha256": MANIFEST_SHA256, "license_sha256": LICENSE_SHA256}
    finally:
        if snapshot(fixture) != before:
            raise FixtureValidationError("validator modified the fixture")


def validate_with_pinned_schemas(fixture: Path, primary_xsd: Path, signature_xsd: Path) -> str:
    """Validate with explicitly pinned local schemas; the resolver cannot use network."""
    primary_xsd = primary_xsd.resolve(strict=True)
    signature_xsd = signature_xsd.resolve(strict=True)
    primary_bytes = _read_small_file(primary_xsd)
    signature_bytes = _read_small_file(signature_xsd)
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
    schema.assertValid(etree.fromstring(_read_small_file(fixture / MANIFEST_NAME), parser))
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
