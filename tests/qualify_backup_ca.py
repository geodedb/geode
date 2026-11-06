#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Actual CLI/server private-CA backup qualification; never mocks a response."""

import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def start(binary, root, name, password):
    data = root / name
    data.mkdir(mode=0o700)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(('127.0.0.1', 0))
        address = '127.0.0.1:' + str(sock.getsockname()[1])
    log = root / (name + '.log')
    with log.open('wb') as stream:
        process = subprocess.Popen(
            [str(binary), 'serve', '--listen', address, '--data-dir', str(data)],
            env={'PATH': os.environ.get('PATH', ''), 'HOME': str(root),
                 'GEODE_ADMIN_PASSWORD': password, 'GEODE_ALLOW_INSECURE_TLS': '1'},
            stdout=stream, stderr=stream, start_new_session=True)
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('owned real server exited during startup (exit ' + str(process.returncode) + ')')
            if b'[startup] server ready' in log.read_bytes() and (data / 'server.crt').is_file():
                return process, address, data / 'server.crt'
            time.sleep(0.1)
        raise RuntimeError('owned real server startup deadline expired')
    except BaseException:
        stop(process)
        raise


def qualify(binary, evidence, private_logs=None):
    processes = []
    results = []
    with tempfile.TemporaryDirectory(prefix='geode-private-ca-backup-') as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        password = 'Aa1!' + secrets.token_urlsafe(32)
        # The real server generates both independent certificates. No external
        # signer, embedded private key, fixture response or TLS bypass is used.
        try:
            server, address, ca = start(binary, root, 'primary', password)
            processes.append(server)
            other, _, wrong_ca = start(binary, root, 'untrusted', 'Aa1!' + secrets.token_urlsafe(32))
            processes.append(other)
            stop(other)
            env = {'PATH': os.environ.get('PATH', ''), 'HOME': str(root),
                   'GEODE_BACKUP_PASSWORD': password}
            for name, certificate in [('correct-ca', ca), ('wrong-ca', wrong_ca),
                                      ('missing-ca', root / 'absent.crt')]:
                output = root / (name + '.backup.gz')
                run = subprocess.run(
                    [str(binary), 'backup', 'create', '--output', str(output),
                     '--server', address, '--user', 'geode', '--ca-cert', str(certificate), '--compress'],
                    env=env, capture_output=True, timeout=65)
                text = run.stdout + run.stderr
                fallback = any(marker in text for marker in
                               [b'Attempting local data directory backup', b'Local backup completed'])
                bypass = b'verification disabled' in text.lower()
                result = {'case': name, 'exit': run.returncode,
                          'fallback_observed': fallback, 'verification_disabled': bypass}
                if name == 'correct-ca':
                    assert run.returncode == 0 and not fallback and not bypass, 'verified remote backup refused'
                    assert b'Receiving backup' in text and output.is_file() and output.stat().st_size > 0, 'no actual remote backup received'
                    info = subprocess.run([str(binary), 'backup', 'info', str(output)],
                                          env=env, capture_output=True, timeout=15)
                    assert info.returncode == 0, 'actual backup parser refused captured bytes'
                    result['received_bytes'] = output.stat().st_size
                    result['parser_exit'] = info.returncode
                else:
                    assert run.returncode != 0 and not fallback and not bypass and not output.exists(), 'untrusted CA produced a backup or fallback'
                results.append(result)
                print(json.dumps(result), flush=True)
        finally:
            for process in reversed(processes):
                stop(process)
            if private_logs:
                private_logs.mkdir(mode=0o700, parents=True, exist_ok=True)
                private_logs.chmod(0o700)
                for log in root.glob('*.log'):
                    destination = private_logs / log.name
                    shutil.copyfile(log, destination)
                    destination.chmod(0o600)
    if evidence:
        evidence.write_text(json.dumps({'schema': 'geode.private-ca-backup-qualification/v1',
                                       'results': results, 'owned_servers_stopped': True}, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('zig-out/bin/geode'))
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--private-logs', type=Path, help='retain private server diagnostics for local debugging')
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    qualify(binary, args.evidence, args.private_logs)
