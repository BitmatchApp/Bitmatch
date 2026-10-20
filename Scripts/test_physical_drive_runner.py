#!/usr/bin/env python3
"""Mock-only regressions: no drive queries, subprocesses, or media writes."""
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('physical_runner', Path(__file__).with_name('test-physical-drives.py'))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PhysicalDrivePreflightTests(unittest.TestCase):
    def setUp(self):
        self.volume = {'MountPoint': '/Volumes/Fixture', 'VolumeUUID': 'FIXTURE', 'Internal': False,
                       'ParentWholeDisk': 'disk8', 'FilesystemType': 'exfat', 'OSInternalMedia': False,
                       'Writable': True, 'WritableMedia': True, 'WritableVolume': True}
        self.whole = {'WholeDisk': True, 'Internal': False, 'VirtualOrPhysical': 'Physical',
                      'OSInternalMedia': False, 'WritableMedia': True}
        self.boot = {'ParentWholeDisk': 'disk0'}
        self.path = patch.object(runner, 'direct_mount', return_value=Path('/Volumes/Fixture'))
        self.access = patch.object(runner.os, 'access', return_value=True)
        self.path.start(); self.access.start()
        self.addCleanup(self.path.stop); self.addCleanup(self.access.stop)

    def query(self, volume=None, whole=None, boot=None):
        with patch.object(runner, 'disk_info', side_effect=[volume or self.volume, whole or self.whole, boot or self.boot]):
            return runner.physical_volume('explicit selection')

    def test_current_diskutil_keys_without_mounted_or_whole_are_supported(self):
        self.assertEqual(self.query()['parent'], 'disk8')

    def test_boot_capability_does_not_misidentify_a_data_ssd_as_the_startup_disk(self):
        self.assertEqual(self.query(dict(self.volume, Bootable=True))['parent'], 'disk8')

    def test_explicit_removable_secure_digital_media_in_an_internal_reader_is_allowed(self):
        self.assertEqual(self.query(
            dict(self.volume, Internal=True, RemovableMedia=True, BusProtocol='Secure Digital'),
            dict(self.whole, Internal=True, RemovableMedia=True, BusProtocol='Secure Digital'))['parent'], 'disk8')

    def test_internal_fixed_or_non_sd_media_is_refused(self):
        for flags in [dict(Internal=True), dict(Internal=True, RemovableMedia=False, BusProtocol='Secure Digital'),
                      dict(Internal=True, RemovableMedia=True, BusProtocol='PCI-Express'),
                      dict(Internal=True, RemovableMedia=True, BusProtocol='USB')]:
            with self.subTest(flags=flags), self.assertRaises(runner.UnsafeFixture):
                self.query(dict(self.volume, **flags))

    def test_partition_and_whole_device_must_both_prove_internal_reader_exception(self):
        volume = dict(self.volume, Internal=True, RemovableMedia=True, BusProtocol='Secure Digital')
        with self.assertRaises(runner.UnsafeFixture):
            self.query(volume, dict(self.whole, Internal=True, RemovableMedia=False, BusProtocol='Secure Digital'))

    def test_read_only_system_virtual_and_active_boot_devices_are_refused(self):
        for flags in [dict(Writable=False), dict(WritableMedia=False), dict(WritableVolume=False),
                      dict(ReadOnlyMedia=True), dict(SystemImage=True), dict(OSInternalMedia=True),
                      dict(BootVolume=True), dict(APFSVolumeRoles=['System'])]:
            with self.subTest(flags=flags), self.assertRaises(runner.UnsafeFixture):
                self.query(dict(self.volume, **flags))
        for flags in [dict(VirtualOrPhysical='Virtual'), dict(SystemImage=True),
                      dict(OSInternalMedia=True), dict(Internal=True), dict(WritableMedia=False)]:
            with self.subTest(flags=flags), self.assertRaises(runner.UnsafeFixture):
                self.query(whole=dict(self.whole, **flags))
        with self.assertRaises(runner.UnsafeFixture):
            self.query(boot={'ParentWholeDisk': 'disk8'})

    def test_interruption_and_timeout_are_propagated_after_graceful_child_exit(self):
        for exception in [KeyboardInterrupt(), subprocess.TimeoutExpired('mock', 1)]:
            with self.subTest(exception=type(exception).__name__), tempfile.TemporaryDirectory() as temporary:
                child = MagicMock()
                child.pid = 123456
                child.wait.side_effect = [exception, 0]
                child.poll.side_effect = [None, 0]
                run = runner.Run.__new__(runner.Run)
                run.workspace = Path(temporary)
                run.child = None
                with patch.object(runner.subprocess, 'Popen', return_value=child), \
                     patch.object(runner.os, 'killpg', side_effect=ProcessLookupError()), patch('sys.stdout', io.StringIO()):
                    with self.assertRaises(type(exception)):
                        run.command(['never executed'], run.workspace / 'mock.log')
                self.assertIsNone(run.child)


if __name__ == '__main__':
    unittest.main()
