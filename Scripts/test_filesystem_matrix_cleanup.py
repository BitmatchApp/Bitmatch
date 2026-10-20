#!/usr/bin/env python3
"""Exercise mounted-matrix cleanup failures without mounting any filesystem."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


class FilesystemMatrixCleanupTests(unittest.TestCase):
    def exercise(self, detach_fails=False, table_fails=False, finish_fails=False):
        temporary = tempfile.TemporaryDirectory(prefix="bitmatch-matrix-cleanup-")
        self.addCleanup(temporary.cleanup)
        parent = Path(temporary.name)
        pair = parent / "owned"
        pair.mkdir()
        (pair / ".bitmatch-fault-matrix-owned").touch()
        sentinel = pair / "fixture.bin"
        sentinel.write_bytes(b"owned fixture")
        unrelated = parent / "unrelated.bin"
        unrelated.write_bytes(b"leave me alone")
        source = (Path(__file__).parent / "test-filesystem-fault-matrix.sh").read_text()
        cleanup = source[source.index("cleanup() {"):source.index("\ntrap cleanup EXIT")]
        environment = dict(os.environ, PAIR=str(pair), DETACH_FAIL=str(int(detach_fails)),
                           TABLE_FAIL=str(int(table_fails)), FINISH_FAIL=str(int(finish_fails)),
                           TRACE=str(parent / "trace"))
        script = "\n".join([
            "set -euo pipefail", "attached=1", 'MOUNTS=("$PAIR/mount")',
            'mount() { [[ "$TABLE_FAIL" == 0 ]] || return 1; if [[ "$attached" == 1 ]]; then echo "fixture on $PAIR/mount (exfat)"; fi; }',
            'hdiutil() { echo detach >> "$TRACE"; [[ "$DETACH_FAIL" == 0 ]] || return 1; attached=0; }',
            'finish_evidence() { echo "status=$1" >> "$TRACE"; [[ "$FINISH_FAIL" == 0 ]]; }',
            cleanup, "trap cleanup EXIT", "exit 0",
        ])
        result = subprocess.run(["/bin/bash", "-c", script], env=environment,
                                capture_output=True, text=True)
        self.assertEqual(unrelated.read_bytes(), b"leave me alone")
        return pair, sentinel, parent / "trace", result

    def test_success_detaches_before_removing_owned_files(self):
        pair, _, trace, result = self.exercise()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(pair.exists())
        self.assertEqual(trace.read_text().splitlines(), ["detach", "status=0"])

    def test_failed_detach_retains_mounted_files_and_fails(self):
        pair, sentinel, trace, result = self.exercise(detach_fails=True)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(pair.exists())
        self.assertEqual(sentinel.read_bytes(), b"owned fixture")
        self.assertIn("status=1", trace.read_text())

    def test_unreadable_mount_table_retains_files_and_fails(self):
        pair, sentinel, trace, result = self.exercise(table_fails=True)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(pair.exists())
        self.assertEqual(sentinel.read_bytes(), b"owned fixture")
        self.assertNotIn("detach", trace.read_text())

    def test_receipt_failure_remains_a_failed_run_after_cleanup(self):
        pair, _, _, result = self.exercise(finish_fails=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(pair.exists())


if __name__ == "__main__":
    unittest.main()
