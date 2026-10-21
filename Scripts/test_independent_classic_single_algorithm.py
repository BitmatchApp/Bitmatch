#!/usr/bin/env python3
"""Offline tests for the pinned independent single-algorithm fixture validator."""

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


VALIDATOR_PATH = Path(__file__).resolve().parent / "ascmhl/validate_independent_classic_single_algorithm.py"
SPEC = importlib.util.spec_from_file_location("independent_classic_single_algorithm", VALIDATOR_PATH)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


def synthetic_manifest(name: str, data: bytes, digest: str) -> bytes:
    """Make clearly synthetic parser input; this is not external-tool output."""
    digests = {"md5": hashlib.md5(data).hexdigest(), "sha1": hashlib.sha1(data).hexdigest(),
               "xxhash64be": "0" * 16, None: ""}
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
    if digest is None:
        ET.SubElement(record, "null")
    else:
        ET.SubElement(record, digest).text = digests[digest]
    ET.SubElement(record, "hashdate").text = "2026-01-01T00:00:00Z"
    return ET.tostring(root, encoding="UTF-8", xml_declaration=True)


class IndependentSingleAlgorithmTests(unittest.TestCase):
    def setUp(self):
        self.original_fixture_snapshot = VALIDATOR.snapshot(VALIDATOR.FIXTURE)

    def tearDown(self):
        self.assertEqual(VALIDATOR.snapshot(VALIDATOR.FIXTURE), self.original_fixture_snapshot)

    def test_pinned_fixture_validates_without_changing_any_bytes(self):
        before = VALIDATOR.snapshot(VALIDATOR.FIXTURE)
        try:
            result = VALIDATOR.validate_fixture()
        except VALIDATOR.FixtureValidationError as error:
            if "xxhash is required" in str(error):
                self.skipTest("xxhash module not installed; xxh64 media recompute skipped")
            raise
        self.assertEqual(result["variants"], ["md5-only", "sha1-only", "size-only", "xxh64"])
        self.assertEqual(result["files_per_variant"], 3)
        self.assertEqual(result["bytes_per_variant"], 34 + 36 + 33)
        self.assertEqual(VALIDATOR.snapshot(VALIDATOR.FIXTURE), before)

    def test_pinned_validator_rejects_changed_media_and_extra_files(self):
        with tempfile.TemporaryDirectory(prefix="bitmatch-single-algorithm-test-") as temporary:
            copy = Path(temporary) / "fixture"
            shutil.copytree(VALIDATOR.FIXTURE, copy)
            media = copy / "md5-only" / "clip one.mov"
            media.write_bytes(b"X" + media.read_bytes()[1:])
            with self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.validate_fixture(copy)

            shutil.copyfile(VALIDATOR.FIXTURE / "md5-only" / "clip one.mov", media)
            (copy / "md5-only" / "unexpected.txt").write_text("synthetic extra file\n")
            with self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.validate_fixture(copy)

    def test_pinned_validator_rejects_manifest_and_license_changes(self):
        with tempfile.TemporaryDirectory(prefix="bitmatch-single-pin-control-") as temporary:
            fixture = Path(temporary) / "fixture"
            shutil.copytree(VALIDATOR.FIXTURE, fixture)
            manifest = fixture / "sha1-only" / "sha1-only.mhl"
            manifest.write_bytes(manifest.read_bytes() + b"\n")
            with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "hash mismatch"):
                VALIDATOR.validate_fixture(fixture)
        with tempfile.TemporaryDirectory(prefix="bitmatch-single-license-control-") as temporary:
            fixture = Path(temporary) / "fixture"
            shutil.copytree(VALIDATOR.FIXTURE, fixture)
            target = fixture / VALIDATOR.LICENSE_NAME
            target.write_bytes(target.read_bytes() + b"\n")
            with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "license hash mismatch"):
                VALIDATOR.validate_fixture(fixture)

    def test_synthetic_single_digest_shapes_round_trip(self):
        # Handcrafted parser controls only; not fixture provenance.
        name = "Camera A/clip & café.txt"
        content = b"synthetic single-digest parser control\n"
        for digest, pattern in (("md5", "md5"), ("sha1", "sha1")):
            records = VALIDATOR.parse_variant_manifest(synthetic_manifest(name, content, digest), digest)
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["path"], name)
            self.assertEqual(records[0]["size"], len(content))
            if digest == "md5":
                self.assertEqual(records[0]["md5"], hashlib.md5(content).hexdigest())
            else:
                self.assertEqual(records[0]["sha1"], hashlib.sha1(content).hexdigest())

    def test_synthetic_unsupported_shapes_stay_distinct_from_supported_ones(self):
        name = "sample.txt"
        content = b"synthetic unsupported-shape control\n"
        size_only = VALIDATOR.parse_variant_manifest(synthetic_manifest(name, content, None), None)
        self.assertEqual(size_only[0]["size"], len(content))
        self.assertNotIn("md5", size_only[0])
        xxh64 = VALIDATOR.parse_variant_manifest(synthetic_manifest(name, content, "xxhash64be"), "xxhash64be")
        self.assertEqual(len(xxh64[0]["xxhash64be"]), 16)
        # A both-digest record is not a valid single-digest manifest.
        both = synthetic_manifest(name, content, "md5").replace(
            b"</md5>", ("</md5><sha1>" + hashlib.sha1(content).hexdigest() + "</sha1>").encode())
        with self.assertRaises(VALIDATOR.FixtureValidationError):
            VALIDATOR.parse_variant_manifest(both, "md5")
        with self.assertRaises(VALIDATOR.FixtureValidationError):
            VALIDATOR.parse_variant_manifest(both, "sha1")
        # A digest element in the wrong variant shape is rejected.
        md5_as_sha1 = synthetic_manifest(name, content, "md5")
        with self.assertRaises(VALIDATOR.FixtureValidationError):
            VALIDATOR.parse_variant_manifest(md5_as_sha1, "sha1")

    def test_synthetic_parser_controls_reject_dtd_entities_bad_encoding_and_unsafe_paths(self):
        name = "sample.txt"
        content = b"synthetic parser control\n"
        valid = synthetic_manifest(name, content, "md5")
        variants = [
            valid.replace(b"<hashlist", b"<!DOCTYPE hashlist [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>\n<hashlist", 1),
            valid.replace(b"UTF-8", b"UTF-16", 1),
            "<hashlist version='1.1'/>".encode("utf-16"),
        ]
        for data in variants:
            with self.subTest(data=data[:80]), self.assertRaises(VALIDATOR.FixtureValidationError):
                VALIDATOR.parse_variant_manifest(data, "md5")
        unsafe = synthetic_manifest("../outside.txt", content, "sha1")
        with self.assertRaises(VALIDATOR.FixtureValidationError):
            VALIDATOR.parse_variant_manifest(unsafe, "sha1")

    def test_missing_xxhash_dependency_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="bitmatch-single-xxhash-") as temporary:
            fixture = Path(temporary) / "fixture"
            shutil.copytree(VALIDATOR.FIXTURE, fixture)
            real_import = __import__

            def guarded_import(name, *args, **kwargs):
                if name == "xxhash":
                    raise ImportError("synthetic missing xxhash control")
                return real_import(name, *args, **kwargs)

            with patch("builtins.__import__", side_effect=guarded_import):
                with self.assertRaisesRegex(VALIDATOR.FixtureValidationError, "xxhash is required"):
                    VALIDATOR.validate_fixture(fixture)

    def test_optional_schema_validation_hash_gates_before_loading_lxml(self):
        with tempfile.TemporaryDirectory(prefix="bitmatch-single-schema-pin-") as temporary:
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

        with tempfile.TemporaryDirectory(prefix="bitmatch-single-schema-mock-") as temporary:
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
        self.assertEqual(sum(1 for kind, _ in calls if kind == "valid"), len(VALIDATOR.VARIANTS))
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
