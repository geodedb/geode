#!/usr/bin/env python3
"""Stop a Zig build's process group after its first reported failed step.

Zig 0.16 continues independent build steps after a failure. Its build runner
prints `failed command:` even for successful tests that write warnings, so
that text alone is not a failure signal. Require a failed step summary first,
then preserve its diagnostics before terminating the build and its children.
"""

import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
STEP = re.compile(r"^[ |]*(?:\+-|\\-) ")
FAILURE = re.compile(
    r"(?: [1-9][0-9]* errors| failure)$"
    r"|(?:, |; )[1-9][0-9]* (?:fail|crash|timeout|leaks|error logs)\b"
)


def failed_step(line):
    clean = ANSI.sub("", line).rstrip()
    return bool(STEP.match(clean) and FAILURE.search(clean))


def run(command, log_path=None):
    log = None
    if log_path:
        path = Path(log_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        log = path.open("w")
    child = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace", start_new_session=True,
    )
    failed = False
    interrupted = 0
    timer = None

    def send(sig):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin can return EPERM for a group after its leader has been
            # reaped. Preserve the build's result in that case; a live build
            # that we cannot stop must still report the permission failure.
            if child.poll() is None:
                raise
            print("Build exited; the OS denied final process-group cleanup.",
                  file=sys.stderr, flush=True)

    def stop(sig):
        nonlocal timer
        if timer is None:
            send(sig)
            timer = threading.Timer(2, send, args=(signal.SIGKILL,))
            timer.daemon = True
            timer.start()

    def interrupted_by(sig, _frame):
        nonlocal interrupted
        interrupted = sig
        stop(sig)

    previous = {sig: signal.signal(sig, interrupted_by)
                for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        for line in child.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            if log:
                log.write(line)
                log.flush()
            failed = failed or failed_step(line)
            if failed and ANSI.sub("", line).startswith("failed command:"):
                stop(signal.SIGTERM)
        rc = child.wait()
        if interrupted:
            return 128 + interrupted
        if failed:
            print("Zig step failed; stopped the remaining build processes.", flush=True)
            return 1
        return rc if rc >= 0 else 128 - rc
    finally:
        # Also reap descendants that closed their output or ignored SIGTERM.
        try:
            send(signal.SIGKILL)
            child.wait()
        finally:
            child.stdout.close()
            if timer:
                timer.cancel()
            if log:
                log.close()
            for sig, handler in previous.items():
                signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    return run(command, args.log)


if __name__ == "__main__":
    sys.exit(main())
