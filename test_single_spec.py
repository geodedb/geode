#!/usr/bin/env python3
"""Run a single test spec to debug specific tests."""

import subprocess
import yaml
import sys
from pathlib import Path
import uuid
import time

def run_test(test_case, binary="/home/benji/src/spyder/geode/zig-out/bin/geode"):
    """Run a single test case."""
    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Generate unique test ID
    test_id = str(uuid.uuid4())[:8]

    # Check if this test should skip isolation
    test_name = test_case.get("name", "")
    skip_isolation = "error" in test_name or "duplicate" in test_name

    processed_args = []
    for arg in args:
        if not isinstance(arg, str):
            processed_args.append(arg)
            continue

        processed_arg = arg

        # Add --no-quic for query commands
        if "query" in args and "--no-quic" not in args:
            pass  # Will add at end

        processed_args.append(processed_arg)

    # Add --no-quic if not present
    if "query" in processed_args and "--no-quic" not in processed_args:
        processed_args.insert(processed_args.index("query") + 1, "--no-quic")

    cmd = [binary] + processed_args

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
            input=None
        )
    except subprocess.TimeoutExpired:
        return False, "timeout (30s)"
    except Exception as e:
        return False, f"execution error: {e}"

    # Check expectations
    expected_code = expect.get("exit_code", 0)
    if result.returncode != expected_code:
        return False, f"exit code {result.returncode}, expected {expected_code}"

    # Check stdout_contains
    if "stdout_contains" in expect:
        for pattern in expect["stdout_contains"]:
            if pattern not in result.stdout:
                return False, f"missing: '{pattern}' in stdout"

    return True, "PASSED"


def main():
    spec_file = Path("/home/benji/src/spyder/geode/geodetestlab/specs/geode_migrations.yml")

    with open(spec_file, "r") as f:
        spec = yaml.safe_load(f)

    total_passed = 0
    total_failed = 0
    all_failures = []

    for test in spec.get("tests", []):
        name = test["name"]

        if test.get("skip", False):
            print(f"⊘ {name} [skipped]")
            continue

        success, message = run_test(test)

        if success is None:
            print(f"⊘ {name} [skipped]")
        elif success:
            print(f"✓ {name}")
            total_passed += 1
        else:
            print(f"✗ {name}: {message}")
            total_failed += 1
            all_failures.append((name, message))

    print(f"\n{'='*60}")
    print(f"TOTAL: {total_passed} passed, {total_failed} failed")
    print(f"{'='*60}")

    if all_failures:
        print(f"\nFailures:")
        for name, message in all_failures:
            print(f"  - {name}: {message}")

    return 0 if total_failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
