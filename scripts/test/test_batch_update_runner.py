#!/usr/bin/env python3
"""Test batch-update-properties with the updated test runner logic"""

import subprocess
from pathlib import Path

import yaml


def run_test(test_case, binary="/home/benji/src/gl/devnw/codepros/geode/zig-out/bin/geode"):
    """Run a single test case using updated test runner logic"""
    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Add --server 127.0.0.1:3141 --insecure if not present
    if "query" in args and "--server 127.0.0.1:3141 --insecure" not in args:
        args = args.copy()
        args.insert(args.index("query") + 1, "--server 127.0.0.1:3141 --insecure")

    # Run setup commands if present
    setup_commands = test_case.get("setup", [])
    if setup_commands:
        import shlex

        for cmd_str in setup_commands:
            try:
                setup_args = shlex.split(cmd_str)
                # Add --server 127.0.0.1:3141 --insecure to setup commands
                if "query" in setup_args and "--server 127.0.0.1:3141 --insecure" not in setup_args:
                    setup_args.insert(setup_args.index("query") + 1, "--server 127.0.0.1:3141 --insecure")
                subprocess.run([binary] + setup_args, capture_output=True, text=True, timeout=30)
            except Exception as e:
                return False, f"setup failed: {e}"

    cmd = [binary] + args

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, input=None)
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, f"error: {e}"

    # Check exit code
    expected_code = expect.get("exit_code", 0)
    if result.returncode != expected_code:
        return False, f"exit_code: expected {expected_code}, got {result.returncode}"

    # Check stdout_contains with JSON parsing
    if "stdout_contains" in expect:
        import json

        # Try JSON parsing first
        json_values = []
        for line in result.stdout.split("\n"):
            if line.startswith("{"):
                try:
                    data = json.loads(line)
                    if "rows" in data:
                        for row in data["rows"]:
                            if isinstance(row, list):
                                for val in row:
                                    json_values.append(str(val))
                            elif isinstance(row, dict):
                                for val in row.values():
                                    json_values.append(str(val))
                except:
                    pass

        # Build combined output
        combined = result.stdout + result.stderr
        if json_values:
            combined += " " + " ".join(json_values)

        for pattern in expect["stdout_contains"]:
            # Try exact match in JSON values first
            if json_values and pattern in json_values:
                continue

            # Fall back to string matching
            if pattern.lower() not in combined.lower():
                return False, f"missing: '{pattern}' (JSON values: {json_values})"

    return True, "PASSED"


def main():
    spec_file = Path("/home/benji/src/gl/devnw/codepros/geode/geodetestlab/specs/geode_migrations.yml")

    with open(spec_file) as f:
        spec = yaml.safe_load(f)

    # Find batch-update-properties test
    for test in spec.get("tests", []):
        if test["name"] == "batch-update-properties":
            print("Testing batch-update-properties with JSON matching...")
            print(f"Test: {test['name']}")
            print(f"Setup: {test.get('setup', [])}")
            print(f"Args: {test['args']}")
            print(f"Expect: {test['expect']}")
            print()

            success, message = run_test(test)

            if success:
                print(f"✓ {test['name']}: {message}")
                return 0
            else:
                print(f"✗ {test['name']}: {message}")
                return 1

    print("Test not found!")
    return 1


if __name__ == "__main__":
    import sys

    sys.exit(main())
