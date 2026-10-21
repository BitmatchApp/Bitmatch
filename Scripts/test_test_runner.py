#!/usr/bin/env python3
"""Check local Xcode job routing without compiling or opening the app."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(os.environ.get("BITMATCH_TEST_RUNNER_SOURCE", Path(__file__).resolve().parents[1] / "test.sh"))


class LocalTestRunnerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="bitmatch-test-runner-")
        self.root = Path(self.scratch.name)
        self.checkout = self.root / "checkout with spaces"
        self.checkout.mkdir()
        shutil.copyfile(SOURCE, self.checkout / "test.sh")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.capture = self.root / "calls.jsonl"
        fake = self.bin / "xcodebuild"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['BITMATCH_TEST_CAPTURE'], 'a') as capture:\n"
            "    capture.write(json.dumps(sys.argv[1:]) + '\\n')\n"
        )
        fake.chmod(0o755)
        self.env = dict(os.environ)
        self.env.pop("DERIVED_DATA_ROOT", None)
        self.env.pop("IOS_SIMULATOR_DESTINATION", None)
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"], BITMATCH_TEST_CAPTURE=str(self.capture))

    def tearDown(self):
        self.scratch.cleanup()

    def run_job(self, *args, checkout=None, **overrides):
        env = dict(self.env, **overrides)
        return subprocess.run(
            ["bash", str((checkout or self.checkout) / "test.sh"), *args],
            env=env, text=True, capture_output=True, timeout=10, check=False,
        )

    def calls(self):
        return [json.loads(line) for line in self.capture.read_text().splitlines()] if self.capture.exists() else []

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_default_cache_is_outside_checkout_and_stable(self):
        self.assert_success(self.run_job("mac-build"))
        self.assert_success(self.run_job("mac-build"))
        paths = [Path(call[call.index("-derivedDataPath") + 1]) for call in self.calls()]
        self.assertEqual(paths[0], paths[1])
        self.assertEqual(paths[0].parent.parent, Path(f"/private/tmp/bitmatch-local-tests-{os.getuid()}"))
        self.assertNotIn(self.checkout, paths[0].parents)
        self.assertEqual(paths[0].name, "mac-build")

    def test_different_checkouts_do_not_share_build_products(self):
        other = self.root / "second checkout"
        other.mkdir()
        shutil.copyfile(SOURCE, other / "test.sh")
        self.assert_success(self.run_job("mac-build"))
        self.assert_success(self.run_job("mac-build", checkout=other))
        paths = [call[call.index("-derivedDataPath") + 1] for call in self.calls()]
        self.assertNotEqual(paths[0], paths[1])

    def test_explicit_cache_override_preserves_spaces_and_literal_text(self):
        override = str(self.root / "chosen cache $literal `literal`")
        self.assert_success(self.run_job("mac-build", DERIVED_DATA_ROOT=override))
        call = self.calls()[0]
        self.assertEqual(call[call.index("-derivedDataPath") + 1], override + "/mac-build")

    def test_mac_tests_remain_serial_and_scoped(self):
        self.assert_success(self.run_job())
        call = self.calls()[0]
        self.assertIn("test", call)
        self.assertEqual(call[call.index("-scheme") + 1], "BitMatch")
        self.assertEqual(call[call.index("-parallel-testing-enabled") + 1], "NO")
        self.assertIn("-only-testing:BitMatchTests", call)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", call)
        self.assertEqual(call[call.index("-project") + 1], str(self.checkout / "BitMatch.xcodeproj"))

    def test_mobile_build_and_test_keep_their_destinations(self):
        self.assert_success(self.run_job("ipad-build"))
        destination = "platform=iOS Simulator,id=synthetic-device"
        self.assert_success(self.run_job("ipad-test", IOS_SIMULATOR_DESTINATION=destination))
        build, test = self.calls()
        self.assertEqual(build[build.index("-sdk") + 1], "iphonesimulator")
        self.assertEqual(build[build.index("-destination") + 1], "generic/platform=iOS Simulator")
        self.assertEqual(test[test.index("-destination") + 1], destination)
        self.assertEqual(test[test.index("-parallel-testing-enabled") + 1], "NO")
        self.assertIn("-only-testing:BitMatch-iPadTests", test)

    def test_release_builds_keep_separate_products_and_signing_disabled(self):
        self.assert_success(self.run_job("release-builds"))
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual([call[call.index("-scheme") + 1] for call in calls], ["BitMatch", "BitMatch-iPad"])
        for call, job in zip(calls, ["mac-release", "ipad-release"]):
            self.assertEqual(call[call.index("-configuration") + 1], "Release")
            self.assertIn("CODE_SIGNING_ALLOWED=NO", call)
            self.assertEqual(Path(call[call.index("-derivedDataPath") + 1]).name, job)

    def test_invalid_job_never_invokes_xcode(self):
        result = self.run_job("not-a-job")
        self.assertEqual(result.returncode, 64)
        self.assertIn("Usage:", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_mobile_test_requires_a_destination(self):
        result = self.run_job("ipad-test")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("IOS_SIMULATOR_DESTINATION", result.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
