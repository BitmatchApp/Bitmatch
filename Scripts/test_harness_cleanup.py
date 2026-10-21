#!/usr/bin/env python3
"""Fault-injected cleanup checks: no Xcode builds, mounts, or physical media."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class HarnessCleanupTests(unittest.TestCase):
    def run_cleanup(self, harness, injected, evidence_is_file=False):
        fixture = tempfile.TemporaryDirectory(prefix='bitmatch-cleanup-check.')
        self.addCleanup(fixture.cleanup)
        root = Path(fixture.name)
        work = root / 'work'
        work.mkdir()
        evidence = root / 'evidence'
        if evidence_is_file:
            evidence.write_text('blocks metadata directory')
        else:
            evidence.mkdir()
        marker = work / '.bitmatch-marker'
        marker.touch()
        result = work / 'soak-result.json'
        result.write_text('{"completedIterations":1}')
        source = (SCRIPTS / harness).read_text()
        cleanup = source[source.index('cleanup() {'):source.index('\ntrap cleanup EXIT')]
        environment = dict(os.environ, WORK=str(work), MARKER=str(marker),
                           HARNESS_MARKER=str(marker), RESULT=str(result),
                           EVIDENCE=str(evidence), ATTACHED='1',
                           MOUNT_CANONICAL=str(root / 'fake-mount'),
                           TRACE=str(root / 'trace'))
        script = '\n'.join([
            'set -euo pipefail', 'source "$1"',
            'is_fault_volume_mounted() { return 1; }',
            'hdiutil() { echo detached >> "$TRACE"; }',
            injected, cleanup, 'trap cleanup EXIT', 'exit 0'])
        run = subprocess.run(['bash', '-c', script, 'bash', str(SCRIPTS / 'harness_evidence.sh')],
                             env=environment, capture_output=True, text=True)
        return root, work, result, run

    def test_failed_result_copy_preserves_original(self):
        root, work, result, run = self.run_cleanup('run_soak_tests.sh', 'cp() { return 1; }')
        self.assertEqual(run.returncode, 1)
        self.assertTrue(result.exists())
        self.assertEqual(result.read_text(), '{"completedIterations":1}')
        self.assertTrue((work / '.bitmatch-marker').exists())
        self.assertFalse((root / 'evidence/soak-result.json').exists())
        self.assertIn(str(work), run.stderr)
        self.assertIn('exit_status=1', (root / 'evidence/environment.txt').read_text())

    def test_configuration_removal_failure_still_detaches(self):
        root, work, result, run = self.run_cleanup(
            'run_apfs_fault_tests.sh', 'remove_harness_test_run() { return 1; }')
        self.assertEqual(run.returncode, 1)
        self.assertEqual((root / 'trace').read_text().strip(), 'detached')
        self.assertFalse(work.exists())
        self.assertIn('exit_status=1', (root / 'evidence/environment.txt').read_text())

    def test_metadata_failure_returns_failure_after_detachment(self):
        root, work, result, run = self.run_cleanup('run_apfs_fault_tests.sh', '', True)
        self.assertEqual(run.returncode, 1)
        self.assertTrue((root / 'trace').exists())
        self.assertFalse(work.exists())
        self.assertIn('Unable to finalize evidence metadata', run.stderr)

    def test_work_removal_failure_still_finalizes(self):
        root, work, result, run = self.run_cleanup('run_soak_tests.sh', 'rm() { return 1; }')
        self.assertEqual(run.returncode, 1)
        self.assertTrue(work.exists())
        self.assertIn('exit_status=1', (root / 'evidence/environment.txt').read_text())


if __name__ == '__main__':
    unittest.main()
