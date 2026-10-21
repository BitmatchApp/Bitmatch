#!/usr/bin/env python3
"""Stub the opt-in runner to exercise its pass/skip/receipt gates without Xcode."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "Scripts" / "test-physical-large-file-app-memory.sh"


class PhysicalAppMemoryRunnerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="bitmatch-physical-app-probe-", dir="/private/tmp")
        self.root = Path(self.scratch.name)
        self.evidence = self.root / "evidence-base"
        self.evidence.mkdir()
        self.config = self.root / "marked-config.json"
        self.config.write_text("{}\n")
        self.derived = self.root / "derived-data"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.capture = self.root / "xcode-capture.json"
        stub = self.bin / "xcodebuild"
        stub.write_text(self.stub_source())
        stub.chmod(0o755)
        python_shim = self.bin / "python3"
        python_shim.write_text(self.python_shim_source())
        python_shim.chmod(0o755)
        self.environment = dict(os.environ)
        self.environment["PATH"] = str(self.bin) + os.pathsep + self.environment.get("PATH", os.defpath)
        self.environment.update(
            BITMATCH_PHYSICAL_LARGE_FILE_CONFIG=str(self.config),
            BITMATCH_PHYSICAL_LARGE_FILE_EVIDENCE_BASE=str(self.evidence),
            BITMATCH_PHYSICAL_LARGE_FILE_DERIVED_DATA=str(self.derived),
            STUB_XCODE_CAPTURE=str(self.capture),
        )

    def tearDown(self):
        self.scratch.cleanup()

    @staticmethod
    def python_shim_source():
        return f'''#!{sys.executable}
import os, shutil, sys
from collections import namedtuple

if len(sys.argv) > 1 and sys.argv[1] == "-":
    DiskUsage = namedtuple("DiskUsage", "total used free")
    free = int(os.environ.get("STUB_PREFLIGHT_FREE_BYTES", str(1_000_000_000_000)))
    shutil.disk_usage = lambda _path: DiskUsage(free * 2, free, free)
    source = sys.stdin.read()
    sys.argv = sys.argv[1:]
    exec(compile(source, "<runner-preflight>", "exec"), {{"__name__": "__main__"}})
else:
    os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])
'''

    @staticmethod
    def stub_source():
        return r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

args = sys.argv[1:]
evidence = Path(os.environ["TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_EVIDENCE_ROOT"])
smoke = os.environ.get("TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE") == "1"
requested = "smoke" if smoke else "large"
case = os.environ.get("STUB_XCODE_CASE", "valid")
keys = [
    "BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY",
    "BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE",
    "TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY",
    "TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE",
    "TEST_RUNNER_BITMATCH_HARDWARE_APP_WORKFLOW",
    "TEST_RUNNER_BITMATCH_HARDWARE_CONFIG",
    "TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_EVIDENCE_ROOT",
]
with Path(os.environ["STUB_XCODE_CAPTURE"]).open("w") as output:
    json.dump({"args": args, "env": {key: os.environ.get(key) for key in keys}}, output)

test = "Test Case '-[BitMatchTests.PhysicalLargeFileAppMemoryTests testOptInLargeFilePhysicalAppMemory]'"
if case != "missing_test":
    print(test + " started.")
if case == "skip":
    print(test + " skipped (opt-in missing)")
elif case == "wrongclass":
    print("Test Case '-[BitMatchTests.OtherPhysicalTests testOptInLargeFilePhysicalAppMemory]' passed (1.0 seconds)")
elif case == "duplicate":
    print(test + " passed (1.0 seconds)")
    print(test + " passed (1.0 seconds)")
elif case == "pass_and_fail":
    print(test + " passed (1.0 seconds)")
    print(test + " failed (0.1 seconds) (Assertion failed)")
elif case == "misleading_suffix":
    print("Test Case '-[BitMatchTests.PhysicalLargeFileAppMemoryTests testOptInLargeFilePhysicalAppMemoryExtra]' passed (1.0 seconds)")
elif case == "misleading_class_suffix":
    print("Test Case '-[BitMatchTests.PhysicalLargeFileAppMemoryTestsExtra testOptInLargeFilePhysicalAppMemory]' passed (1.0 seconds)")
elif case != "missing_test":
    print(test + " passed (1.0 seconds)")
if case == "execute_failed":
    print("** TEST EXECUTE FAILED **")
elif case == "failed":
    print("** TEST FAILED **")
elif case == "mixed":
    print("** TEST SUCCEEDED **")
    print("** TEST EXECUTE FAILED **")
elif case == "without_building":
    print("** TEST EXECUTE SUCCEEDED **")
else:
    print("** TEST SUCCEEDED **")
if case == "duplicate_success_banner":
    print("** TEST SUCCEEDED **")
elif case == "both_success_banners":
    print("** TEST EXECUTE SUCCEEDED **")
if case == "missing_receipt":
    raise SystemExit(0)

if requested == "smoke":
    sizes = [1, 2, 3, 4, 5, 7, 20, 22]
    sizes = [size * 1048576 for size in sizes]
    byte_count = 64 * 1048576
    label = "smoke64MiB"
else:
    sizes = [2000000000, 3000000000, 4000000000, 5000000000, 7000000000,
             8800000000, 44500000000, 45300000000]
    byte_count = 119600000000
    label = "physical119_6GB"
if case == "inconsistent":
    label = "physical119_6GB" if requested == "smoke" else "smoke64MiB"
    byte_count = 119600000000 if requested == "smoke" else 64 * 1048576

files = [{"name": f"clip-{index:02d}.mov", "size": size, "sha256": "a" * 64}
         for index, size in enumerate(sizes, 1)]
hashes = [{**item} for item in files]
receipt = {
    "complete": case != "incomplete", "outcome": "passed",
    "cleanup": "passed-owned-children-removed", "workload": label,
    "expectedWorkloadBytes": byte_count, "generatedPayloadBytes": byte_count,
    "generatedFiles": files, "sourceBytes": byte_count,
    "sourceInventoryFiles": 8, "selectedFiles": 8, "selectedBytes": byte_count,
    "excludedAppleDoubleFiles": [],
    "resultRows": 8, "verifiedRows": 8, "savedCheckFiles": 8,
    "sourceRehashFiles": 8, "destinationRehashFiles": 8,
    "verifiedSourceAndDestinationFiles": 16,
    "independentlyHashedSource": hashes,
    "independentlyHashedDestination": hashes,
    "automaticReports": ["pdf", "csv", "json"], "sdUsedForTransfer": False,
    "sdOwnerMetadataValidated": True, "pipelinedVerification": True,
    "verificationWorkers": 2, "transferSeconds": 1.0,
    "memory": {"sampleCount": 3, "peakMiB": 500, "missingSample": False,
               "runtimeLimitHit": False},
}
if case == "cleanupfailed":
    receipt["cleanup"] = "failed-owned-children-retained"
evidence.mkdir(parents=True)
(evidence / "large-file-app-memory.json").write_text(json.dumps(receipt))
if case == "nonzero":
    raise SystemExit(65)
'''

    def run_stubbed(self, case="valid", workload="smoke"):
        environment = dict(self.environment, STUB_XCODE_CASE=case)
        return subprocess.run(
            ["bash", str(RUNNER), workload], env=environment, text=True,
            capture_output=True, timeout=15, check=False,
        )

    def test_pass_forwards_opt_in_and_uses_serial_two_job_focused_xcodebuild(self):
        self.environment.update(
            BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY="1",
            BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE="1",
            TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY="1",
            TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE="1",
        )
        result = self.run_stubbed()
        self.assertEqual(result.returncode, 0, result.stderr)
        call = json.loads(self.capture.read_text())
        args, environment = call["args"], call["env"]
        self.assertEqual(environment["TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE"], "1")
        self.assertEqual(environment["TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY"], "0")
        self.assertEqual(environment["BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE"], "0")
        self.assertEqual(environment["BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY"], "0")
        self.assertEqual(environment["TEST_RUNNER_BITMATCH_HARDWARE_APP_WORKFLOW"], "1")
        self.assertEqual(environment["TEST_RUNNER_BITMATCH_HARDWARE_CONFIG"], str(self.config))
        self.assertEqual(args[args.index("-jobs") + 1], "2")
        self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "NO")
        self.assertIn("-only-testing:BitMatchTests/PhysicalLargeFileAppMemoryTests/testOptInLargeFilePhysicalAppMemory", args)

    def test_large_workload_forwards_only_large_opt_in_and_validates_its_receipt(self):
        self.environment.update(
            BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY="1",
            BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE="1",
            TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY="1",
            TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE="1",
        )
        result = self.run_stubbed(workload="large")
        self.assertEqual(result.returncode, 0, result.stderr)
        environment = json.loads(self.capture.read_text())["env"]
        self.assertEqual(environment["TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY"], "1")
        self.assertEqual(environment["TEST_RUNNER_BITMATCH_PHYSICAL_LARGE_FILE_APP_MEMORY_SMOKE"], "0")
        self.assertIn("physical119_6GB", result.stdout)

    def test_accepts_exact_test_and_test_without_building_success_banners(self):
        for case in ("valid", "without_building"):
            with self.subTest(case=case):
                result = self.run_stubbed(case)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_failure_banners_and_mixed_banners_are_rejected(self):
        for case in ("failed", "execute_failed", "mixed"):
            with self.subTest(case=case):
                result = self.run_stubbed(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("successful test banner", result.stderr.lower())

    def test_duplicate_or_conflicting_success_banners_are_rejected(self):
        for case in ("duplicate_success_banner", "both_success_banners"):
            with self.subTest(case=case):
                result = self.run_stubbed(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("exactly one successful test banner", result.stderr.lower())

    def test_nonzero_xcode_status_is_rejected_even_with_success_banner(self):
        result = self.run_stubbed("nonzero")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("status 65", result.stderr.lower())

    def test_complete_receipt_with_failed_cleanup_is_rejected(self):
        result = self.run_stubbed("cleanupfailed")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cleanup", result.stderr.lower())

    def test_skip_with_xcode_success_is_rejected(self):
        result = self.run_stubbed("skip")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("skipped", result.stderr.lower())
        runs = list(self.evidence.iterdir())
        self.assertEqual(len(runs), 1)
        self.assertIn("skipped", (runs[0] / "test.log").read_text().lower())

    def test_missing_receipt_is_rejected(self):
        result = self.run_stubbed("missing_receipt")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("receipt", result.stderr.lower())

    def test_incomplete_receipt_is_rejected(self):
        result = self.run_stubbed("incomplete")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("complete", result.stderr.lower())

    def test_receipt_for_the_other_workload_is_rejected(self):
        result = self.run_stubbed("inconsistent")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("workload", result.stderr.lower())

    def test_same_method_from_wrong_test_class_is_rejected(self):
        result = self.run_stubbed("wrongclass")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("focused xctest", result.stderr.lower())

    def test_missing_or_duplicate_focused_test_is_rejected(self):
        for case in ("missing_test", "duplicate", "pass_and_fail", "misleading_suffix", "misleading_class_suffix"):
            with self.subTest(case=case):
                result = self.run_stubbed(case)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("focused xctest", result.stderr.lower())

    def test_low_space_preflight_refuses_before_xcode_and_keeps_no_build_bypass(self):
        environment = dict(self.environment, STUB_PREFLIGHT_FREE_BYTES="0")
        result = subprocess.run(
            ["bash", str(RUNNER), "smoke"], env=environment, text=True,
            capture_output=True, timeout=15, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("50 GiB", result.stderr)
        self.assertFalse(self.capture.exists(), "Xcode stub must not be invoked below the free-space floor")


if __name__ == "__main__":
    unittest.main()
