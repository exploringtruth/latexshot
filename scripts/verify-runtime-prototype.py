#!/usr/bin/env python3
"""Audit and exercise a relocated prototype; keeps production gates unchanged."""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
MAGIC = {bytes.fromhex(value) for value in
         ('feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}


def audit(runtime):
    summary = {'files': 0, 'bytes': 0, 'mach_o_files': 0,
               'absolute_non_system_loads': [], 'absolute_non_system_rpaths': []}
    for path in runtime.rglob('*'):
        if path.is_symlink():
            if not path.resolve().is_relative_to(runtime):
                raise ValueError('Runtime symlink escapes its directory: ' + str(path.relative_to(runtime)))
            continue
        if not path.is_file():
            continue
        summary['files'] += 1
        summary['bytes'] += path.stat().st_size
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in MAGIC:
            continue
        summary['mach_o_files'] += 1
        output = subprocess.check_output(['otool', '-arch', 'arm64', '-l', str(path)], text=True)
        for block in output.split('Load command '):
            kind = None
            if re.search(r'cmd LC_(?:LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LOAD_UPWARD_DYLIB)\n', block):
                kind, field = 'absolute_non_system_loads', 'name'
            elif 'cmd LC_RPATH\n' in block:
                kind, field = 'absolute_non_system_rpaths', 'path'
            if kind:
                match = re.search(r'\n\s+' + field + r' (.+?) \(offset', block)
                if match and match[1].startswith('/') and not match[1].startswith(('/System/Library/', '/usr/lib/')):
                    summary[kind].append({'file': str(path.relative_to(runtime)), 'path': match[1]})
    return summary


def probe(root, runtime, model, worker):
    # Runs under sandbox-exec in isolated, relocated Python with an empty HOME.
    result = {'python': sys.version, 'platform': platform.platform(), 'executable': sys.executable,
              'prefix': sys.prefix, 'isolated': sys.flags.isolated, 'predictions': []}
    connection = socket.socket()
    connection.settimeout(2)
    try:
        connection.connect(('1.1.1.1', 443))
    except OSError as error:
        result['network_canary_errno'] = error.errno
        assert error.errno in (errno.EPERM, errno.EACCES), 'Network policy did not deny the canary'
    else:
        raise RuntimeError('Network canary unexpectedly connected')
    finally:
        connection.close()
    result['network_denied'] = True
    assert Path(sys.prefix).resolve() == runtime.resolve(), 'Python prefix is outside the relocated runtime'
    fixtures = json.loads((root / 'manifest.json').read_text())
    with (root / 'worker.log').open('wb') as logs:
        process = subprocess.Popen([sys.executable, '-I', '-B', str(worker), str(model)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=logs)
        def read(count):
            value = bytearray()
            while len(value) < count:
                chunk = process.stdout.read(count - len(value))
                if not chunk:
                    raise RuntimeError('Worker exited before its response')
                value.extend(chunk)
            return value
        def predict(payload):
            process.stdin.write(struct.pack('>I', len(payload)) + payload)
            process.stdin.flush()
            count = struct.unpack('>I', read(4))[0]
            if not 0 < count <= 1_048_576:
                raise ValueError('Invalid worker response size')
            return json.loads(read(count))
        try:
            for fixture in fixtures:
                started = time.perf_counter()
                response = predict((root / 'fixtures' / fixture['image']).read_bytes())
                if not response.get('latex') or response.get('error'):
                    raise RuntimeError('Inference failed for ' + fixture['id'])
                result['predictions'].append({'id': fixture['id'], 'latex': response['latex'],
                                               'seconds': time.perf_counter() - started})
            failure = predict(b'not a valid png')
            assert failure.get('error') and not failure.get('latex')
            recovery = predict((root / 'fixtures' / fixtures[0]['image']).read_bytes())
            assert recovery == {'latex': result['predictions'][0]['latex']}
            result['invalid_image_rejected'] = result['same_worker_recovered'] = True
        finally:
            process.stdin.close()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    result['worker_returncode'] = process.returncode
    assert process.returncode == 0
    print(json.dumps(result))


def verify(args):
    if args.app:
        resources = args.app.resolve() / 'Contents/Resources'
        runtime, model = resources / 'RecognitionRuntime', resources / 'RecognitionModel'
        workers = list(resources.glob('*.bundle/**/recognize.py'))
        if len(workers) != 1:
            raise ValueError('Expected one packaged recognition worker')
        worker = workers[0]
    else:
        runtime, model, worker = args.runtime.resolve(), args.model.resolve(), args.worker.resolve()
    if not (runtime / 'bin/python3').is_file():
        raise ValueError('Missing staged RecognitionRuntime/bin/python3')
    assembly = json.loads((runtime / 'assembly.json').read_text())
    original = Path(assembly['build_prefix']).resolve()
    if runtime == original or runtime.is_relative_to(original.parent):
        raise ValueError('Move the runtime outside its original assembly directory before verification')
    model_lock = json.loads((ROOT / 'benchmarks/model-lock.json').read_text())
    for entry in model_lock['files']:
        path = model / entry['name']
        if path.stat().st_size != entry['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError('Prototype model artifact mismatch: ' + entry['name'])
    result = {'status': 'PROTOTYPE_ONLY', 'release_qualified': False,
              'runtime': str(runtime), 'assembly': assembly,
              'worker_sha256': hashlib.sha256(worker.read_bytes()).hexdigest(),
              'model_revision': model_lock['revision'], 'native_audit': audit(runtime)}
    work = Path(tempfile.mkdtemp(prefix='latexshot-runtime-verification.', dir='/private/tmp'))
    (work / 'fixtures').mkdir()
    (work / 'home').mkdir()
    fixtures = [row for row in json.loads((ROOT / 'benchmarks/fixtures/manifest.json').read_text())
                if row['id'].endswith('-01')]
    (work / 'manifest.json').write_text(json.dumps(fixtures))
    for fixture in fixtures:
        shutil.copy(ROOT / 'benchmarks/fixtures' / fixture['image'], work / 'fixtures' / fixture['image'])
    shutil.copy(worker, work / 'recognize.py')
    denied = ['/opt/homebrew', '/usr/local', '/private/tmp/latexshot-recognition-venv', str(original.parent)]
    policy = '(version 1)(allow default)(deny network*)(deny file-read* ' + ''.join(
        '(subpath ' + json.dumps(path) + ')' for path in denied) + ')'
    result['sandbox_policy'] = policy
    result['probe_directory'] = str(work)
    command = ['sandbox-exec', '-p', policy, str(runtime / 'bin/python3'), '-I', '-B',
               str(Path(__file__).resolve()), '--probe', str(work), str(runtime), str(model), str(work / 'recognize.py')]
    environment = {'PATH': '/usr/bin:/bin', 'HOME': str(work / 'home'), 'TMPDIR': '/private/tmp',
                   'HF_HUB_OFFLINE': '1', 'PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK': 'True',
                   'DISABLE_MODEL_SOURCE_CHECK': 'True'}
    process = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=180)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise RuntimeError('Relocation probe exceeded 180 seconds; its process group was stopped')
    if process.returncode:
        (work / 'probe-stderr.log').write_text(stderr)
        raise RuntimeError('Relocation probe failed; diagnostics: ' + str(work))
    result['verification'] = json.loads(stdout)
    result['strict_native_audit_passed'] = not (result['native_audit']['absolute_non_system_loads'] or
                                              result['native_audit']['absolute_non_system_rpaths'])
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print('Relocated inference, network denial, invalid input, and recovery passed.')
    print('Native references still requiring review:', len(result['native_audit']['absolute_non_system_loads']),
          'load commands,', len(result['native_audit']['absolute_non_system_rpaths']), 'rpaths')
    print('Evidence:', args.output)
    if args.strict and not result['strict_native_audit_passed']:
        raise ValueError('Strict native dependency audit failed; prototype is not distribution-qualified')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--probe':
        probe(*(Path(value) for value in sys.argv[2:]))
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        source = parser.add_mutually_exclusive_group(required=True)
        source.add_argument('--runtime', type=Path)
        source.add_argument('--app', type=Path)
        parser.add_argument('--model', type=Path)
        parser.add_argument('--worker', type=Path, default=ROOT / 'Sources/EquationRecognition/Resources/recognize.py')
        parser.add_argument('--output', required=True, type=Path)
        parser.add_argument('--strict', action='store_true', help='Fail on absolute non-system native load commands or rpaths')
        arguments = parser.parse_args()
        if arguments.runtime and not arguments.model:
            parser.error('--model is required with --runtime')
        try:
            verify(arguments)
        except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
            sys.exit(str(error))
