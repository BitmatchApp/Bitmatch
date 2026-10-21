#!/usr/bin/env python3
"""Offline tests for the pinned independent classic-MHL fixture validator."""

import hashlib
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
from types import ModuleType
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


VALIDATOR_PATH = Path(__file__).resolve().parent / "ascmhl/validate_independent_classic_fixture.py"
SPEC = importlib.util.spec_from_file_location("independent_classic_fixture", VALIDATOR_PATH)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


def synthetic_manifest(name: str, data: bytes) -> bytes:
    """Make clearly synthetic parser input; this is not external-tool output."""
    root = ET.Element("hashlist", {"version": "1.1"})
    creator = ET.SubElement(root, "creatorinfo")
    for key, value in (("username", "synthetic-test"), ("hostname", "synthetic-host"),
                       ("tool", "synthetic parser control"),
                       ("startdate", "2026-01-01T00:00:00Z"),
                       ("finishdate", "2026-01-01T00:00:00Z"),
                       ("log", "not independent MHL output")):
        ET.SubElement(creator, key).text = value
    record = ET.SubElement(root, "hash")
    ET.SubElement(record, "file").text = name
    ET.SubElement(record, "size").text = str(len(data))
    ET.SubElement(record, "lastmodificationdate").text = "2026-01-01T00:00:00Z"
    ET.SubElement(record, "md5").text = hashlib.md5(data).hexdigest()
    ET.SubElement(record, "sha1").text = hashlib.sha1(data).hexdigest()
    ET.SubElement(record, "hashdate").text = "2026-01-01T00:00:00Z"
    return ET.tostring(root, encoding="UTF-8", xml_declaration=True)


class IndependentClassicFixtureTests(unittest.TestCase):
    def setUp(self):
        self.original_fixture_snapshot = VALIDATOR.snapshot(VALIDATOR.FIXTURE)

    def tearDown(self):
        self.assertEqual(VALIDATOR.snapshot(VALIDATOR.FIXTURE), self.original_fixture_snapshot)

    def test_pinned_fixture_validates_without_changing_any_bytes(self):
        before = VALIDATOR.snapshot(VALIDATOR.FIXTURE)
        result = VALIDATOR.validate_fixture()
        self.assertEqual(result["files"], 1)
        self.assertEqual(result["bytes"], 30)
        self.assertEqual(result["manifest_sha256"], VALIDATOR.MANIFEST_SHA256)
        self.assertEqual(VALIDATOR.snapshot(VALIDATOR.FIXTURE), before)

    def test_pinned_validator_rejects_changed_media_and_extra_files(self):
        with tempfile.TemporaryDirectory(prefix="bitmatch-independent-classic-test-") as temporary:
            copy = Path(temporary) / "fixture"
            shutil.copytree(VALIDATOR.FIXTURE, copy)
            media = copy / VALIDATOR.MEDIA_NAME
            media.write_bytes(b"X" + media.read_bytes()[1:])
            with self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.validate_fixture(copy)

            shutil.copyfile(VALIDATOR.FIXTURE / VALIDATOR.MEDIA_NAME, media)
            (copy / "unexpected.txt").write_text("synthetic extra file\n")
            with self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.validate_fixture(copy)

    def test_synthetic_unicode_and_escaped_path_round_trips_and_hashes(self):
        # This temporary parser control is handcrafted test input, not fixture provenance.
        name = "Camera A/clip & café 東京.txt"
        content = b"synthetic Unicode-path parser control\n"
        data = synthetic_manifest(name, content)
        self.assertIn(b"&amp;", data)
        self.assertIn("café 東京".encode("utf-8"), data)
        with tempfile.TemporaryDirectory(prefix="bitmatch-synthetic-unicode-") as temporary:
            media_root = Path(temporary)
            media = media_root / name
            media.parent.mkdir(parents=True)
            media.write_bytes(content)
            records = VALIDATOR.verify_inventory(data, media_root)
        self.assertEqual(records[0]["path"], name)
        self.assertEqual(records[0]["size"], len(content))
        self.assertEqual(records[0]["md5"], hashlib.md5(content).hexdigest())
        self.assertEqual(records[0]["sha1"], hashlib.sha1(content).hexdigest())

    def test_pinned_validator_rejects_manifest_and_license_changes(self):
        for filename in (VALIDATOR.MANIFEST_NAME, VALIDATOR.LICENSE_NAME):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory(
                    prefix="bitmatch-fixture-pin-control-") as temporary:
                fixture = Path(temporary) / "fixture"
                shutil.copytree(VALIDATOR.FIXTURE, fixture)
                target = fixture / filename
                target.write_bytes(target.read_bytes() + b"\n")
                with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "hash mismatch"):
                    VALIDATOR.validate_fixture(fixture)

    def test_synthetic_padded_path_must_match_without_trimming_or_renaming(self):
        name = " padded control.txt "
        content = b"synthetic padded path control\n"
        data = synthetic_manifest(name, content)
        with tempfile.TemporaryDirectory(prefix="bitmatch-synthetic-padding-") as temporary:
            media_root = Path(temporary)
            (media_root / name).write_bytes(content)
            self.assertEqual(VALIDATOR.verify_inventory(data, media_root)[0]["path"], name)
            (media_root / name).rename(media_root / name.strip())
            with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "missing media path"):
                VALIDATOR.verify_inventory(data, media_root)

    def test_synthetic_parser_controls_reject_dtd_entities_bad_encoding_and_unsafe_paths(self):
        name = "sample.txt"
        content = b"synthetic parser control\n"
        valid = synthetic_manifest(name, content)
        variants = [
            valid.replace(b"<hashlist", b"<!DOCTYPE hashlist [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>\n<hashlist", 1),
            valid.replace(b"UTF-8", b"UTF-16", 1),
            "<hashlist version='1.1'/>".encode("utf-16"),
        ]
        for data in variants:
            with self.subTest(data=data[:80]), self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.parse_manifest(data)

        unsafe = synthetic_manifest("../outside.txt", content)
        with self.assertRaises(VALIDATOR.FixtureValidationError):
            VALIDATOR.parse_manifest(unsafe)

        nested_field = valid.replace(b"<file>sample.txt</file>", b"<file>sample<part>.txt</part></file>")
        with self.assertRaises(VALIDATOR.FixtureValidationError):
            VALIDATOR.parse_manifest(nested_field)
        for tag in (b"lastmodificationdate", b"hashdate"):
            nested_date = valid.replace(b"<" + tag + b">", b"<" + tag + b"><unexpected/>")
            with self.subTest(tag=tag), self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.parse_manifest(nested_date)

        non_whitespace_tails = [
            valid.replace(b"</file>", b"</file>surplus", 1),
            valid.replace(b"</creatorinfo>", b"</creatorinfo>surplus", 1),
            valid.replace(b"<creatorinfo>", b"<creatorinfo>surplus", 1),
            valid.replace(b"<hash>", b"<hash extra='value'>", 1),
            valid.replace(b"<file>", b"<file extra='value'>", 1),
        ]
        for candidate in non_whitespace_tails:
            with self.subTest(data=candidate[:120]), self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.parse_manifest(candidate)

        duplicate_digest = valid.replace(b"</hash>", b"<md5>duplicate</md5></hash>")
        with self.assertRaises(VALIDATOR.FixtureValidationError):
            VALIDATOR.parse_manifest(duplicate_digest)
        duplicate_record = valid.replace(b"</hashlist>", b"<hash>duplicate</hash></hashlist>")
        with self.assertRaises(VALIDATOR.FixtureValidationError):
            VALIDATOR.parse_manifest(duplicate_record)

    def test_synthetic_parser_controls_reject_wrong_digest_size_and_unlisted_media(self):
        name = "sample.txt"
        content = b"synthetic parser control\n"
        valid = synthetic_manifest(name, content)
        with tempfile.TemporaryDirectory(prefix="bitmatch-synthetic-controls-") as temporary:
            media_root = Path(temporary)
            (media_root / name).write_bytes(content)
            wrong_md5 = valid.replace(hashlib.md5(content).hexdigest().encode(), b"0" * 32)
            if hashlib.md5(content).hexdigest() == "0" * 32:
                wrong_md5 = valid.replace(hashlib.md5(content).hexdigest().encode(), b"1" * 32)
            wrong_sha1 = valid.replace(hashlib.sha1(content).hexdigest().encode(), b"0" * 40)
            if hashlib.sha1(content).hexdigest() == "0" * 40:
                wrong_sha1 = valid.replace(hashlib.sha1(content).hexdigest().encode(), b"1" * 40)
            for algorithm, candidate in (("MD5", wrong_md5), ("SHA-1", wrong_sha1)):
                message_pattern = "SHA1" if algorithm == "SHA-1" else algorithm
                with self.subTest(algorithm=algorithm), self.assertRaisesRegex(
                        VALIDATOR.FixtureValidationError, message_pattern):
                    VALIDATOR.verify_inventory(candidate, media_root)
            wrong_size = valid.replace(f"<size>{len(content)}</size>".encode(), b"<size>1</size>")
            with self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.verify_inventory(wrong_size, media_root)
            (media_root / "extra.txt").write_text("synthetic unlisted media\n")
            with self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.verify_inventory(valid, media_root)

    def test_synthetic_inventory_rejects_symlinked_media(self):
        name = "linked.txt"
        content = b"synthetic symlink control\n"
        data = synthetic_manifest(name, content)
        with tempfile.TemporaryDirectory(prefix="bitmatch-synthetic-symlink-") as temporary:
            root = Path(temporary)
            media_root = root / "media"
            media_root.mkdir()
            target = root / "outside.txt"
            target.write_bytes(content)
            (media_root / name).symlink_to(target)
            with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "symbolic-link"):
                VALIDATOR.verify_inventory(data, media_root)

    def test_synthetic_inventory_rejects_empty_directory(self):
        name = "nested/sample.txt"
        content = b"synthetic empty-directory control\n"
        data = synthetic_manifest(name, content)
        with tempfile.TemporaryDirectory(prefix="bitmatch-synthetic-empty-dir-") as temporary:
            media_root = Path(temporary)
            nested = media_root / "nested"
            nested.mkdir()
            (nested / "sample.txt").write_bytes(content)
            self.assertEqual(VALIDATOR.verify_inventory(data, media_root)[0]["path"], name)
            (media_root / "unused").mkdir()
            with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "empty or unlisted directory"):
                VALIDATOR.verify_inventory(data, media_root)

    def test_inventory_payload_size_is_rejected_before_reading_bytes(self):
        content = b"x" * (VALIDATOR.MAX_SMALL_FILE_BYTES + 1)
        name = "large-synthetic-control.bin"
        data = synthetic_manifest(name, content)
        with tempfile.TemporaryDirectory(prefix="bitmatch-bounded-payload-") as temporary:
            media_root = Path(temporary)
            (media_root / name).write_bytes(content)
            with patch.object(VALIDATOR, "_read_small_file", side_effect=AssertionError("must not read payload")):
                with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "1 MiB limit"):
                    VALIDATOR.verify_inventory(data, media_root)

    def test_optional_schema_validation_hash_gates_before_loading_lxml(self):
        with tempfile.TemporaryDirectory(prefix="bitmatch-schema-pin-") as temporary:
            primary = Path(temporary) / "primary.xsd"
            signature = Path(temporary) / "signature.xsd"
            primary.write_bytes(b"synthetic unpinned schema")
            signature.write_bytes(b"synthetic unpinned signature schema")
            with patch.dict("sys.modules", {"lxml": None, "lxml.etree": None}):
                with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "primary classic MHL"):
                    VALIDATOR.validate_with_pinned_schemas(VALIDATOR.FIXTURE, primary, signature)

    def test_optional_schema_validation_uses_pinned_bytes_and_offline_resolver(self):
        calls = []

        class ResolverBase:
            def resolve_filename(self, filename, context):
                return ("local-schema", filename)

            def resolve_string(self, data, context, base_url=None):
                return ("pinned-schema-bytes", data, base_url)

        class ResolverRegistry:
            def add(self, resolver):
                self.resolver = resolver

        class FakeParser:
            def __init__(self):
                self.resolvers = ResolverRegistry()

        class FakeSchema:
            def __init__(self, root):
                calls.append(("schema", root))

            def assertValid(self, root):
                calls.append(("valid", root))

        fake_etree = ModuleType("lxml.etree")
        fake_etree.Resolver = ResolverBase
        parser = FakeParser()
        fake_etree.XMLParser = lambda **options: (calls.append(("parser", options)) or parser)
        fake_etree.fromstring = lambda data, selected_parser: (calls.append(("fromstring", data)) or data)
        fake_etree.XMLSchema = FakeSchema
        fake_lxml = ModuleType("lxml")
        fake_lxml.etree = fake_etree

        with tempfile.TemporaryDirectory(prefix="bitmatch-schema-mock-") as temporary:
            primary = Path(temporary) / "primary.xsd"
            signature = Path(temporary) / "signature.xsd"
            primary.write_bytes(b"synthetic pinned schema bytes")
            signature.write_bytes(b"synthetic pinned signature schema bytes")
            with patch.object(VALIDATOR, "sha256", side_effect=[
                    VALIDATOR.PRIMARY_XSD_SHA256, VALIDATOR.SIGNATURE_XSD_SHA256]), \
                    patch.dict(sys.modules, {"lxml": fake_lxml, "lxml.etree": fake_etree}):
                result = VALIDATOR.validate_with_pinned_schemas(VALIDATOR.FIXTURE, primary, signature)

        self.assertEqual(result, "pinned classic MHL 1.1 schema")
        self.assertIn(("fromstring", b"synthetic pinned schema bytes"), calls)
        self.assertIn(("fromstring", (VALIDATOR.FIXTURE / VALIDATOR.MANIFEST_NAME).read_bytes()), calls)
        options = next(value for kind, value in calls if kind == "parser")
        self.assertEqual(options, {"no_network": True, "load_dtd": False, "resolve_entities": False})
        resolver = parser.resolvers.resolver
        self.assertEqual(resolver.resolve(VALIDATOR.SIGNATURE_XSD_URL, None, None),
                         ("pinned-schema-bytes", b"synthetic pinned signature schema bytes",
                          VALIDATOR.SIGNATURE_XSD_URL))
        with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "unpinned external dependency"):
            resolver.resolve("https://example.invalid/other.xsd", None, None)


if __name__ == "__main__":
    unittest.main()
