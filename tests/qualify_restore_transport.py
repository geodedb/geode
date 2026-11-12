#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exercise restore against owned TLS QUIC/gRPC servers and actual storage.

Only Python's standard library and openssl are needed. The small HTTP/2 client
speaks to the real server; it never fabricates a database response.
"""

import argparse
import json
import os
import re
import secrets
import selectors
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import time
from pathlib import Path


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def string(number, value):
    data = value.encode()
    return varint(number * 8 + 2) + varint(len(data)) + data


def integer(number, value):
    return varint(number * 8) + varint(value)


def decode(data):
    def number(offset):
        result = 0
        for shift in range(0, 70, 7):
            if offset >= len(data):
                raise ValueError("truncated protobuf varint")
            byte = data[offset]
            offset += 1
            result |= (byte & 127) << shift
            if byte < 128:
                return result, offset
        raise ValueError("oversized protobuf varint")

    result = {}
    offset = 0
    while offset < len(data):
        tag, offset = number(offset)
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            value, offset = number(offset)
        else:
            if wire == 2:
                length, offset = number(offset)
            elif wire in (1, 5):
                length = 8 if wire == 1 else 4
            else:
                raise ValueError("unexpected protobuf wire type")
            if length > len(data) - offset:
                raise ValueError("truncated protobuf field")
            value = data[offset : offset + length]
            offset += length
        result[field] = value
    return result


def frame(kind, flags, stream, payload=b""):
    return len(payload).to_bytes(3, "big") + bytes([kind, flags]) + stream.to_bytes(4, "big") + payload


def receive(sock, length):
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError("real gRPC connection closed early")
        data.extend(chunk)
    return bytes(data)


def rpc(port, ca, method, body):
    context = ssl.create_default_context(cafile=str(ca))
    context.set_alpn_protocols(["h2"])
    with (
        socket.create_connection(("127.0.0.1", port), timeout=60) as raw,
        context.wrap_socket(raw, server_hostname="localhost") as sock,
    ):
        sock.settimeout(60)
        assert sock.selected_alpn_protocol() == "h2", "server did not negotiate HTTP/2"
        headers = bytearray()
        for name, value in [
            (":method", "POST"),
            (":scheme", "https"),
            (":authority", "localhost"),
            (":path", "/geode.GeodeService/" + method),
            ("content-type", "application/grpc"),
            ("te", "trailers"),
        ]:
            # HPACK literal, no indexing and no Huffman coding. Each string
            # is shorter than the seven-bit HPACK length prefix.
            assert len(name) < 127 and len(value) < 127
            headers.extend(b"\0" + bytes([len(name)]) + name.encode() + bytes([len(value)]) + value.encode())
        packet = b"\0" + len(body).to_bytes(4, "big") + body
        sock.sendall(
            b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + frame(4, 0, 0) + frame(1, 4, 1, headers) + frame(0, 1, 1, packet)
        )
        output = bytearray()
        while True:
            header = receive(sock, 9)
            length = int.from_bytes(header[:3], "big")
            assert length <= 1 << 20, "oversized HTTP/2 frame"
            kind, flags = header[3:5]
            stream = int.from_bytes(header[5:], "big") & 0x7FFFFFFF
            payload = receive(sock, length)
            if kind == 4 and not flags & 1:
                sock.sendall(frame(4, 1, 0))
            elif kind == 6 and not flags & 1:
                sock.sendall(frame(6, 1, 0, payload))
            elif kind == 0 and stream == 1:
                if flags & 8:
                    payload = payload[1 : len(payload) - payload[0]]
                output.extend(payload)
                assert len(output) <= 1 << 20, "oversized gRPC response"
            elif kind in (3, 7):
                raise RuntimeError("server reset the actual HTTP/2 request")
            if stream == 1 and kind in (0, 1) and flags & 1:
                assert len(output) >= 5 and output[0] == 0, "missing or compressed gRPC body"
                size = int.from_bytes(output[1:5], "big")
                assert size == len(output) - 5, "invalid gRPC body length"
                return decode(output[5:])


def free_port(kind):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def stop(process):
    if process.poll() is None:
        # A timeout case can leave our daemon paused; resume before shutdown.
        os.killpg(process.pid, signal.SIGCONT)
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


class Fixture:
    def __init__(self, binary, root):
        self.binary, self.root = binary, root
        self.password = "Restore Admin Three Words " + secrets.token_hex(8)
        self.reader_password = "Restore Reader Three Words " + secrets.token_hex(8)
        self.env = {
            "PATH": os.environ.get("PATH", ""),
            "XDG_STATE_HOME": str(root / "state"),
            "GEODE_ADMIN_PASSWORD": self.password,
            "GEODE_BACKUP_PASSWORD": self.password,
            "OTEL_SDK_DISABLED": "true",
        }
        self.processes = []
        self.data = root / "live"
        self.data.mkdir(mode=0o700)
        self.certificate(self.data)

    @staticmethod
    def certificate(data):
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "ec",
                "-pkeyopt",
                "ec_paramgen_curve:prime256v1",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=localhost",
                "-addext",
                "subjectAltName=DNS:localhost,IP:127.0.0.1",
                "-keyout",
                str(data / "server.key"),
                "-out",
                str(data / "server.crt"),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        (data / "server.key").chmod(0o600)

    def start(self, data, name, cluster=False):
        self.qport, self.gport = free_port(socket.SOCK_DGRAM), free_port(socket.SOCK_STREAM)
        self.ca = data / "server.crt"
        log = self.root / (name + ".log")
        self.current_log = log
        command = [
            str(self.binary),
            "serve",
            "--listen",
            f"127.0.0.1:{self.qport}",
            "--listen-grpc",
            f"127.0.0.1:{self.gport}",
            "--data-dir",
            str(data),
        ]
        environment = dict(self.env)
        if cluster:
            command.extend(["--cluster-port", str(free_port(socket.SOCK_DGRAM))])
            environment.update({"GEODE_NODE_ID": "1", "GEODE_CLUSTER_TOKEN": secrets.token_hex(32)})
        with log.open("wb") as stream:
            process = subprocess.Popen(
                command,
                cwd=self.root,
                env=environment,
                stdout=stream,
                stderr=stream,
                start_new_session=True,
            )
        self.processes.append(process)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            assert process.poll() is None, "owned real server exited during startup"
            if b"[startup] server ready" in log.read_bytes():
                return process
            time.sleep(0.1)
        raise RuntimeError("owned real server startup deadline expired")

    def command(self, *args):
        command = [
            str(self.binary),
            *args,
            "--server",
            f"127.0.0.1:{self.qport}",
            "--user",
            "geode",
            "--ca-cert",
            str(self.ca),
        ]
        if args[0] == "query":
            command.extend(["--password", self.password])
        return command

    def cli(self, *args):
        result = subprocess.run(
            self.command(*args), cwd=self.root, env=self.env, capture_output=True, text=True, timeout=90
        )
        diagnostic = (
            (result.stdout[-1000:] + result.stderr[-1000:])
            .replace(self.password, "<redacted>")
            .replace(self.reader_password, "<redacted>")
        )
        assert result.returncode == 0, "actual CLI request failed: " + diagnostic
        return result.stdout + result.stderr

    def handshake(self, username, password):
        response = rpc(
            self.gport,
            self.ca,
            "Handshake",
            string(1, username) + string(2, password) + string(4, "restore-regression"),
        )
        assert response.get(1) == 1, "actual gRPC handshake refused"
        return response[2].decode()

    def restore(self, body):
        return rpc(self.gport, self.ca, "Restore", body)

    def completed(self, session, job):
        phases = []
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            response = self.restore(string(3, session) + string(5, job))
            phases.append(response.get(8, b"").decode())
            if response.get(7) in (b"completed", b"failed"):
                assert response.get(1) == 1 and response.get(7) == b"completed", "actual restore failed"
                assert response.get(5, 0) > 0 and response.get(9) == response.get(10) and response[10] > 0
                return response, list(dict.fromkeys(phases))
            time.sleep(0.05)
        raise RuntimeError("actual restore job deadline expired")

    def count(self, expected):
        output = self.cli("query", "MATCH (n:RestoreSample) RETURN count(n) AS total", "--format", "json")
        # CLI informational output may accompany the JSON document.
        assert re.search(r'"total"\s*:\s*' + str(expected) + r"\b", output), "restored/live node count disagrees"

    def timeout_and_resume(self, server):
        process = subprocess.Popen(
            self.command("restore", "--source", "s3://server-managed/fixture", "--yes", "--timeout-ms", "1000"),
            cwd=self.root,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.processes.append(process)
        output = bytearray()
        paused = False
        job = None
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stderr, selectors.EVENT_READ)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    for key, _ in selector.select(timeout=0.1):
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if chunk:
                            output.extend(chunk)
                    match = re.search(rb"RESTORE: Job ([0-9a-f]{32})", output)
                    if match:
                        job = match[1].decode()
                        os.killpg(server.pid, signal.SIGSTOP)
                        paused = True
                        break
                    if process.poll() is not None:
                        break
            assert job, "CLI did not report the actual accepted restore job"
            stdout, stderr = process.communicate(timeout=15)
            output.extend(stderr)
            assert process.returncode != 0, "paused server unexpectedly produced successful restore completion"
            assert b"restart with --data-dir" not in stdout + output
            assert job.encode() in output and (b"timed out" in output or b"interrupted" in output), (
                "timeout lost resumable job ID"
            )
        finally:
            if paused and server.poll() is None:
                os.killpg(server.pid, signal.SIGCONT)
            stop(process)
        resumed = self.cli("restore", "--job", job, "--timeout-ms", "30000")
        assert "restart with --data-dir" in resumed, "resumed CLI did not wait for actual completion"
        return job


def qualify(binary, evidence, private_logs):
    checks = []
    with tempfile.TemporaryDirectory(prefix="geode-restore-transport-") as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        fixture = Fixture(binary, root)
        try:
            server = fixture.start(fixture.data, "live-server")
            fixture.cli("query", "CREATE (:RestoreSample {name: 'before'})")
            fixture.cli(
                "query", "CREATE USER restore_reader SET PASSWORD '" + fixture.reader_password + "' ROLE readonly"
            )
            fixture.cli("backup", "create", "--output", str(root / "snapshot.backup"))
            fixture.cli("query", "CREATE (:RestoreSample {name: 'after'})")
            admin = fixture.handshake("geode", fixture.password)
            reader = fixture.handshake("restore_reader", fixture.reader_password)
            for name, expected, body in [
                ("confirmation-required", b"RestoreRequiresConfirmation", string(3, admin) + integer(4, 1)),
                (
                    "invalid-time-refused",
                    b"InvalidRestoreTime",
                    string(1, "invalid") + integer(2, 1) + string(3, admin) + integer(4, 1),
                ),
                ("readonly-start-refused", b"Admin role required", integer(2, 1) + string(3, reader) + integer(4, 1)),
            ]:
                response = fixture.restore(body)
                assert not response.get(1, 0) and not response.get(6), name + " unexpectedly accepted"
                assert expected in response.get(2, b""), name + " returned the wrong refusal"
                checks.append(name)
            accepted = fixture.restore(integer(2, 1) + string(3, admin) + integer(4, 1))
            assert accepted.get(1, 0) == 0 and accepted.get(7) == b"queued", "acceptance reported success"
            job = accepted[6].decode()
            checks.append("async-acceptance-is-pending")
            for name, expected, body in [
                ("unauthenticated-poll-refused", b"Authentication required", string(5, job)),
                ("readonly-poll-refused", b"Admin role required", string(3, reader) + string(5, job)),
            ]:
                response = fixture.restore(body)
                assert not response.get(1, 0) and not response.get(6), name + " leaked job status"
                assert expected in response.get(2, b""), name + " returned the wrong refusal"
                checks.append(name)
            finished, phases = fixture.completed(admin, job)
            target = Path(finished[3].decode())
            assert str(target).startswith(str(fixture.data) + ".restored-") and target.is_dir()
            assert not (root / "data").exists(), "restore ignored the actual --data-dir"
            again = fixture.restore(string(3, admin) + string(5, job))
            assert again.get(5) == finished[5], "completion timestamp changed on poll"
            checks.extend(["actual-data-dir-target", "grpc-progress-completed", "stable-completion-timestamp"])
            resumed = fixture.cli("restore", "--job", job, "--timeout-ms", "10000")
            assert "restart with --data-dir" in resumed and str(target) in resumed
            checks.append("cli-resume-completed")
            # Old clients omit async_restore and must receive completion, not
            # a pending response or a premature successful acceptance.
            synchronous = fixture.restore(integer(2, 1) + string(3, admin))
            assert synchronous.get(1) == 1 and synchronous.get(7) == b"completed"
            checks.append("synchronous-grpc-waits-for-completion")
            fixture.timeout_and_resume(server)
            checks.append("cli-start-timeout-and-resume")
            fixture.count(2)
            checks.append("live-data-unchanged")
            stop(server)
            # The original adapter has now checkpointed during shutdown. The
            # staged copy must still contain only the pre-backup node.
            fixture.certificate(target)
            restored_server = fixture.start(target, "restored-server")
            fixture.count(1)
            checks.append("restart-restored-copy-retains-backup-data")
            stop(restored_server)
            fixture.start(fixture.data, "cluster-server", cluster=True)
            cluster_admin = fixture.handshake("geode", fixture.password)
            refused = fixture.restore(integer(2, 1) + string(3, cluster_admin) + integer(4, 1))
            assert not refused.get(1, 0) and not refused.get(6), "cluster accepted an unreplicated restore"
            assert any(
                reason in refused.get(2, b"") for reason in (b"ClusterNotLeader", b"ClusterWriteNotReplicable")
            ), "cluster returned the wrong refusal"
            checks.append("actual-cluster-restore-refused")
            deadline = time.monotonic() + 20
            while b"state=leader" not in fixture.current_log.read_bytes():
                assert time.monotonic() < deadline, "owned singleton cluster did not elect a leader"
                time.sleep(0.1)
            refused = fixture.restore(integer(2, 1) + string(3, cluster_admin) + integer(4, 1))
            assert not refused.get(1, 0) and not refused.get(6)
            assert b"ClusterWriteNotReplicable" in refused.get(2, b""), "leader accepted an unreplicated restore"
            checks.append("actual-cluster-leader-restore-refused")
        finally:
            for process in reversed(fixture.processes):
                stop(process)
            if private_logs:
                private_logs.mkdir(mode=0o700, parents=True, exist_ok=True)
                for log in root.glob("*.log"):
                    destination = private_logs / log.name
                    shutil.copyfile(log, destination)
                    destination.chmod(0o600)
    receipt = {
        "schema": "geode.restore-transport-qualification/v1",
        "checks": checks,
        "files": finished[10],
        "observed_phases": phases,
        "owned_servers_stopped": True,
    }
    if evidence:
        evidence.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("zig-out/bin/geode"))
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--private-logs", type=Path)
    args = parser.parse_args()
    qualify(args.binary.resolve(strict=True), args.evidence, args.private_logs)
