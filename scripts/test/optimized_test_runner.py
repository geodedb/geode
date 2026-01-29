#!/usr/bin/env python3
"""Optimized test runner with reduced overhead."""

import subprocess
import sys
from collections import defaultdict
from pathlib import Path

import yaml


def run_test_fast(test_case, binary="/home/benji/src/gl/devnw/codepros/geode/zig-out/bin/geode"):
    """Run a test with minimal overhead."""
    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Add --server 127.0.0.1:3141 --insecure for query commands if not present
    if len(args) > 0 and args[0] == "query":
        if not any("--server" in str(arg) for arg in args) and not any(
            "--server 127.0.0.1:3141 --insecure" in str(arg) for arg in args
        ):
            args = ["query", "--server 127.0.0.1:3141 --insecure"] + args[1:]

    stdin_content = test_case.get("stdin", None)

    try:
        result = subprocess.run([binary] + args, input=stdin_content, capture_output=True, text=True, timeout=2)
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
                return False, f"missing '{pattern}'"

    # Check stderr_contains
    if "stderr_contains" in expect:
        for pattern in expect["stderr_contains"]:
            if pattern.lower() not in result.stderr.lower():
                return False, f"stderr missing '{pattern}'"

    return True, "PASSED"


def main():
    specs_dir = Path("/home/benji/src/gl/devnw/codepros/geode/geodetestlab/specs")

    total_passed = 0
    total_failed = 0
    total_skipped = 0
    failure_patterns = defaultdict(list)

    # Process specs in order
    for spec_file in sorted(specs_dir.glob("*.yml")):
        try:
            with open(spec_file) as f:
                spec = yaml.safe_load(f)
        except:
            continue

        for test in spec.get("tests", []):
            name = test["name"]

            if test.get("skip", False):
                total_skipped += 1
                continue

            # Skip parallel/loop tests for now
            if test.get("parallel") or test.get("loop"):
                total_skipped += 1
                continue

            success, message = run_test_fast(test)

            if success is None:
                total_skipped += 1
            elif success:
                print(f"✓ [{spec_file.name}] {name}")
                total_passed += 1
            else:
                print(f"✗ [{spec_file.name}] {name}: {message}")
                total_failed += 1
                key = message.split()[0] if " " in message else message
                failure_patterns[key].append((spec_file.name, name))

    print(f"\n{'=' * 80}")
    print(f"TOTAL: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"{'=' * 80}\n")

    if failure_patterns:
        print("TOP FAILURE PATTERNS:")
        print(f"{'=' * 80}")
        for pattern, tests in sorted(failure_patterns.items(), key=lambda x: -len(x[1]))[:10]:
            print(f"{pattern:30s} {len(tests):4d} tests")
            for spec, name in tests[:3]:
                print(f"  - [{spec}] {name}")
            if len(tests) > 3:
                print(f"  ... and {len(tests) - 3} more")
            print()

    return 0 if total_failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
