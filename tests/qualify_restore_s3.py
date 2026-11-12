#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Start a private real MinIO server and run the actual Zig S3 restore test."""

import argparse
import datetime
import hashlib
import hmac
import http.client
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

VERSION = "RELEASE.2025-09-07T16-13-09Z"
SHA256 = "7c5bd8512c6e966455b1d198209358b2d191c77a83ab377c4073281065fb855f"
URL = "https://github.com/minio/minio/releases/download/" + VERSION + "/minio.linux-amd64." + VERSION


def binary(path, root):
    if path:
        result = path.resolve(strict=True)
    else:
        result = root / "minio"
        with urllib.request.urlopen(URL, timeout=60) as source, result.open("wb") as destination:
            shutil.copyfileobj(source, destination)
        result.chmod(0o700)
    with result.open("rb") as source:
        assert hashlib.file_digest(source, "sha256").hexdigest() == SHA256, "MinIO release digest mismatch"
    return result


def create_bucket(endpoint, bucket, access, secret):
    now = datetime.datetime.now(datetime.timezone.utc)
    date, timestamp = now.strftime("%Y%m%d"), now.strftime("%Y%m%dT%H%M%SZ")
    payload_hash = hashlib.sha256(b"").hexdigest()
    signed = "host;x-amz-content-sha256;x-amz-date"
    canonical = "\n".join(
        [
            "PUT",
            "/" + bucket,
            "",
            "host:" + endpoint + "\nx-amz-content-sha256:" + payload_hash + "\nx-amz-date:" + timestamp + "\n",
            signed,
            payload_hash,
        ]
    )
    scope = date + "/us-east-1/s3/aws4_request"
    to_sign = "AWS4-HMAC-SHA256\n" + timestamp + "\n" + scope + "\n" + hashlib.sha256(canonical.encode()).hexdigest()
    key = ("AWS4" + secret).encode()
    for value in [date, "us-east-1", "s3", "aws4_request"]:
        key = hmac.digest(key, value.encode(), "sha256")
    signature = hmac.new(key, to_sign.encode(), "sha256").hexdigest()
    connection = http.client.HTTPConnection(endpoint, timeout=5)
    try:
        connection.request(
            "PUT",
            "/" + bucket,
            body=b"",
            headers={
                "Authorization": "AWS4-HMAC-SHA256 Credential="
                + access
                + "/"
                + scope
                + ", SignedHeaders="
                + signed
                + ", Signature="
                + signature,
                "x-amz-content-sha256": payload_hash,
                "x-amz-date": timestamp,
            },
        )
        response = connection.getresponse()
        response.read()
        assert response.status == 200, "real object store refused bucket creation: " + str(response.status)
    finally:
        connection.close()


def qualify(args):
    with tempfile.TemporaryDirectory(prefix="geode-restore-s3-") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        executable = binary(args.minio, root)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            endpoint = "127.0.0.1:" + str(sock.getsockname()[1])
        access, secret = secrets.token_hex(10), secrets.token_hex(24)
        bucket = "geode-restore-" + secrets.token_hex(6)
        data = root / "objects"
        data.mkdir(mode=0o700)
        log = root / "minio.log"
        with log.open("wb") as stream:
            server = subprocess.Popen(
                [str(executable), "server", "--address", endpoint, str(data)],
                env={
                    "PATH": os.environ.get("PATH", ""),
                    "MINIO_ROOT_USER": access,
                    "MINIO_ROOT_PASSWORD": secret,
                    "MINIO_BROWSER": "off",
                    "MINIO_UPDATE": "off",
                },
                stdout=stream,
                stderr=stream,
                start_new_session=True,
            )
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                assert server.poll() is None, "owned MinIO exited during startup"
                try:
                    with urllib.request.urlopen("http://" + endpoint + "/minio/health/ready", timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError("owned MinIO startup deadline expired")
            create_bucket(endpoint, bucket, access, secret)
            environment = {
                **os.environ,
                "GEODE_TEST_S3_ENDPOINT": endpoint,
                "GEODE_TEST_S3_ACCESS_KEY": access,
                "GEODE_TEST_S3_SECRET_KEY": secret,
                "GEODE_TEST_S3_BUCKET": bucket,
            }
            command = args.command or ["zig", "build", "-j1", "test-sonny6300-restore-s3", "--summary", "all"]
            if command[0] == "--":
                command = command[1:]
            result = subprocess.run(command, env=environment, timeout=1800)
            assert result.returncode == 0, "actual Geode S3 round-trip regression failed"
            print(
                json.dumps(
                    {
                        "schema": "geode.restore-s3-qualification/v1",
                        "minio_release": VERSION,
                        "minio_sha256": SHA256,
                        "actual_round_trip": True,
                    }
                ),
                flush=True,
            )
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid, signal.SIGKILL)
                    server.wait()
            if args.private_logs:
                args.private_logs.mkdir(mode=0o700, parents=True, exist_ok=True)
                destination = args.private_logs / "minio.log"
                shutil.copyfile(log, destination)
                destination.chmod(0o600)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minio", type=Path, help="reuse the pinned, digest-verified release executable")
    parser.add_argument("--private-logs", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    qualify(parser.parse_args())
