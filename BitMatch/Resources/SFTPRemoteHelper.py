"""One-shot SSH helper for BitMatch's opt-in remote backup.

All names are relative to the authenticated account's working directory.
Directory descriptors pin each ancestor; leaf opens refuse symlinks, and
promotion uses linkat without replacing an existing final name. No pathname
is removed here. The app sends this bundled source to Python 3 over SSH.
This does not defend against another process with the same account privileges
mutating an already-open inode or moving a pinned directory itself.
"""

import ctypes
import errno
import json
import os
import shutil
import stat
import sys

# The SSH account can inherit a restrictive or permissive umask. Keep newly
# created directories accessible only to this account and leaf files private.
os.umask(0o077)
libc = ctypes.CDLL(None, use_errno=True)
for symbol in ("openat", "mkdirat", "linkat"):
    if not hasattr(libc, symbol):
        sys.exit(44)
libc.openat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_int)
libc.openat.restype = ctypes.c_int
libc.mkdirat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
libc.mkdirat.restype = ctypes.c_int
libc.linkat.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int)
libc.linkat.restype = ctypes.c_int
for name in ("O_NOFOLLOW", "O_DIRECTORY", "O_EXCL", "O_CLOEXEC"):
    if not hasattr(os, name):
        sys.exit(44)
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC


def check(result):
    if result < 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))
    return result


def openat(parent, name, flags, mode=0):
    return check(libc.openat(parent, os.fsencode(name), flags, mode))


def mkdirat(parent, name):
    check(libc.mkdirat(parent, os.fsencode(name), 0o700))


def linkat(src_parent, src_name, dst_parent, dst_name):
    check(libc.linkat(src_parent, os.fsencode(src_name), dst_parent, os.fsencode(dst_name), 0))


def parts(index):
    value = json.loads(sys.argv[index])
    if not isinstance(value, list) or not value:
        raise ValueError("bad path")
    if any(not isinstance(p, str) or not p or p in (".", "..") or "/" in p or "\\" in p or "\x00" in p for p in value):
        raise ValueError("bad path")
    return value


def walk(parts, create=False):
    current = os.open(".", DIR_FLAGS)
    try:
        for name in parts:
            try:
                next_fd = openat(current, name, DIR_FLAGS)
            except OSError as exc:
                if not create or exc.errno != errno.ENOENT:
                    raise
                try:
                    mkdirat(current, name)
                except OSError as mkdir_error:
                    if mkdir_error.errno != errno.EEXIST:
                        raise
                next_fd = openat(current, name, DIR_FLAGS)
            os.close(current)
            current = next_fd
        return current
    except BaseException:
        os.close(current)
        raise


def regular(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise ValueError("not regular")
    return info


def main():
    action = sys.argv[1]
    if action == "check":
        fd = walk([])
        os.close(fd)
        print("__BITMATCH_HELPER_READY__")
    elif action == "mkdir":
        fd = walk(parts(2), create=True)
        os.close(fd)
    elif action == "inspect":
        path = parts(2)
        try:
            parent = walk(path[:-1])
        except OSError as exc:
            if exc.errno == errno.ENOENT:
                return
            raise
        try:
            try:
                fd = openat(parent, path[-1], FILE_FLAGS)
            except OSError as exc:
                if exc.errno == errno.ENOENT:
                    return
                raise
            try:
                print(regular(fd).st_size)
            finally:
                os.close(fd)
        finally:
            os.close(parent)
    elif action == "upload":
        path = parts(2)
        parent = walk(path[:-1])
        try:
            fd = openat(parent, path[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb", buffering=1024 * 1024) as output:
                shutil.copyfileobj(sys.stdin.buffer, output, 1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
        finally:
            os.close(parent)
    elif action == "download":
        path = parts(2)
        parent = walk(path[:-1])
        try:
            fd = openat(parent, path[-1], FILE_FLAGS)
            regular(fd)
            with os.fdopen(fd, "rb", buffering=1024 * 1024) as source:
                shutil.copyfileobj(source, sys.stdout.buffer, 1024 * 1024)
                sys.stdout.buffer.flush()
        finally:
            os.close(parent)
    elif action == "promote":
        source = parts(2)
        final = parts(3)
        src_parent = walk(source[:-1])
        dst_parent = walk(final[:-1])
        try:
            src_fd = openat(src_parent, source[-1], FILE_FLAGS)
            try:
                original = regular(src_fd)
                linkat(src_parent, source[-1], dst_parent, final[-1])
                final_fd = openat(dst_parent, final[-1], FILE_FLAGS)
                try:
                    linked = regular(final_fd)
                    if (original.st_dev, original.st_ino) != (linked.st_dev, linked.st_ino):
                        raise ValueError("source changed")
                finally:
                    os.close(final_fd)
            finally:
                os.close(src_fd)
        finally:
            os.close(src_parent)
            os.close(dst_parent)
    elif action == "same":
        source = parts(2)
        final = parts(3)
        try:
            src_parent = walk(source[:-1])
        except OSError as exc:
            if exc.errno == errno.ENOENT:
                print("__BITMATCH_DIFFERENT__")
                return
            raise
        try:
            try:
                dst_parent = walk(final[:-1])
            except OSError as exc:
                if exc.errno == errno.ENOENT:
                    print("__BITMATCH_DIFFERENT__")
                    return
                raise
            try:
                src_fd = dst_fd = None
                try:
                    src_fd = openat(src_parent, source[-1], FILE_FLAGS)
                    dst_fd = openat(dst_parent, final[-1], FILE_FLAGS)
                    original = regular(src_fd)
                    linked = regular(dst_fd)
                    same = (original.st_dev, original.st_ino) == (linked.st_dev, linked.st_ino)
                    print("__BITMATCH_SAME__" if same else "__BITMATCH_DIFFERENT__")
                except OSError as exc:
                    if exc.errno == errno.ENOENT:
                        print("__BITMATCH_DIFFERENT__")
                        return
                    raise
                finally:
                    if src_fd is not None:
                        os.close(src_fd)
                    if dst_fd is not None:
                        os.close(dst_fd)
            finally:
                os.close(dst_parent)
        finally:
            os.close(src_parent)
    else:
        raise ValueError("bad action")


try:
    main()
except OSError as exc:
    print("__BITMATCH_ERRNO__" + str(exc.errno), file=sys.stderr)
    if exc.errno == errno.EEXIST and sys.argv[1] in ("upload", "promote"):
        sys.exit(42)
    if exc.errno in (errno.ELOOP, errno.ENOTDIR):
        sys.exit(43)
    if exc.errno in (errno.ENOSPC, getattr(errno, "EDQUOT", -1)):
        print("__BITMATCH_STORAGE_FULL__", file=sys.stderr)
        sys.exit(46)
    if exc.errno in (errno.EACCES, errno.EPERM):
        print("__BITMATCH_PERMISSION__", file=sys.stderr)
        sys.exit(47)
    if sys.argv[1] == "promote" and exc.errno in (errno.ENOSYS, errno.ENOTSUP, errno.EXDEV, getattr(errno, "EOPNOTSUPP", -1)):
        print("__BITMATCH_NO_HARDLINK__", file=sys.stderr)
        sys.exit(48)
    sys.exit(45)
except (ValueError, json.JSONDecodeError):
    print("__BITMATCH_UNSAFE_PATH__", file=sys.stderr)
    sys.exit(43)
