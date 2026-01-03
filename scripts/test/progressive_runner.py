#!/usr/bin/env python3
"""Progressive test runner that processes specs one at a time with progress reporting."""

import subprocess
import yaml
import sys
from pathlib import Path
from collections import defaultdict
import time

BINARY = "/home/benji/src/geode/geode/zig-out/bin/geode"

def run_test_simple(test_case):
    """Run test with minimal overhead - no cleanup, no isolation."""
    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Skip parallel/loop
    if test_case.get("parallel") or test_case.get("loop"):
        return None, "skipped"

    # Add --server 127.0.0.1:3141 --insecure for query
    if len(args) > 0 and args[0] == "query":
        if not any("--server" in str(arg) for arg in args) and not any("--server 127.0.0.1:3141 --insecure" in str(arg) for arg in args):
            args = ["query", "--server 127.0.0.1:3141 --insecure"] + args[1:]

    try:
        result = subprocess.run(
            [BINARY] + args,
            input=test_case.get("stdin"),
            capture_output=True,
            text=True,
            timeout=1
        )
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, str(e)

    # Check exit code
    if "exit_code" in expect and result.returncode != expect["exit_code"]:
        return False, f"exit code"

    # Check stdout_contains
    if "stdout_contains" in expect:
        combined = result.stdout + result.stderr
        for pattern in expect["stdout_contains"]:
            if pattern.lower() not in combined.lower():
                return False, "missing"

    # Check stderr_contains
    if "stderr_contains" in expect:
        for pattern in expect["stderr_contains"]:
            if pattern.lower() not in result.stderr.lower():
                return False, "stderr missing"

    return True, "PASSED"

def process_spec(spec_file):
    """Process a single spec file."""
    try:
        with open(spec_file, "r") as f:
            spec = yaml.safe_load(f)
    except Exception as e:
        print(f"Error loading {spec_file.name}: {e}")
        return 0, 0, 0, []

    passed = 0
    failed = 0
    skipped = 0
    failures = []

    for test in spec.get("tests", []):
        success, message = run_test_simple(test)

        if success is None:
            skipped += 1
        elif success:
            passed += 1
        else:
            failed += 1
            failures.append((test["name"], message))

    return passed, failed, skipped, failures

def main():
    specs_dir = Path("/home/benji/src/geode/geode/geodetestlab/specs")
    spec_files = sorted(specs_dir.glob("*.yml"))

    print(f"Processing {len(spec_files)} spec files...")
    print(f"{'='*80}\n")

    total_passed = 0
    total_failed = 0
    total_skipped = 0
    all_failures = defaultdict(list)

    start_time = time.time()

    for i, spec_file in enumerate(spec_files, 1):
        spec_start = time.time()
        passed, failed, skipped, failures = process_spec(spec_file)

        total_passed += passed
        total_failed += failed
        total_skipped += skipped

        # Aggregate failures by pattern
        for test_name, message in failures:
            all_failures[message].append((spec_file.name, test_name))

        # Progress reporting
        spec_time = time.time() - spec_start
        print(f"[{i}/{len(spec_files)}] {spec_file.name:50s} {passed:3d}P {failed:3d}F {skipped:3d}S  ({spec_time:.1f}s)")

    elapsed = time.time() - start_time
    total_tests = total_passed + total_failed + total_skipped

    print(f"\n{'='*80}")
    print(f"FINAL: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"Time: {elapsed:.1f}s ({total_tests} tests, {total_tests/elapsed:.1f} tests/sec)")
    if total_passed + total_failed > 0:
        print(f"Pass rate: {100*total_passed/(total_passed+total_failed):.1f}%")
    print(f"{'='*80}\n")

    if all_failures:
        print(f"TOP FAILURE PATTERNS:")
        print(f"{'='*80}")
        for pattern, tests in sorted(all_failures.items(), key=lambda x: -len(x[1]))[:20]:
            print(f"{pattern:30s} {len(tests):4d} tests")
        print()

    return 0 if total_failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
