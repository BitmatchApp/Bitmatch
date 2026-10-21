#!/usr/bin/env python3
"""Check local test job routing with fake Xcode and Swift commands only."""

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
        self.environment_capture = self.root / "environment.jsonl"
        fake = self.bin / "xcodebuild"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "with open(os.environ['LOCAL_TEST_RUNNER_CAPTURE'], 'a') as capture:\n"
            "    capture.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "with open(os.environ['LOCAL_TEST_RUNNER_ENV_CAPTURE'], 'a') as capture:\n"
            "    selected = {k: v for k, v in os.environ.items() if k.startswith(('BITMATCH_', 'TEST_RUNNER_BITMATCH_')) or k in ('DERIVED_DATA_ROOT', 'IOS_SIMULATOR_DESTINATION', 'LOCAL_UNRELATED_SETTING')}\n"
            "    capture.write(json.dumps(selected) + '\\n')\n"
        )
        fake.chmod(0o755)
        shutil.copyfile(fake, self.bin / "swift")
        (self.bin / "swift").chmod(0o755)
        # Force the direct Swift branch: never reach the real arch/Swift tools.
        (self.bin / "uname").write_text("#!/bin/sh\nprintf 'x86_64\\n'\n")
        (self.bin / "uname").chmod(0o755)
        (self.bin / "arch").write_text("#!/bin/sh\nexit 97\n")
        (self.bin / "arch").chmod(0o755)
        self.env = dict(os.environ)
        self.env.pop("DERIVED_DATA_ROOT", None)
        self.env.pop("IOS_SIMULATOR_DESTINATION", None)
        for name in list(self.env):
            if name.startswith(("BITMATCH_", "TEST_RUNNER_BITMATCH_")):
                del self.env[name]
        self.env.update(
            PATH=str(self.bin) + os.pathsep + self.env["PATH"],
            LOCAL_TEST_RUNNER_CAPTURE=str(self.capture),
            LOCAL_TEST_RUNNER_ENV_CAPTURE=str(self.environment_capture),
        )

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

    def environments(self):
        return [json.loads(line) for line in self.environment_capture.read_text().splitlines()]

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

    def test_test_jobs_drop_inherited_stress_and_hardware_controls(self):
        controls = {
            "BITMATCH_HARDWARE_APP_WORKFLOW": "1",
            "TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY": "1",
            "BITMATCH_APP_MANY_FILES_MEMORY": "1",
            "TEST_RUNNER_BITMATCH_REPORT_PDF_MEMORY": "1",
            "BITMATCH_RUN_SOAK": "1",
            "BITMATCH_LARGE_VERIFY_ROOT": "/not-a-real-fixture",
            "BITMATCH_FUTURE_STRESS_GATE": "1\nprivate fixture name",
            "TEST_RUNNER_BITMATCH_FUTURE_STRESS_GATE": "1",
        }
        for job, expected_calls in [("mac-test", 1), ("ipad-test", 1), ("engine-test", 2)]:
            with self.subTest(job=job):
                self.capture.unlink(missing_ok=True)
                self.environment_capture.unlink(missing_ok=True)
                result = self.run_job(job, IOS_SIMULATOR_DESTINATION="platform=iOS Simulator,id=fake", **controls)
                self.assert_success(result)
                self.assertEqual(len(self.calls()), expected_calls)
                for environment in self.environments():
                    self.assertFalse(set(controls).intersection(environment))
                self.assertNotIn("private fixture name", result.stdout + result.stderr)

    def test_test_jobs_preserve_capture_and_output_routing(self):
        controls = {
            "BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS": "1",
            "TEST_RUNNER_BITMATCH_CAPTURE_WORKFLOW_SNAPSHOTS": "1",
            "DERIVED_DATA_ROOT": str(self.root / "external cache"),
            "IOS_SIMULATOR_DESTINATION": "platform=iOS Simulator,id=fake",
            "LOCAL_UNRELATED_SETTING": "preserved",
        }
        for name in ["PDF_EDGE_ARTIFACTS", "PREVIEW_PDF_OUTPUT", "REPORT_PDF_ARTIFACTS", "MATRIX_ARTIFACTS", "WORKFLOW_SNAPSHOT_OUTPUT_DIR"]:
            controls["BITMATCH_" + name] = str(self.root / name)
            controls["TEST_RUNNER_BITMATCH_" + name] = str(self.root / name)
        self.assert_success(self.run_job("mac-test", **controls))
        environment = self.environments()[0]
        for name, value in controls.items():
            self.assertEqual(environment.get(name), value, name)

    def test_engine_runs_both_frameworks_with_serial_scoped_arguments(self):
        self.assert_success(self.run_job("engine-test"))
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        for call, framework in zip(calls, ["--disable-swift-testing", "--disable-xctest"]):
            self.assertEqual(call, ["test", "--package-path", str(self.checkout / "Packages/BitMatchEngine"),
                                    "--build-system", "native", "--no-parallel", framework])

    def test_build_job_keeps_environment(self):
        self.assert_success(self.run_job("mac-build", BITMATCH_TEST_CONFIGURATION="unchanged"))
        self.assertEqual(self.environments()[0].get("BITMATCH_TEST_CONFIGURATION"), "unchanged")


if __name__ == "__main__":
    unittest.main()
