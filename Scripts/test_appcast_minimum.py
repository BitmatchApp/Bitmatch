#!/usr/bin/env python3
"""Offline tests only: fake archives, signing tools, GitHub, Git and Xcode."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("appcast_minimum", SCRIPTS / "appcast_minimum.py")
METADATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METADATA)
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
VERSION = "9.9.9"

STUB_COMMAND = '''#!/usr/bin/python3
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["APPCAST_TEST_COMMAND_LOG"], "a") as stream:
    stream.write(json.dumps([name, *args]) + "\\n")
if name == "sign_update":
    if args != ["--account", "bitmatch", os.environ["APPCAST_TEST_DMG"]]:
        raise SystemExit("Unexpected signing arguments")
    print('sparkle:edSignature="FAKE-SIGNATURE+/=" length="42"')
elif name == "gh" and args[:3] == ["repo", "clone", "BitmatchApp/bitmatchapp.github.io"]:
    if args[4:] != ["--", "--depth=1"]:
        raise SystemExit("Unexpected clone arguments")
    site = pathlib.Path(args[3])
    site.mkdir()
    shutil.copyfile(os.environ["APPCAST_TEST_INPUT"], site / "appcast.xml")
elif name == "git" and len(args) >= 3 and args[0] == "-C":
    if args[2:] == ["push"]:
        shutil.copyfile(pathlib.Path(args[1]) / "appcast.xml", os.environ["APPCAST_TEST_OUTPUT"])
    elif args[2:] not in (["add", "appcast.xml"], ["commit", "-m", "Publish BitMatch 9.9.9 appcast"]):
        raise SystemExit("Unexpected git command")
else:
    raise SystemExit("Unexpected external command: " + name + " " + repr(args))
'''


class AppcastMinimumTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bitmatch-appcast-tests-")
        self.root = Path(self.temporary.name)
        scripts = self.root / "Scripts"
        scripts.mkdir()
        for name in ("publish_appcast.sh", "appcast_minimum.py"):
            shutil.copyfile(SCRIPTS / name, scripts / name)
        self.plist = (self.root / "dist" / f"BitMatch-{VERSION}.xcarchive" / "Products"
                      / "Applications" / "BitMatch.app" / "Contents" / "Info.plist")
        self.plist.parent.mkdir(parents=True)
        self.dmg = self.root / "dist" / f"BitMatch-{VERSION}.dmg"
        self.dmg.write_bytes(b"x" * 42)
        self.info = {"CFBundleShortVersionString": VERSION, "CFBundleVersion": "123",
                     "LSMinimumSystemVersion": "15.5"}
        self.write_info()
        packages = self.root / "fake-derived-data" / "SourcePackages"
        tools = packages / "artifacts" / "sparkle" / "bin"
        tools.mkdir(parents=True)
        (packages / "Package.resolved").write_text(json.dumps({"pins": [
            {"identity": "sparkle", "state": {"version": "2.10.0"}}]}))
        self.bin = self.root / "fake-bin"
        self.bin.mkdir()
        for path in [*(self.bin / name for name in ("gh", "git", "xcodebuild")), tools / "sign_update"]:
            path.write_text(STUB_COMMAND)
            path.chmod(0o755)
        self.commands = self.root / "commands.jsonl"
        self.input_appcast = self.root / "existing-appcast.xml"
        self.input_appcast.write_text(f'''<?xml version="1.0"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}"><channel>
  <title>Keep this channel</title><description>Keep this description</description>
  <item><title>Replace this version</title><sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>
    <enclosure url="https://example.invalid/duplicate.dmg" sparkle:edSignature="replace-me"/></item>
  <item><title>Keep old release</title><sparkle:shortVersionString>0.2.8</sparkle:shortVersionString>
    <sparkle:version>18</sparkle:version><sparkle:minimumSystemVersion>15.5</sparkle:minimumSystemVersion>
    <enclosure url="https://example.invalid/old.dmg" sparkle:edSignature="OLD-SIGNATURE+/=" length="1234"/></item>
</channel></rss>''')
        self.output = self.root / "result-appcast.xml"
        self.env = dict(os.environ, PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        DERIVED_DATA_PATH=str(packages.parent), TMPDIR=str(self.root),
                        APPCAST_TEST_COMMAND_LOG=str(self.commands), APPCAST_TEST_DMG=str(self.dmg),
                        APPCAST_TEST_INPUT=str(self.input_appcast), APPCAST_TEST_OUTPUT=str(self.output))

    def tearDown(self):
        self.temporary.cleanup()

    def write_info(self, fmt=plistlib.FMT_XML):
        self.plist.write_bytes(plistlib.dumps(self.info, fmt=fmt))

    def run_shell(self):
        return subprocess.run(["/bin/bash", str(self.root / "Scripts" / "publish_appcast.sh"), VERSION],
                              capture_output=True, text=True, env=self.env, timeout=20)

    def assert_no_external_commands(self):
        self.assertFalse(self.commands.exists(), "Invalid metadata reached an external tool")
        self.assertFalse(self.output.exists(), "Invalid metadata produced an appcast")

    def assert_valid_appcast(self, expected):
        result = self.run_shell()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        tree = ET.parse(self.output)
        channel = tree.getroot().find("channel")
        self.assertEqual(channel.findtext("title"), "Keep this channel")
        self.assertEqual(channel.findtext("description"), "Keep this description")
        items = channel.findall("item")
        self.assertEqual(len(items), 2)
        new, old = items
        self.assertEqual(new.findtext(f"{{{SPARKLE}}}minimumSystemVersion"), expected)
        self.assertEqual(new.findtext(f"{{{SPARKLE}}}shortVersionString"), VERSION)
        self.assertEqual(new.findtext(f"{{{SPARKLE}}}version"), "123")
        self.assertEqual(new.find("enclosure").attrib, {
            "url": f"https://github.com/BitmatchApp/Bitmatch/releases/download/v{VERSION}/BitMatch-{VERSION}.dmg",
            f"{{{SPARKLE}}}edSignature": "FAKE-SIGNATURE+/=", "length": "42",
            "type": "application/octet-stream"})
        original_old = ET.parse(self.input_appcast).getroot().find("channel").findall("item")[1]
        def content(element):
            return (element.tag, (element.text or "").strip(), element.attrib,
                    tuple(content(child) for child in element))
        self.assertEqual(content(old), content(original_old))
        commands = [json.loads(line) for line in self.commands.read_text().splitlines()]
        self.assertEqual([command[0] for command in commands], ["sign_update", "gh", "git", "git", "git"])
        self.assertFalse(any(command[0] == "xcodebuild" for command in commands))
        self.assertFalse(list(self.root.glob("bitmatch-appcast.*")), "Script left its temporary site behind")

    def test_xml_and_binary_archive_versions(self):
        for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
            for minimum in ("15.5", "15.5.0", "15.0", "26.1"):
                with self.subTest(format=fmt, minimum=minimum):
                    self.info["LSMinimumSystemVersion"] = minimum
                    self.write_info(fmt)
                    result = subprocess.run([sys.executable, str(SCRIPTS / "appcast_minimum.py"), str(self.plist)],
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, minimum + "\n")

    def test_missing_bad_types_and_non_numeric_versions_are_rejected(self):
        invalid = [None, True, False, 15.5, 15, [], {}, b"15.5", "", "15", "15.", ".5", "15.5.0.1",
                   "15.05", "015.5", "0.5", "15.5beta1", "15.5\n", " 15.5", "15.5 ", "１５.５", "1" * 65 + ".5"]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                METADATA.minimum_system_version({"LSMinimumSystemVersion": value})
        with self.assertRaises(ValueError):
            METADATA.minimum_system_version({})
        for value in ([], "15.5", True):
            with self.subTest(root=value), self.assertRaises(ValueError):
                METADATA.minimum_system_version(value)

    def test_architecture_overrides_must_be_valid_and_agree(self):
        base = {"LSMinimumSystemVersion": "15.5"}
        for values in ({}, {"arm64": "15.5", "x86_64": "15.5.0"}):
            self.assertEqual(METADATA.minimum_system_version(dict(base, LSMinimumSystemVersionByArchitecture=values)), "15.5")
        for values in (None, [], "15.5", {"arm64": "15.0"}, {"x86_64": "16.0"},
                       {"arm64": True}, {"arm64": "15.5beta"}, {"": "15.5"}, {1: "15.5"}):
            with self.subTest(overrides=values), self.assertRaises(ValueError):
                METADATA.minimum_system_version(dict(base, LSMinimumSystemVersionByArchitecture=values))

    def test_cli_rejects_missing_and_malformed_plists_readably(self):
        for raw in (b"garbage", b"<?xml version='1.0'?><plist><dict>", b"bplist00truncated"):
            self.plist.write_bytes(raw)
            result = subprocess.run([sys.executable, str(SCRIPTS / "appcast_minimum.py"), str(self.plist)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 65)
            self.assertIn("Archived app minimum macOS version is invalid", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
        self.plist.unlink()
        result = subprocess.run([sys.executable, str(SCRIPTS / "appcast_minimum.py"), str(self.plist)],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 65)

    def test_stubbed_publish_keeps_current_minimum_and_prior_signed_entry(self):
        self.assert_valid_appcast("15.5")

    def test_stubbed_publish_reads_binary_plist_and_15_0_fixture_only(self):
        self.info["LSMinimumSystemVersion"] = "15.0"
        self.write_info(plistlib.FMT_BINARY)
        self.assert_valid_appcast("15.0")

    def test_bad_metadata_stops_before_dependency_resolution_signing_or_network(self):
        # If validation moves later, the absent pin/tool forces an external
        # dependency-resolution attempt, which the stub records and rejects.
        packages = Path(self.env["DERIVED_DATA_PATH"]) / "SourcePackages"
        (packages / "Package.resolved").unlink()
        (packages / "artifacts" / "sparkle" / "bin" / "sign_update").unlink()
        variants = [{}, {"LSMinimumSystemVersion": True}, {"LSMinimumSystemVersion": "garbage"},
                    {"LSMinimumSystemVersion": "15.5", "LSMinimumSystemVersionByArchitecture": {"x86_64": "16.0"}}]
        for values in variants:
            with self.subTest(metadata=values):
                self.info = dict(CFBundleShortVersionString=VERSION, CFBundleVersion="123", **values)
                self.write_info()
                result = self.run_shell()
                self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
                self.assertIn("Archived app minimum macOS version is invalid", result.stderr)
                self.assert_no_external_commands()

    def test_requested_version_mismatch_still_stops_before_external_commands(self):
        self.info["CFBundleShortVersionString"] = "9.9.8"
        self.write_info()
        result = self.run_shell()
        self.assertEqual(result.returncode, 65)
        self.assertIn("does not match requested version", result.stderr)
        self.assert_no_external_commands()


if __name__ == "__main__":
    unittest.main()
