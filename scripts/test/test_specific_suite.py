#!/usr/bin/env python3
"""Test a specific suite to identify failures."""

import subprocess
import yaml
import sys
from pathlib import Path
import uuid
import time
import os

def run_test(test_case, binary="/home/benji/src/spyder/geode/zig-out/bin/geode", spec_name=""):
    """Run a single test case."""
    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Generate unique test ID for isolation
    test_id = str(uuid.uuid4())[:8]
    test_timestamp = int(time.time() * 1000)

    # Check if this test should skip isolation
    skip_isolation = False
    test_name = test_case.get("name", "")
    if "error" in test_name or "duplicate" in test_name or test_case.get("skip_isolation", False):
        skip_isolation = True

    # Clear persistence files
    try:
        os.remove('/tmp/geode_graph_store.dat')
    except FileNotFoundError:
        pass

    if not skip_isolation:
        home_dir = os.path.expanduser('~')
        catalog_paths = [
            f'{home_dir}/.geode/catalog.json',
            f'{home_dir}/.geode/catalog_indexes.json',
            f'{home_dir}/.geode/catalog_schemas.json',
        ]
        for catalog_path in catalog_paths:
            try:
                os.remove(catalog_path)
            except FileNotFoundError:
                pass

    # Execute setup commands if present
    setup_commands = test_case.get("setup", [])
    if setup_commands:
        import shlex
        for cmd_item in setup_commands:
            try:
                if isinstance(cmd_item, dict):
                    setup_args = cmd_item.get("args", [])
                    setup_stdin = cmd_item.get("stdin", None)
                else:
                    setup_args = shlex.split(cmd_item)
                    setup_stdin = None

                setup_result = subprocess.run(
                    [binary] + setup_args,
                    input=setup_stdin,
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                if setup_result.returncode != 0:
                    error_msg = f"setup command failed (exit {setup_result.returncode})"
                    if setup_result.stderr:
                        error_msg += f": {setup_result.stderr[:200]}"
                    return False, error_msg
            except Exception as e:
                return False, f"setup error: {str(e)}"

    # Get stdin content if present
    stdin_content = test_case.get("stdin", None)

    try:
        result = subprocess.run(
            [binary] + args,
            input=stdin_content,
            capture_output=True,
            text=True,
            timeout=5
        )
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, str(e)

    # Check exit code
    if "exit_code" in expect:
        if result.returncode != expect["exit_code"]:
            return False, f"exit code: expected {expect['exit_code']}, got {result.returncode}"

    # Check stdout_contains
    if "stdout_contains" in expect:
        combined = result.stdout + result.stderr
        for pattern in expect["stdout_contains"]:
            if pattern.lower() not in combined.lower():
                return False, f"missing: '{pattern}'"

    # Check stderr_contains
    if "stderr_contains" in expect:
        combined_stderr = result.stderr
        for pattern in expect["stderr_contains"]:
            if pattern.lower() not in combined_stderr.lower():
                return False, f"stderr missing: '{pattern}'"

    return True, "PASSED"

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 test_specific_suite.py <spec_file.yml>")
        sys.exit(1)

    spec_file = Path(sys.argv[1])
    if not spec_file.exists():
        print(f"Error: {spec_file} not found")
        sys.exit(1)

    with open(spec_file, "r") as f:
        spec = yaml.safe_load(f)

    total_passed = 0
    total_failed = 0
    total_skipped = 0
    all_failures = []

    for test in spec.get("tests", []):
        name = test["name"]

        if test.get("skip", False):
            total_skipped += 1
            continue

        success, message = run_test(test, spec_name=spec_file.name)

        if success is None:
            total_skipped += 1
        elif success:
            print(f"✓ {name}")
            total_passed += 1
        else:
            print(f"✗ {name}: {message}")
            total_failed += 1
            all_failures.append((spec_file.name, name, message))

    print(f"\n{'='*60}")
    print(f"{spec_file.name}: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"{'='*60}")

    if all_failures:
        print(f"\nFailures:")
        for spec_file, name, message in all_failures:
            print(f"  [{spec_file}] {name}: {message}")

    return 0 if total_failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
