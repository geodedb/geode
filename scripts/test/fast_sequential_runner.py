#!/usr/bin/env python3
"""Fast sequential test runner with minimal overhead."""

import subprocess
import yaml
import sys
from pathlib import Path
import os
from collections import defaultdict
import time

BINARY = "/home/benji/src/spyder/geode/zig-out/bin/geode"

def is_readonly_test(test_case):
    """Check if test is read-only (doesn't modify state)."""
    args = test_case.get("args", [])
    if not args:
        return True

    cmd = args[0] if args else ""

    # Help commands are read-only
    if any(flag in args for flag in ["--help", "-h", "--version", "-v"]):
        return True

    # Auth/user commands that modify state
    if cmd in ["user", "role", "policy", "grant", "revoke"]:
        subcommands = args[1:] if len(args) > 1 else []
        if any(sc in ["create", "delete", "enable", "disable"] for sc in subcommands):
            return False

    # Query commands with write operations
    if cmd == "query":
        query_str = " ".join(str(arg) for arg in args)
        if any(op in query_str.upper() for op in ["CREATE", "MERGE", "DELETE", "SET", "REMOVE", "DROP", "ALTER"]):
            return False

    return True

def run_test(test_case, spec_name):
    """Run a single test with minimal overhead."""
    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Skip parallel/loop tests
    if test_case.get("parallel") or test_case.get("loop"):
        return None, "skipped (parallel/loop)"

    # Add --server 127.0.0.1:3141 --insecure for query commands
    modified_args = args[:]
    if len(args) > 0 and args[0] == "query":
        if not any("--server" in str(arg) for arg in args) and not any("--server 127.0.0.1:3141 --insecure" in str(arg) for arg in args):
            modified_args = ["query", "--server 127.0.0.1:3141 --insecure"] + args[1:]

    stdin_content = test_case.get("stdin", None)

    # Determine timeout: 1s for fast tests, 2s for others
    timeout = 1 if is_readonly_test(test_case) else 2

    try:
        result = subprocess.run(
            [BINARY] + modified_args,
            input=stdin_content,
            capture_output=True,
            text=True,
            timeout=timeout
        )
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, str(e)

    # Check exit code
    if "exit_code" in expect:
        if result.returncode != expect["exit_code"]:
            return False, f"exit code {result.returncode}"

    # Check stdout_contains
    if "stdout_contains" in expect:
        combined = result.stdout + result.stderr
        for pattern in expect["stdout_contains"]:
            if pattern.lower() not in combined.lower():
                return False, f"missing"

    # Check stderr_contains
    if "stderr_contains" in expect:
        for pattern in expect["stderr_contains"]:
            if pattern.lower() not in result.stderr.lower():
                return False, f"stderr missing"

    return True, "PASSED"

def main():
    specs_dir = Path("/home/benji/src/spyder/geode/geodetestlab/specs")

    total_passed = 0
    total_failed = 0
    total_skipped = 0
    failure_patterns = defaultdict(list)

    start_time = time.time()

    # Process each spec file
    for spec_file in sorted(specs_dir.glob("*.yml")):
        try:
            with open(spec_file, "r") as f:
                spec = yaml.safe_load(f)
        except:
            continue

        for test in spec.get("tests", []):
            name = test["name"]

            success, message = run_test(test, spec_file.name)

            if success is None:
                total_skipped += 1
            elif success:
                # Only print failures and summary to reduce output
                total_passed += 1
            else:
                print(f"✗ [{spec_file.name}] {name}: {message}")
                total_failed += 1
                key = message.split()[0] if " " in message else message
                failure_patterns[key].append((spec_file.name, name))

    elapsed = time.time() - start_time
    total_tests = total_passed + total_failed + total_skipped

    print(f"\n{'='*80}")
    print(f"RESULTS: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"Time: {elapsed:.1f}s ({total_tests} tests, {total_tests/elapsed:.1f} tests/sec)")
    print(f"Pass rate: {100*total_passed/max(1,total_passed+total_failed):.1f}%")
    print(f"{'='*80}\n")

    if failure_patterns:
        print(f"TOP FAILURE PATTERNS:")
        print(f"{'='*80}")
        for pattern, tests in sorted(failure_patterns.items(), key=lambda x: -len(x[1]))[:15]:
            print(f"{pattern:30s} {len(tests):4d} tests")
        print()

    return 0 if total_failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
