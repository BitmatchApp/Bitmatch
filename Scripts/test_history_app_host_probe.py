#!/usr/bin/env python3
"""Exercise History probe path and non-skipped-success gates without Xcode."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "Scripts" / "test-history-app-host-probe.sh"
TEST_LINE = "Test Case '-[BitMatchTests.HistoryAppHostScaleTests testActualHistoryAppHostScaleProbe]'"


class HistoryProbeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="bitmatch-history-probe-", dir="/private/tmp")
        self.root = Path(self.scratch.name).resolve()
        self.evidence = self.root / "evidence"
        self.derived = self.root / "derived"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.capture = self.root / "xcode-capture.json"
        stub = self.bin / "xcodebuild"
        stub.write_text(self.stub_source())
        stub.chmod(0o755)
        self.environment = dict(os.environ)
        self.environment["PATH"] = str(self.bin) + os.pathsep + self.environment.get("PATH", os.defpath)
        self.environment.update(
            BITMATCH_HISTORY_EVIDENCE_BASE=str(self.evidence),
            BITMATCH_HISTORY_DERIVED_DATA=str(self.derived),
            BITMATCH_HISTORY_ATTEMPTS="100",
            STUB_XCODE_CAPTURE=str(self.capture),
        )

    def tearDown(self):
        self.scratch.cleanup()

    @staticmethod
    def stub_source():
        return f'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path

args = sys.argv[1:]
case = os.environ.get("STUB_XCODE_CASE", "pass")
evidence = Path(os.environ["TEST_RUNNER_BITMATCH_HISTORY_EVIDENCE_ROOT"])
Path(os.environ["STUB_XCODE_CAPTURE"]).write_text(json.dumps({{
    "args": args,
    "evidence": str(evidence),
    "attempts": os.environ.get("TEST_RUNNER_BITMATCH_HISTORY_ATTEMPTS"),
}}))
if case == "skip":
    print({TEST_LINE!r} + " skipped (probe opt-in missing)")
    print("** TEST SUCCEEDED **")
    raise SystemExit(0)
if case == "vacuous":
    print("Test Suite 'Selected tests' passed")
    print("** TEST SUCCEEDED **")
    raise SystemExit(0)
print({TEST_LINE!r} + " passed (1.0 seconds)")
print("** TEST SUCCEEDED **")
receipt = {{
    "complete": True, "cleanupComplete": True,
    "attempts": 100, "resultRows": 10000, "coveredRows": 10000,
    "recoveredRunningAttempts": 1, "durableLegacyRowIDs": 1,
    "queueSummaryRowsBuilt": 8, "historyRenderedPNGBytes": 123,
    "queueRenderedPNGBytes": 456, "missingMemorySample": False,
    "memorySamples": 3, "peakPhysicalFootprintMiB": 400,
    "maximumMainActorDelayMilliseconds": 10.0,
    "maximumMainActorDelayMillisecondsByPhase": {{
        "fixturePreparation": 1.0, "historySearch": 2.0,
        "historyViewLayout": 3.0, "queueViewLayout": 4.0,
    }},
}}
(evidence / "history-app-host-probe-stub.json").write_text(json.dumps(receipt))
print("HISTORY_APP_HOST_PROBE {{}}")
'''

    def run_runner(self, **overrides):
        environment = dict(self.environment, **overrides)
        return subprocess.run(
            ["bash", str(RUNNER)], env=environment, text=True,
            capture_output=True, timeout=15, check=False,
        )

    def test_canonical_paths_reach_serial_stubbed_xcode(self):
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        capture = json.loads(self.capture.read_text())
        self.assertEqual(Path(capture["evidence"]).parent, self.evidence.resolve())
        self.assertEqual(capture["attempts"], "100")
        args = capture["args"]
        self.assertEqual(args[args.index("-jobs") + 1], "2")
        self.assertEqual(args[args.index("-parallel-testing-enabled") + 1], "NO")
        self.assertIn("-only-testing:BitMatchTests/HistoryAppHostScaleTests/testActualHistoryAppHostScaleProbe", args)

    def test_tmp_alias_is_accepted_when_it_resolves_inside_private_tmp(self):
        alias = Path("/tmp") / self.evidence.relative_to(Path("/private/tmp"))
        self.environment["BITMATCH_HISTORY_EVIDENCE_BASE"] = str(alias)
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.capture.exists())

    def test_symlinked_evidence_escape_is_refused_before_missing_target_creation(self):
        with tempfile.TemporaryDirectory(prefix="bitmatch-history-outside-", dir="/private/var/tmp") as outside:
            target = Path(outside) / "missing-child"
            link = self.root / "evidence-link"
            link.symlink_to(Path(outside), target_is_directory=True)
            self.environment["BITMATCH_HISTORY_EVIDENCE_BASE"] = str(link / "missing-child")
            result = self.run_runner()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("private/tmp", result.stderr)
            self.assertFalse(target.exists())
            self.assertFalse(self.capture.exists())

    def test_symlinked_derived_data_escape_is_refused_before_missing_target_creation(self):
        with tempfile.TemporaryDirectory(prefix="bitmatch-history-outside-", dir="/private/var/tmp") as outside:
            target = Path(outside) / "missing-child"
            link = self.root / "derived-link"
            link.symlink_to(Path(outside), target_is_directory=True)
            self.environment["BITMATCH_HISTORY_DERIVED_DATA"] = str(link / "missing-child")
            result = self.run_runner()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("private/tmp", result.stderr)
            self.assertFalse(target.exists())
            self.assertFalse(self.capture.exists())

    def test_parent_traversal_outside_private_tmp_is_refused(self):
        self.environment["BITMATCH_HISTORY_EVIDENCE_BASE"] = "/private/tmp/../outside"
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("private/tmp", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_skipped_xctest_with_xcode_success_is_rejected_and_log_retained(self):
        result = self.run_runner(STUB_XCODE_CASE="skip")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("focused app-host probe", result.stderr.lower())
        run_roots = list(self.evidence.glob("app-host-*"))
        self.assertEqual(len(run_roots), 1)
        self.assertIn("skipped", (run_roots[0] / "test.log").read_text().lower())

    def test_vacuous_xcode_success_without_focused_test_is_rejected(self):
        result = self.run_runner(STUB_XCODE_CASE="vacuous")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("focused app-host probe", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
