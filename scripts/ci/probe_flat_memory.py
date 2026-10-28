"""Diagnose the ordered regression prefix on the native Linux worker."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

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
new = ('const tests = b.addTest(.{ .root_module = mod, .filters = &.{'
       + ','.join(json.dumps(name) for name in names) + '} });')
probe = Path("build.failure-probe.zig")
assert not probe.exists()
probe.write_text(source[:at] + source[at:].replace(old, new, 1))
try:
    result = subprocess.run([
        sys.executable, "scripts/ci/zig_fail_fast.py", "--log", "reports/flat-memory-probe.log",
        "--", "zig", "build", "--build-file", str(probe),
        "test-sonny-write-allowlist-r4b", "-j1", "--summary", "all", "--error-style", "verbose",
    ])
finally:
    probe.unlink()
sys.exit(result.returncode)
