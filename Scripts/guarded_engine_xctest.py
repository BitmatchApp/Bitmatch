#!/usr/bin/env python3
"""Run one exact XCTest in an owned engine bundle; sample its physical footprint.
Only SIGINT is sent to the validated direct worker. Native calls may still wait.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


class Usage(ctypes.Structure):
    # Public Darwin rusage_info_v0 layout (sys/resource.h).
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in
        ['user', 'system', 'pkg', 'interrupt', 'pageins', 'wired', 'resident', 'footprint', 'start', 'exit']]


class WorkerExited(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_xctest(text, selected):
    require(re.fullmatch(r'BitMatchEngineTests\.[A-Za-z0-9_]+/[A-Za-z0-9_]+', selected), 'Invalid explicit XCTest selection')
    class_name, method = selected.rsplit('/', 1)
    rows = re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures', text)
    require(rows and tuple(int(x or 0) for x in rows[-1]) == (1, 0, 0), 'Expected one actual passing XCTest')
    require(len(re.findall(r"Test Case '-\[" + re.escape(class_name) + " " + re.escape(method) + r"\]' passed", text)) == 1,
            'Selected XCTest did not pass exactly once')


def validate_soak(value, seed, iterations):
    require(all(type(value.get(key)) is int for key in ['formatVersion', 'baseSeed', 'requestedIterations', 'completedIterations', 'destinationsPerIteration']), 'Invalid receipt numeric fields')
    require(value.get('formatVersion') == 2 and value.get('outcome') == 'passed', 'Missing successful format-2 receipt')
    require(value.get('baseSeed') == seed and value.get('requestedIterations') == iterations
            and value.get('completedIterations') == iterations, 'Incomplete iteration coverage')
    require(value.get('verificationMode') == 'standard' and value.get('destinationsPerIteration') == 2,
            'Unexpected transfer policy')
    rows = value.get('iterations', [])
    require(len(rows) == iterations, 'Wrong iteration receipt count')
    for index, row in enumerate(rows):
        require(all(type(number) is int for number in row.values()), 'Invalid iteration numeric fields')
        expected_seed = (seed + index) & ((1 << 64) - 1)
        require(row == {'iteration': index, 'seed': expected_seed, 'manifestFiles': 9, 'verifiedOutputs': 18,
                        'sourceHashesBefore': 9, 'sourceHashesAfter': 9, 'sourceDirectoriesBeforeAfter': 3,
                        'payloadPattern': expected_seed & 255}, 'Iteration inventory/hash coverage mismatch')


def run(args):
    work = Path(args.work).resolve()
    require(work.is_dir() and (work / '.bitmatch-disposable-fixture').is_file(), 'Unowned worker directory')
    bundle = Path(args.bundle).resolve()
    require(bundle.suffix == '.xctest' and bundle.is_dir(), 'Missing explicit engine test bundle')
    host = subprocess.check_output(['/usr/bin/xcrun', '--find', 'xctest'], text=True, timeout=15).strip()
    require(host.startswith('/Applications/') and host.endswith('/usr/bin/xctest'), 'Unexpected XCTest host')
    architecture = subprocess.check_output(['/usr/bin/uname', '-m'], text=True, timeout=15).strip()
    require(architecture in ('arm64', 'x86_64'), 'Unsupported host architecture')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('BITMATCH_', 'TEST_RUNNER_BITMATCH_'))}
    explicit_environment = json.loads(args.environment)
    require(isinstance(explicit_environment, dict) and all(isinstance(key, str) and isinstance(value, str)
            for key, value in explicit_environment.items()), 'Worker environment must contain string fields')
    require(re.fullmatch(r'BitMatchEngineTests\.[A-Za-z0-9_]+/[A-Za-z0-9_]+', args.selected), 'Invalid explicit XCTest selection')
    environment.update(explicit_environment)
    log = work / (args.label + '.log')
    receipt = {'scope': 'Host-only selected XCTest; public proc_pid_rusage physical footprint, sampled not a leak proof',
               'limitBytes': 1024 ** 3, 'sampleIntervalSeconds': 0.01, 'samples': 0, 'peakBytes': 0,
               'guard': False, 'missingSamples': 0, 'outcome': 'failed', 'stillActive': False}
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    lib.proc_pidpath.restype = ctypes.c_int
    child = None
    interrupted = None
    start_identity = None
    worker_seen = False

    def usage():
        item = Usage()
        if lib.proc_pid_rusage(child.pid, 0, ctypes.byref(item)) != 0:
            return None
        return item

    def validate_worker():
        item = usage()
        buffer = ctypes.create_string_buffer(4096)
        path_size = lib.proc_pidpath(child.pid, buffer, len(buffer))
        if item is None or path_size <= 0:
            # A successful worker may exit between poll and the read-only query.
            # Join that exit before calling a vanished sample unavailable.
            try:
                child.wait(timeout=0.2)
                raise WorkerExited()
            except subprocess.TimeoutExpired:
                receipt['missingSamples'] += 1
                receipt['guard'] = True
                raise ValueError('Worker physical footprint or identity unavailable')
        require(Path(os.fsdecode(buffer.value)).resolve() == Path(host).resolve(), 'Worker executable changed')
        require(start_identity is None or item.start == start_identity, 'Worker process identity changed')
        return item

    def request_interrupt():
        if child is not None and child.poll() is None:
            buffer = ctypes.create_string_buffer(4096)
            if lib.proc_pidpath(child.pid, buffer, len(buffer)) <= 0:
                try:
                    child.wait(timeout=0.2)
                    return
                except subprocess.TimeoutExpired:
                    raise ValueError('Cannot validate worker before interrupt')
            require(Path(os.fsdecode(buffer.value)).resolve() == Path(host).resolve(), 'Interrupt target executable changed')
            item = usage()
            # Popen owns this direct, unreaped child; absence of a memory
            # sample must not prevent interrupting that exact validated host.
            require(item is None or start_identity is None or item.start == start_identity,
                    'Interrupt target process identity changed')
            child.send_signal(signal.SIGINT)

    def receive(signum, frame):
        nonlocal interrupted
        interrupted = signum

    handlers = {sig: signal.signal(sig, receive) for sig in (signal.SIGINT, signal.SIGTERM)}
    started = time.monotonic()
    try:
        with log.open('x') as output:
            child = subprocess.Popen(['/usr/bin/arch', '-' + architecture, host, '-XCTest', args.selected, str(bundle)],
                                     env=environment, stdout=output, stderr=subprocess.STDOUT)
            receipt['childPID'] = child.pid
            while child.poll() is None:
                text = log.read_text(errors='replace')
                match = re.search(r'^(?:SOAK|STRESS) workerPID=(\d+)$', text, re.M)
                if match:
                    require(int(match.group(1)) == child.pid, 'Breadcrumb does not identify direct worker')
                    try:
                        item = validate_worker()
                    except WorkerExited:
                        break
                    if start_identity is None:
                        start_identity = item.start
                    worker_seen = True
                    receipt['samples'] += 1
                    receipt['peakBytes'] = max(receipt['peakBytes'], item.footprint)
                    if item.footprint >= receipt['limitBytes']:
                        receipt['guard'] = True
                if time.monotonic() - started >= args.max_seconds or interrupted or receipt['guard']:
                    receipt['interruptRequested'] = True
                    request_interrupt()
                    try:
                        child.wait(timeout=60)
                    except subprocess.TimeoutExpired:
                        receipt['stillActive'] = True
                    break
                time.sleep(0.01)
        require(child.poll() == 0 and worker_seen and interrupted is None and not receipt.get('interruptRequested'), 'Worker failed or was interrupted')
        validate_xctest(log.read_text(errors='replace'), args.selected)
        receipt['outcome'] = 'passed'
    finally:
        if child is not None and child.poll() is None:
            try:
                request_interrupt()
                child.wait(timeout=60)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                receipt['stillActive'] = child.poll() is None
        receipt['stillActive'] = child is not None and child.poll() is None
        receipt.update(exitStatus=child.poll() if child else None, elapsedSeconds=time.monotonic() - started,
                       actualWorkerObserved=worker_seen, interruptedSignal=interrupted)
        if interrupted is not None:
            receipt['outcome'] = 'failed'
        (work / (args.label + '-memory.json')).write_text(json.dumps(receipt, indent=2) + '\n')
        for sig, handler in handlers.items():
            signal.signal(sig, handler)
    print(json.dumps(receipt), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', required=True)
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--selected', required=True)
    parser.add_argument('--environment', required=True)
    parser.add_argument('--label', default='worker')
    parser.add_argument('--max-seconds', type=float, default=900)
    arguments = parser.parse_args()
    require(0 < arguments.max_seconds <= 3600, 'Runtime limit must be 1–3600 seconds')
    require(re.fullmatch('[A-Za-z0-9_-]+', arguments.label), 'Invalid log label')
    run(arguments)
