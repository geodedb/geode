"""Diagnose the ordered regression prefix on the native Linux worker."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

from instrument_zig_runner import instrument

resources = {"cpus": os.cpu_count()}
for name in ("/proc/meminfo", "/sys/fs/cgroup/cpu.max", "/sys/fs/cgroup/memory.max"):
    path = Path(name)
    if path.exists():
        resources[name] = path.read_text()[:2000]
print(json.dumps(resources), flush=True)

source = Path("build.zig").read_text()
anchor = '.root_source_file = b.path("tests/test_sonny_write_allowlist_r4b.zig")'
start = source.index(anchor)
old = 'const tests = b.addTest(.{ .root_module = mod });'
at = source.index(old, start)
names = re.findall(r'^test "([^"]+)"', Path("tests/test_sonny_write_allowlist_r4b.zig").read_text(), re.M)
assert len(names) == 22 and "nested statements" in names[-1]
# Preserve all preceding tests and their order, including both bounded joins.
# Only the final, unrelated parser-depth stress test is outside this probe.
names = names[:-1]
print(json.dumps({"ordered_tests": names}), flush=True)
# Avoid apostrophes in full test names: Zig's response-file tokenizer treats
# those as quotes. These stable prefixes select exactly the same 21 tests.
filters = sorted({name.split(":", 1)[0].split(" (", 1)[0] for name in names})
assert all(any(value in name for value in filters) for name in names)
assert not any(value in "SONNY-3244 (I-4): nested statements and expressions are refused, never crash an 8 MiB or a 16 MiB thread" for value in filters)
progress = Path("reports/ordered-test-progress.log").resolve()
progress.parent.mkdir(parents=True, exist_ok=True)
progress.unlink(missing_ok=True)
runner = Path("probe-test-runner.zig")
assert not runner.exists()
zig_lib = Path(shutil.which("zig")).resolve().parent / "lib"
runner.write_text(instrument((zig_lib / "compiler/test_runner.zig").read_text(), progress))
new = ('const tests = b.addTest(.{ .root_module = mod, '
       '.test_runner = .{ .path = b.path("probe-test-runner.zig"), .mode = .server }, .filters = &.{'
       + ','.join(json.dumps(value) for value in filters) + '} });')
probe = Path("build.failure-probe.zig")
assert not probe.exists()
probe.write_text(source[:at] + source[at:].replace(old, new, 1))
try:
    result = subprocess.Popen([
        sys.executable, "scripts/ci/zig_fail_fast.py", "--log", "reports/flat-memory-probe.log",
        "--", "zig", "build", "--build-file", str(probe),
        "test-sonny-write-allowlist-r4b", "-j1", "--summary", "all", "--error-style", "verbose",
    ])
    printed = 0
    sampled = 0
    while result.poll() is None:
        if progress.exists():
            lines = progress.read_text().splitlines()
            for line in lines[printed:]:
                print(json.dumps({"at": time.time(), "test_progress": line}), flush=True)
            printed = len(lines)
        if time.monotonic() - sampled >= 30:
            processes = {}
            for path in Path("/proc").glob("[0-9]*/stat"):
                try:
                    raw = path.read_text()
                    fields = raw.rsplit(")", 1)[1].split()
                    processes[int(path.parent.name)] = {
                        "ppid": int(fields[1]), "state": fields[0],
                        "cpu_ticks": int(fields[11]) + int(fields[12]),
                        "rss_pages": int(fields[21]),
                        "wait": (path.parent / "wchan").read_text().strip(),
                        "command": raw.split("(", 1)[1].rsplit(")", 1)[0],
                    }
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    continue
            owned = {result.pid}
            while True:
                expanded = owned | {pid for pid, item in processes.items() if item["ppid"] in owned}
                if expanded == owned:
                    break
                owned = expanded
            print(json.dumps({"at": time.time(), "processes": {pid: processes[pid] for pid in sorted(owned) if pid in processes}}), flush=True)
            sampled = time.monotonic()
        try:
            result.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    if progress.exists():
        for line in progress.read_text().splitlines()[printed:]:
            print(json.dumps({"at": time.time(), "test_progress": line}), flush=True)
finally:
    probe.unlink()
    runner.unlink()
sys.exit(result.returncode)
