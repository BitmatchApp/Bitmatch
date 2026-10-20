#!/usr/bin/env python3
"""Run the engine's opt-in physical-drive tests in new, marked folders.

Never formats or ejects a physical drive. Logs/config stay in /private/tmp.
The large case writes 119.6 GB and performs several full rereads. At an
illustrative (not measured) 40 MB/s, 478.4 GB of destination I/O takes 3.3 h.
A fast exFAT image keeps the file sizes but shares its selected host SSD.
On the large source SSD it is not an independent backup. An image never
adds a separate drive, USB bridge, or power-loss test.
Requires Python with descriptor-relative filesystem APIs (e.g. Homebrew
Python); older Framework Python builds are rejected before touching media.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import uuid


class UnsafeFixture(RuntimeError):
    pass


def plist_command(*args):
    result = subprocess.run(list(args), check=True, capture_output=True, timeout=30)
    return plistlib.loads(result.stdout)


def disk_info(path):
    return plist_command('/usr/sbin/diskutil', 'info', '-plist', str(path))


def direct_mount(value):
    path = Path(value).absolute()
    if path.parent != Path('/Volumes') or path.resolve(strict=True) != path or path.is_symlink():
        raise UnsafeFixture('Use a direct /Volumes/<name> mount, without symlink aliases.')
    return path


def parent_disks(info):
    parent = info.get('ParentWholeDisk')
    container = info.get('APFSContainerReference')
    if container:
        containers = plist_command('/usr/sbin/diskutil', 'apfs', 'list', '-plist').get('Containers', [])
        stores = [store for item in containers if item.get('ContainerReference') == container
                  for store in item.get('PhysicalStores', [])]
        parents = {disk_info(store['DeviceIdentifier']).get('ParentWholeDisk') for store in stores}
        if not parents or None in parents:
            raise UnsafeFixture('Cannot establish the APFS physical stores.')
        return parents
    if not parent:
        raise UnsafeFixture('Cannot establish the physical ParentWholeDisk.')
    return {parent}


def removable_sd_reader(info):
    return (info.get('Internal') is True and info.get('RemovableMedia') is True
            and info.get('BusProtocol') == 'Secure Digital' and info.get('OSInternalMedia') is False
            and not info.get('SystemImage'))


def physical_volume(value):
    path = direct_mount(value)
    info = disk_info(path)
    roles = info.get('APFSVolumeRoles', info.get('APFSVolumeRole', []))
    roles = [roles] if isinstance(roles, str) else roles
    reader = removable_sd_reader(info)
    if (info.get('Mounted') is False or info.get('MountPoint') != str(path)
            or not info.get('VolumeUUID') or (info.get('Internal') is not False and not reader)
            or info.get('ReadOnlyMedia') or info.get('ReadOnlyVolume')
            or any(info.get(key) is False for key in ('Writable', 'WritableMedia', 'WritableVolume'))
            or info.get('BootVolume') or info.get('SystemImage') or info.get('OSInternalMedia')
            or any(str(role).lower() not in ('none', '') for role in roles)
            or not os.access(path, os.W_OK | os.X_OK)):
        raise UnsafeFixture('Use writable external data media or an explicitly selected removable SD card.')
    parents = parent_disks(info)
    if len(parents) != 1:
        raise UnsafeFixture('A selected volume must resolve to exactly one physical store.')
    parent = next(iter(parents))
    whole = disk_info(parent)
    if (not whole.get('WholeDisk', whole.get('Whole'))
            or (whole.get('Internal') is not False and not (reader and removable_sd_reader(whole)))
            or str(whole.get('VirtualOrPhysical', '')).lower() != 'physical'
            or whole.get('DiskImage') or whole.get('BootVolume') or whole.get('SystemImage')
            or whole.get('OSInternalMedia') or whole.get('ReadOnlyMedia')
            or any(whole.get(key) is False for key in ('Writable', 'WritableMedia'))):
        raise UnsafeFixture('Virtual, internal, or ambiguous physical media is refused.')
    # Bootable is a capability flag, including on some ExFAT data SSDs.
    # Reject the actual startup device instead of inferring it from that flag.
    if parent in parent_disks(disk_info('/')):
        raise UnsafeFixture('The active startup physical disk cannot be used for validation.')
    return {'path': path, 'uuid': info['VolumeUUID'], 'parent': parent,
            'filesystem': info.get('FilesystemType', info.get('FileSystemPersonality', ''))}


def mounted_paths():
    output = subprocess.check_output(['/sbin/mount'], text=True, timeout=30)
    paths = []
    for line in output.splitlines():
        if ' on ' not in line or ' (' not in line:
            raise UnsafeFixture('Cannot parse the mount table; retaining fixtures.')
        paths.append(Path(line.split(' on ', 1)[1].rsplit(' (', 1)[0]))
    if Path('/') not in paths:
        raise UnsafeFixture('The mount table is incomplete; retaining fixtures.')
    return paths


def below(path, root):
    return path == root or root in path.parents


def require_execution(log, method):
    text = log.read_text(errors='replace')
    rows = re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures', text)
    if (not rows or tuple(int(x or 0) for x in rows[-1]) != (1, 0, 0)
            or not re.search(r"Test Case '-\[[^\]]+ " + re.escape(method) + r"\]' passed", text)):
        raise UnsafeFixture('The requested XCTest did not execute and pass exactly once: ' + str(log))


def remove_tree_at(parent_fd, name, identity, device):
    """Descriptor-relative removal; never follows links or crosses a mount."""
    fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    try:
        current = os.fstat(fd)
        if (current.st_dev, current.st_ino) != identity or current.st_dev != device:
            raise UnsafeFixture('Fixture directory identity changed; retaining it.')
        with os.scandir(fd) as entries:
            ordered = sorted(entries, key=lambda item: item.name == '.bitmatch-validation-owned.json')
            for entry in ordered:
                try:
                    item = entry.stat(follow_symlinks=False)
                except FileNotFoundError:
                    # macOS can remove a companion when its principal is unlinked.
                    if entry.name.startswith('._') and len(entry.name) > 2:
                        continue
                    raise
                if stat.S_ISDIR(item.st_mode):
                    remove_tree_at(fd, entry.name, (item.st_dev, item.st_ino), device)
                else:
                    try:
                        os.unlink(entry.name, dir_fd=fd)
                    except FileNotFoundError:
                        if not (entry.name.startswith('._') and len(entry.name) > 2):
                            raise
        named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (named.st_dev, named.st_ino) != identity:
            raise UnsafeFixture('Fixture name was replaced; retaining replacement.')
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=parent_fd)


class Run:
    def __init__(self, volumes, large, image_host):
        self.volumes, self.large, self.image_host = volumes, large, image_host
        self.nonce = str(uuid.uuid4())
        self.workspace = Path(tempfile.mkdtemp(prefix='bitmatch-physical-', dir='/private/tmp'))
        self.root_name = 'BitMatch-validation-' + dt.datetime.now().strftime('%Y%m%d-') + self.nonce
        self.config = {'nonce': self.nonce, 'volumes': {}}
        self.roots, self.identities = {}, {}
        self.removed = set()
        self.image = self.image_mount = self.child = None
        self.image_identity = None
        self.attach_started = self.attach_confirmed = False
        self.warnings = []
        self.passed = []
        self.project = Path(__file__).resolve().parent.parent
        self.build = self.workspace / 'build'
        self.swift = ['/usr/bin/xcrun', 'swift']
        apple = subprocess.run(['/usr/sbin/sysctl', '-n', 'hw.optional.arm64'], capture_output=True, text=True)
        if apple.returncode == 0 and apple.stdout.strip() == '1':
            self.swift = ['/usr/bin/arch', '-arm64'] + self.swift

    def command(self, args, log, env=None, timeout=None):
        print('Running ' + log.name + ' — receipts: ' + str(self.workspace), flush=True)
        with log.open('wb') as output:
            self.child = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                                          env=env, start_new_session=True)
            try:
                status = self.child.wait(timeout=timeout)
            finally:
                if self.child.poll() is None:
                    for sig in (signal.SIGINT, signal.SIGTERM):
                        try:
                            os.killpg(self.child.pid, sig)
                        except ProcessLookupError:
                            pass  # The child exited between poll and signal.
                        try:
                            self.child.wait(timeout=10)
                            break
                        except subprocess.TimeoutExpired:
                            pass
                if self.child.poll() is not None:
                    self.child = None
        if status != 0:
            raise UnsafeFixture('Command failed; inspect ' + str(log))

    def make_root(self, key, mount, volume_uuid):
        root = mount / self.root_name
        root.mkdir(mode=0o700)  # No existing directory is ever adopted.
        self.roots[key] = root
        item = root.lstat()
        self.identities[key] = (item.st_dev, item.st_ino)
        record = {'nonce': self.nonce, 'root': str(root), 'mount': str(mount), 'volumeUUID': volume_uuid}
        marker = root / '.bitmatch-validation-owned.json'
        fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(record, stream)
            stream.flush()
            os.fsync(stream.fileno())
        directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory_fd)
            item = os.fstat(directory_fd)
            named = root.lstat()
            if (item.st_dev, item.st_ino) != (named.st_dev, named.st_ino):
                raise UnsafeFixture('Fixture root changed while saving its ownership marker.')
            self.identities[key] = (item.st_dev, item.st_ino)
        finally:
            os.close(directory_fd)
        self.config['volumes'][key] = record

    def validate_root(self, key):
        root, record = self.roots[key], self.config['volumes'].get(key)
        if not record or root.parent != Path(record['mount']):
            raise UnsafeFixture('An unmarked fixture root is retained.')
        current = disk_info(root.parent)
        if current.get('VolumeUUID', '').casefold() != record['volumeUUID'].casefold():
            raise UnsafeFixture('Fixture volume UUID changed; retaining it.')
        fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            item = os.fstat(fd)
            if (item.st_dev, item.st_ino) != self.identities[key]:
                raise UnsafeFixture('Fixture root was replaced; retaining it.')
            marker_fd = os.open('.bitmatch-validation-owned.json', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
            with os.fdopen(marker_fd, 'rb') as stream:
                if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode) or os.fstat(stream.fileno()).st_size > 4096:
                    raise UnsafeFixture('Fixture marker is not a bounded regular file.')
                raw = stream.read(4097)
                if len(raw) > 4096 or json.loads(raw) != record:
                    raise UnsafeFixture('Fixture marker changed; retaining it.')
        finally:
            os.close(fd)

    def image_attachments(self):
        images = plist_command('/usr/bin/hdiutil', 'info', '-plist').get('images', [])
        return [entry for entry in images if entry.get('image-path') == str(self.image)]

    def prepare_image(self):
        key = self.image_host
        self.validate_root(key)
        self.image = self.roots[key] / 'LargeDestination.sparseimage'
        self.image_mount = self.workspace / 'large-mount'
        self.image_mount.mkdir(mode=0o700)
        self.command(['/usr/bin/hdiutil', 'create', '-quiet', '-size', '160g', '-type', 'SPARSE',
                      '-fs', 'ExFAT', '-volname', 'BMLARGE', '-o', str(self.image)], self.workspace / 'image-create.log', timeout=120)
        self.validate_root(key)
        item = self.image.lstat()
        if not stat.S_ISREG(item.st_mode) or item.st_dev != self.identities[key][0]:
            raise UnsafeFixture('The image must be a new regular file on its selected physical volume.')
        self.image_identity = (item.st_dev, item.st_ino)
        self.attach_started = True
        self.command(['/usr/bin/hdiutil', 'attach', '-quiet', '-nobrowse', '-mountpoint',
                      str(self.image_mount), str(self.image)], self.workspace / 'image-attach.log', timeout=120)
        attachments = self.image_attachments()
        points = [Path(entity['mount-point']) for image in attachments
                  for entity in image.get('system-entities', []) if entity.get('mount-point')]
        if points != [self.image_mount] or self.image_mount not in mounted_paths():
            raise UnsafeFixture('Unexpected image attachment; retaining its host root.')
        info = disk_info(self.image_mount)
        if not info.get('VolumeUUID') or info.get('MountPoint') != str(self.image_mount):
            raise UnsafeFixture('Cannot identify the owned image volume.')
        self.attach_confirmed = True
        self.make_root('largeDestination', self.image_mount, info['VolumeUUID'])

    def write_config(self):
        path = self.workspace / 'config.json'
        path.write_text(json.dumps(self.config, indent=2) + '\n')
        path.chmod(0o600)
        return path

    def execute(self):
        test = self.project / 'Packages/BitMatchEngine/Tests/BitMatchEngineTests/PhysicalDriveTransferTests.swift'
        if not test.is_file():
            raise UnsafeFixture('This checkout does not contain PhysicalDriveTransferTests.swift.')
        self.command(self.swift + ['build', '--build-tests', '--jobs', '4', '--package-path',
                     str(self.project / 'Packages/BitMatchEngine'), '--scratch-path', str(self.build)], self.workspace / 'build.log')
        for key, volume in self.volumes.items():
            refreshed = physical_volume(str(volume['path']))
            if refreshed['uuid'] != volume['uuid'] or refreshed['parent'] != volume['parent']:
                raise UnsafeFixture('A selected physical volume changed before provisioning.')
            self.make_root(key, volume['path'], volume['uuid'])
        methods = ['testCardToTwoPhysicalBackupsAcrossModesAndReuse']
        if self.large:
            methods.append('testEightLargeFilesThroughPhysicalCopyVerificationAndMHL')
        for index, method in enumerate(methods):
            if index == 1 and self.image_host:
                self.prepare_image()
            env = dict(os.environ, BITMATCH_HARDWARE_CONFIG=str(self.write_config()))
            if index == 1:
                env['BITMATCH_HARDWARE_LARGE'] = '1'
            else:
                env.pop('BITMATCH_HARDWARE_LARGE', None)
            log = self.workspace / ('large.log' if index else 'card.log')
            self.command(self.swift + ['test', '--skip-build', '--disable-swift-testing', '--no-parallel', '--jobs', '4',
                         '--package-path', str(self.project / 'Packages/BitMatchEngine'), '--scratch-path', str(self.build),
                         '--filter', 'PhysicalDriveTransferTests/' + method], log, env)
            require_execution(log, method)
            self.passed.append(method)

    def cleanup(self, *, preserve_fixtures=False):
        # An unresponsive test must never race recursive deletion of its files.
        if self.child is not None and self.child.poll() is None:
            self.warnings.append('Test process is still active; all media fixtures retained.')
            return
        image_safe = True
        if self.image is not None:
            try:
                self.validate_root(self.image_host)
                item = self.image.lstat()
                if not stat.S_ISREG(item.st_mode) or (item.st_dev, item.st_ino) != self.image_identity:
                    raise UnsafeFixture('Image backing file identity changed.')
                attachments = self.image_attachments()
                if self.attach_started and not self.attach_confirmed and not attachments:
                    raise UnsafeFixture('Image attachment did not settle; retaining backing data.')
                points = [Path(entity['mount-point']) for image in attachments
                          for entity in image.get('system-entities', []) if entity.get('mount-point')]
                if any(point != self.image_mount for point in points):
                    raise UnsafeFixture('The owned image has unexpected mountpoints.')
                if 'largeDestination' in self.roots:
                    if points != [self.image_mount]:
                        raise UnsafeFixture('Cannot revalidate the marked virtual root; retaining its image.')
                    self.validate_root('largeDestination')
                if points:
                    if self.image_mount not in mounted_paths():
                        raise UnsafeFixture('Image and mount-table evidence disagree.')
                    self.command(['/usr/bin/hdiutil', 'detach', '-quiet', str(self.image_mount)], self.workspace / 'image-detach.log', timeout=120)
                if self.image_attachments() or any(below(point, self.image_mount) for point in mounted_paths()):
                    raise UnsafeFixture('The owned image is still attached; retaining backing data.')
            except Exception as error:
                image_safe = False
                self.warnings.append(str(error))
        # A failed or interrupted run is evidence. Settle any owned image
        # attachment above, then retain its backing file and every marked root.
        # Manual reviewed cleanup still uses the default descriptor-checked path.
        if preserve_fixtures:
            return
        for key in ('sd', 'ssdA', 'ssdB'):
            if key not in self.roots or (key == self.image_host and not image_safe):
                continue
            try:
                self.validate_root(key)
                root = self.roots[key]
                if any(below(point, root) for point in mounted_paths()):
                    raise UnsafeFixture('A child mount remains inside a fixture; retaining it.')
                parent_fd = os.open(root.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    remove_tree_at(parent_fd, root.name, self.identities[key], self.identities[key][0])
                    self.removed.add(key)
                finally:
                    os.close(parent_fd)
            except Exception as error:
                self.warnings.append(str(error))
        if image_safe and not any(below(point, self.build) for point in mounted_paths()):
            shutil.rmtree(self.build, ignore_errors=False) if self.build.exists() else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--source-volume', required=True, metavar='/Volumes/CARD')
    parser.add_argument('--backup-volume', required=True, action='append', metavar='/Volumes/SSD',
                        help='Repeat twice. First seeds the large source; second is the default large destination. Three distinct physical disks are required; an internal removable SD reader is allowed.')
    parser.add_argument('--large', action='store_true', help='Also run the 119.6 GB / eight-file case.')
    parser.add_argument('--fast-large-image-on', metavar='/Volumes/SSD',
                        help='With --large, put a 160 GiB sparse exFAT image on one authorized backup.')
    args = parser.parse_args()
    if len(args.backup_volume) != 2 or (args.fast_large_image_on and not args.large):
        parser.error('Provide exactly two --backup-volume arguments; the image option also requires --large.')
    if platform.system() != 'Darwin':
        parser.error('Physical validation requires macOS.')
    if (not all(function in os.supports_dir_fd for function in (os.open, os.stat, os.unlink, os.rmdir))
            or os.scandir not in os.supports_fd or not shutil.rmtree.avoids_symlink_attacks):
        parser.error('Use a Python build with descriptor-relative filesystem APIs, such as Homebrew python3.')
    run = None
    status = 1
    try:
        volumes = dict(zip(('sd', 'ssdA', 'ssdB'), map(physical_volume, [args.source_volume] + args.backup_volume)))
        if len({entry['parent'].casefold() for entry in volumes.values()}) != 3:
            raise UnsafeFixture('Source and backups must be on three distinct physical ParentWholeDisks.')
        image_host = None
        if args.fast_large_image_on:
            chosen = direct_mount(args.fast_large_image_on)
            image_host = next((key for key in ('ssdA', 'ssdB') if volumes[key]['path'] == chosen), None)
            if image_host is None:
                raise UnsafeFixture('The image host must be one of the two explicitly authorized backups.')
        required = {'sd': 4 * 1024**3, 'ssdA': 6 * 1024**3, 'ssdB': 6 * 1024**3}
        if args.large:
            required['ssdA'] = 119_600_000_000 + 8 * 1024**3
            required[image_host or 'ssdB'] += (160 * 1024**3 if image_host else 119_600_000_000)
            for key in {'ssdA', image_host or 'ssdB'}:
                if 'fat32' in str(volumes[key]['filesystem']).lower() or str(volumes[key]['filesystem']).lower() == 'msdos':
                    raise UnsafeFixture('The large case requires support for individual 45 GB files.')
        for key, volume in volumes.items():
            if shutil.disk_usage(volume['path']).free < required[key]:
                raise UnsafeFixture('Insufficient free space for ' + key + '; no fixture folders created.')
        run = Run(volumes, args.large, image_host)
        def interrupt(signum, frame):
            raise KeyboardInterrupt('Interrupted by signal ' + str(signum))
        signal.signal(signal.SIGINT, interrupt)
        signal.signal(signal.SIGTERM, interrupt)
        print('Fixtures are generated test data only. Existing footage is never selected or modified.', flush=True)
        if args.large:
            print('Large case: 119.6 GB; up to 478.4 GB destination I/O. Illustrative 40 MB/s: 3.3 hours; throughput is not measured yet.', flush=True)
        if image_host:
            print('Large exFAT image shares its selected SSD hardware; '
                  + ('also the large source SSD, so this is not an independent backup.' if image_host == 'ssdA'
                     else 'this adds filesystem coverage, not another physical drive.'), flush=True)
        run.execute()
        status = 0
    except (Exception, KeyboardInterrupt) as error:
        print('Physical validation stopped: ' + str(error), file=sys.stderr)
    finally:
        if run:
            # A second interrupt must not abandon a normal detach attempt.
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            preserve_fixtures = status != 0
            try:
                run.cleanup(preserve_fixtures=preserve_fixtures)
            except Exception as error:
                run.warnings.append(str(error))
            if run.warnings:
                status = 1
            summary = {'exitStatus': status, 'largeRequested': args.large, 'imageSharesHostSSD': bool(image_host),
                       'fixturePolicy': 'retainFailedValidation' if preserve_fixtures else 'cleanupAfterPassingValidation',
                       'imageSharesLargeSourceSSD': image_host == 'ssdA',
                       'passedXCTests': run.passed, 'cleanupWarnings': run.warnings,
                       'retainedFixtureRoles': sorted(set(run.roots) - run.removed
                           - ({'largeDestination'} if run.image_host in run.removed else set())),
                       'logsRetained': str(run.workspace)}
            (run.workspace / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(json.dumps(summary, indent=2))
    return status


if __name__ == '__main__':
    sys.exit(main())
