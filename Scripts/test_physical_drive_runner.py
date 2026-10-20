#!/usr/bin/env python3
"""Mocks and tiny owned host fixtures; no drive queries or physical-media writes."""
import contextlib
import importlib.util
import io
import json
import os
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


class PhysicalFixtureCleanupTests(unittest.TestCase):
    marker = '.bitmatch-validation-owned.json'

    @contextlib.contextmanager
    def fixture(self):
        with tempfile.TemporaryDirectory(prefix='bitmatch-cleanup-test-', dir='/private/tmp') as temporary:
            parent = Path(temporary)
            root = parent / 'owned'
            root.mkdir()
            (root / self.marker).write_bytes(b'owned test marker')
            parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                yield parent, root, parent_fd
            finally:
                os.close(parent_fd)

    def remove(self, root, parent_fd):
        item = root.lstat()
        runner.remove_tree_at(parent_fd, root.name, (item.st_dev, item.st_ino), item.st_dev)

    def cached_entries(self, root, names):
        with os.scandir(root) as entries:
            by_name = {entry.name: entry for entry in entries}
        context = MagicMock()
        context.__enter__.return_value = iter(by_name[name] for name in names)
        context.__exit__.return_value = False
        return context

    def test_cached_companion_autoremoved_with_principal_is_skipped(self):
        with self.fixture() as (_, root, parent_fd):
            (root / 'empty.bin').write_bytes(b'')
            (root / '._empty.bin').write_bytes(b'generated companion')
            entries = self.cached_entries(root, [self.marker, 'empty.bin', '._empty.bin'])
            unlink = os.unlink
            deleted = []

            def unlink_with_metadata(name, *, dir_fd):
                deleted.append(name)
                unlink(name, dir_fd=dir_fd)
                if name == 'empty.bin':
                    # Model macOS removing the companion before its cached stat.
                    unlink('._empty.bin', dir_fd=dir_fd)

            with patch.object(runner.os, 'scandir', return_value=entries), \
                 patch.object(runner.os, 'unlink', side_effect=unlink_with_metadata):
                self.remove(root, parent_fd)
            self.assertFalse(root.exists())
            self.assertEqual(deleted, ['empty.bin', self.marker])

    def test_companion_disappearing_between_stat_and_unlink_is_skipped(self):
        with self.fixture() as (_, root, parent_fd):
            (root / '._clip.bin').write_bytes(b'generated companion')
            entries = self.cached_entries(root, [self.marker, '._clip.bin'])
            unlink = os.unlink

            def unlink_after_metadata_removal(name, *, dir_fd):
                if name == '._clip.bin':
                    unlink(name, dir_fd=dir_fd)
                unlink(name, dir_fd=dir_fd)

            with patch.object(runner.os, 'scandir', return_value=entries), \
                 patch.object(runner.os, 'unlink', side_effect=unlink_after_metadata_removal):
                self.remove(root, parent_fd)
            self.assertFalse(root.exists())

    def test_root_marker_stays_until_every_nested_child_has_been_removed(self):
        with self.fixture() as (_, root, parent_fd):
            child = root / 'nested'
            child.mkdir()
            (child / 'payload').write_bytes(b'tiny host fixture')
            (child / self.marker).write_bytes(b'ordinary nested filename')
            unlink = os.unlink
            root_inode = root.stat().st_ino
            saw_root_marker = False

            def checked_unlink(name, *, dir_fd):
                nonlocal saw_root_marker
                if name == self.marker and os.fstat(dir_fd).st_ino == root_inode:
                    self.assertEqual([p.name for p in root.iterdir()], [self.marker])
                    saw_root_marker = True
                unlink(name, dir_fd=dir_fd)

            with patch.object(runner.os, 'unlink', side_effect=checked_unlink):
                self.remove(root, parent_fd)
            self.assertTrue(saw_root_marker)
            self.assertFalse(root.exists())

    def test_unknown_cached_file_absence_stops_before_marker_removal(self):
        with self.fixture() as (_, root, parent_fd):
            missing = root / 'unknown.bin'
            missing.write_bytes(b'not metadata')
            entries = self.cached_entries(root, [self.marker, missing.name])
            missing.unlink()
            with patch.object(runner.os, 'scandir', return_value=entries):
                with self.assertRaises(FileNotFoundError):
                    self.remove(root, parent_fd)
            self.assertEqual((root / self.marker).read_bytes(), b'owned test marker')

    def test_unknown_file_disappearing_at_unlink_is_not_ignored(self):
        with self.fixture() as (_, root, parent_fd):
            (root / 'unknown.bin').write_bytes(b'not metadata')
            entries = self.cached_entries(root, [self.marker, 'unknown.bin'])
            unlink = os.unlink

            def unlink_after_unknown_removal(name, *, dir_fd):
                if name == 'unknown.bin':
                    unlink(name, dir_fd=dir_fd)
                unlink(name, dir_fd=dir_fd)

            with patch.object(runner.os, 'scandir', return_value=entries), \
                 patch.object(runner.os, 'unlink', side_effect=unlink_after_unknown_removal):
                with self.assertRaises(FileNotFoundError):
                    self.remove(root, parent_fd)
            self.assertEqual((root / self.marker).read_bytes(), b'owned test marker')

    def test_bare_dot_underscore_is_not_a_companion_exception(self):
        with self.fixture() as (_, root, parent_fd):
            unknown = root / '._'
            unknown.write_bytes(b'not a companion filename')
            entries = self.cached_entries(root, [self.marker, unknown.name])
            unknown.unlink()
            with patch.object(runner.os, 'scandir', return_value=entries):
                with self.assertRaises(FileNotFoundError):
                    self.remove(root, parent_fd)
            self.assertTrue((root / self.marker).is_file())

    def test_wrong_directory_identity_or_device_preserves_sentinel(self):
        for change in ('inode', 'device'):
            with self.subTest(change=change), self.fixture() as (_, root, parent_fd):
                sentinel = root / 'sentinel'
                sentinel.write_bytes(b'unchanged')
                info = root.stat()
                identity = (info.st_dev, info.st_ino + (change == 'inode'))
                device = info.st_dev + (change == 'device')
                with self.assertRaises(runner.UnsafeFixture):
                    runner.remove_tree_at(parent_fd, root.name, identity, device)
                self.assertEqual(sentinel.read_bytes(), b'unchanged')
                self.assertTrue((root / self.marker).is_file())

    def test_root_symlink_is_refused_without_touching_its_target(self):
        with self.fixture() as (parent, root, parent_fd):
            (root / 'sentinel').write_bytes(b'unchanged')
            link = parent / 'link'
            link.symlink_to(root, target_is_directory=True)
            info = root.stat()
            with self.assertRaises(OSError):
                runner.remove_tree_at(parent_fd, link.name, (info.st_dev, info.st_ino), info.st_dev)
            self.assertEqual((root / 'sentinel').read_bytes(), b'unchanged')
            self.assertTrue(link.is_symlink())

    def test_child_symlink_is_unlinked_without_following_it(self):
        with self.fixture() as (parent, root, parent_fd):
            outside = parent / 'outside'
            outside.mkdir()
            sentinel = outside / 'sentinel'
            sentinel.write_bytes(b'unchanged')
            (root / 'link').symlink_to(outside, target_is_directory=True)
            self.remove(root, parent_fd)
            self.assertFalse(root.exists())
            self.assertEqual(sentinel.read_bytes(), b'unchanged')

    def test_replaced_named_root_retains_the_replacement(self):
        with self.fixture() as (parent, root, parent_fd):
            (root / 'payload').write_bytes(b'owned payload')
            info = root.stat()
            original_stat = os.stat
            replaced = False

            def replace_before_named_check(path, *args, **kwargs):
                nonlocal replaced
                if path == root.name and kwargs.get('dir_fd') == parent_fd and not replaced:
                    root.rename(parent / 'retained-original')
                    root.mkdir()
                    (root / 'sentinel').write_bytes(b'replacement stays')
                    replaced = True
                return original_stat(path, *args, **kwargs)

            with patch.object(runner.os, 'stat', side_effect=replace_before_named_check):
                with self.assertRaises(runner.UnsafeFixture):
                    runner.remove_tree_at(parent_fd, root.name, (info.st_dev, info.st_ino), info.st_dev)
            self.assertTrue(replaced)
            self.assertEqual((root / 'sentinel').read_bytes(), b'replacement stays')


class PhysicalFailureRetentionTests(unittest.TestCase):
    @contextlib.contextmanager
    def owned_run(self, image=False):
        with tempfile.TemporaryDirectory(prefix='bitmatch-retention-test-', dir='/private/tmp') as temporary:
            workspace = Path(temporary)
            root = workspace / 'owned-volume-root'
            root.mkdir()
            (root / '.bitmatch-validation-owned.json').write_bytes(b'tiny owned host marker')
            (root / 'evidence.bin').write_bytes(b'failed bytes retained')
            item = root.stat()
            run = runner.Run.__new__(runner.Run)
            run.workspace, run.build = workspace, workspace / 'build'
            run.child = run.image = run.image_host = None
            run.roots = {'ssdA': root}
            run.identities = {'ssdA': (item.st_dev, item.st_ino)}
            run.config = {'volumes': {}}
            run.warnings, run.removed = [], set()
            run.validate_root = MagicMock()
            run.command = MagicMock()
            run.image_attachments = MagicMock(return_value=[])
            if image:
                run.image_host = 'ssdA'
                run.image = root / 'Owned.sparseimage'
                run.image.write_bytes(b'tiny fake image; no actual filesystem')
                info = run.image.stat()
                run.image_identity = (info.st_dev, info.st_ino)
                run.image_mount = workspace / 'owned-image-mount'
                run.image_mount.mkdir()
                run.attach_started = run.attach_confirmed = True
            yield run, root

    # Plant: remove cleanup's preserve_fixtures return; failed bytes must remain.
    def test_failed_run_preserves_marker_payload_and_build(self):
        with self.owned_run() as (run, root), patch.object(runner, 'mounted_paths', return_value=[Path('/')]):
            run.build.mkdir()
            (run.build / 'inspection.bin').write_bytes(b'owned test build')
            run.cleanup(preserve_fixtures=True)
            self.assertTrue((root / '.bitmatch-validation-owned.json').is_file())
            self.assertEqual((root / 'evidence.bin').read_bytes(), b'failed bytes retained')
            self.assertEqual((run.build / 'inspection.bin').read_bytes(), b'owned test build')
            self.assertEqual(run.removed, set())
            self.assertEqual(run.warnings, [])

    def test_passing_run_keeps_descriptor_checked_cleanup(self):
        with self.owned_run() as (run, root), patch.object(runner, 'mounted_paths', return_value=[Path('/')]):
            run.cleanup()
            self.assertFalse(root.exists())
            self.assertEqual(run.removed, {'ssdA'})
            self.assertEqual(run.warnings, [])

    def test_live_child_retains_everything_without_querying_or_detaching_image(self):
        with self.owned_run(image=True) as (run, root):
            run.child = MagicMock()
            run.child.poll.return_value = None
            run.cleanup(preserve_fixtures=True)
            run.validate_root.assert_not_called()
            run.image_attachments.assert_not_called()
            run.command.assert_not_called()
            self.assertTrue(run.image.is_file())
            self.assertTrue((root / 'evidence.bin').is_file())
            self.assertEqual(run.removed, set())
            self.assertIn('still active', run.warnings[0])

    def test_settled_failure_detaches_only_owned_image_and_preserves_backing_evidence(self):
        with self.owned_run(image=True) as (run, root):
            run.image_attachments.side_effect = [[{'system-entities': [{'mount-point': str(run.image_mount)}]}], []]
            with patch.object(runner, 'mounted_paths', side_effect=[[Path('/'), run.image_mount], [Path('/')]]):
                run.cleanup(preserve_fixtures=True)
            run.command.assert_called_once_with(
                ['/usr/bin/hdiutil', 'detach', '-quiet', str(run.image_mount)],
                run.workspace / 'image-detach.log', timeout=120)
            self.assertEqual(run.image.read_bytes(), b'tiny fake image; no actual filesystem')
            self.assertTrue((root / '.bitmatch-validation-owned.json').is_file())
            self.assertTrue((root / 'evidence.bin').is_file())
            self.assertEqual(run.removed, set())
            self.assertEqual(run.warnings, [])

    def test_unrelated_image_attachment_is_never_detached_or_removed(self):
        with self.owned_run(image=True) as (run, root):
            run.image_attachments.return_value = [{'system-entities': [{'mount-point': '/unrelated-mount'}]}]
            run.cleanup(preserve_fixtures=True)
            run.command.assert_not_called()
            self.assertTrue(run.image.is_file())
            self.assertTrue((root / 'evidence.bin').is_file())
            self.assertEqual(run.removed, set())
            self.assertIn('unexpected mountpoints', run.warnings[0])

    def test_replaced_backing_image_is_never_detached_or_removed(self):
        with self.owned_run(image=True) as (run, root):
            run.image_identity = (run.image_identity[0], run.image_identity[1] + 1)
            run.cleanup(preserve_fixtures=True)
            run.command.assert_not_called()
            run.image_attachments.assert_not_called()
            self.assertTrue(run.image.is_file())
            self.assertTrue((root / 'evidence.bin').is_file())
            self.assertEqual(run.removed, set())
            self.assertIn('identity changed', run.warnings[0])

    def test_main_retains_failed_and_interrupted_runs_but_cleans_after_passing_validation(self):
        for failure in (None, runner.UnsafeFixture('synthetic test failure'), KeyboardInterrupt()):
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory(prefix='bitmatch-main-retention-') as temporary:
                fake = MagicMock()
                fake.workspace = Path(temporary)
                fake.warnings, fake.passed, fake.roots, fake.removed = [], [], {}, set()
                fake.execute.side_effect = failure
                volumes = [{'path': Path('/Volumes/' + role), 'uuid': role, 'parent': 'disk-' + role,
                            'filesystem': 'exfat'} for role in ('sd', 'ssdA', 'ssdB')]
                arguments = ['physical-runner', '--source-volume', '/Volumes/sd',
                             '--backup-volume', '/Volumes/ssdA', '--backup-volume', '/Volumes/ssdB']
                with patch.object(sys, 'argv', arguments), patch.object(runner.platform, 'system', return_value='Darwin'), \
                     patch.object(runner, 'physical_volume', side_effect=volumes), \
                     patch.object(runner.shutil, 'disk_usage', return_value=MagicMock(free=100 * 1024**3)), \
                     patch.object(runner, 'Run', return_value=fake), patch.object(runner.signal, 'signal'), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    status = runner.main()
                fake.cleanup.assert_called_once_with(preserve_fixtures=failure is not None)
                self.assertEqual(status, 0 if failure is None else 1)
                summary = json.loads((fake.workspace / 'summary.json').read_text())
                self.assertEqual(summary['fixturePolicy'],
                                 'cleanupAfterPassingValidation' if failure is None else 'retainFailedValidation')


if __name__ == '__main__':
    unittest.main()
