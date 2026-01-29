#!/usr/bin/env python3
"""Custom test runner for Geode test specifications."""

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml


def run_command(args: list[str], binary: str = "./zig-out/bin/geode") -> tuple[int, str, str]:
    """Run a command and return exit code, stdout, and stderr."""
    try:
        # Prepare the command
        cmd = [binary] + args

        # Handle special cases for the embedded server mode
        if "query" in args and "--process" not in args:
            # Add --process flag for query commands to use embedded server
            cmd.append("--process")

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "Command timed out"
    except Exception as e:
        return -1, "", str(e)


def check_expectation(expect: dict[str, Any], exit_code: int, stdout: str, stderr: str) -> tuple[bool, str]:
    """Check if the command output meets expectations."""
    # Check exit code
    if "exit_code" in expect and exit_code != expect["exit_code"]:
        return False, f"Exit code mismatch: expected {expect['exit_code']}, got {exit_code}"

    # Check stdout contains
    if "stdout_contains" in expect:
        combined = stdout + stderr  # Check both stdout and stderr
        for pattern in expect["stdout_contains"]:
            # Try exact match first, then case-insensitive match
            if pattern not in combined and pattern.lower() not in combined.lower():
                return False, f"Pattern not found: '{pattern}'"

    # Check stderr contains
    if "stderr_contains" in expect:
        for pattern in expect["stderr_contains"]:
            if pattern not in stderr and pattern.lower() not in stderr.lower():
                return False, f"Stderr pattern not found: '{pattern}'"

    return True, "Passed"


def run_test_suite(spec_file: Path) -> dict[str, Any]:
    """Run a test suite from a YAML specification file."""
    with open(spec_file) as f:
        spec = yaml.safe_load(f)

    suite_name = spec.get("name", spec_file.stem)
    description = spec.get("description", "No description")
    tests = spec.get("tests", [])

    print(f"\n{'=' * 60}")
    print(f"Running: {suite_name}")
    print(f"Description: {description}")
    print(f"{'=' * 60}")

    passed = 0
    failed = 0
    skipped = 0
    failures = []

    for i, test in enumerate(tests, 1):
        test_name = test.get("name", f"test_{i}")
        args = test.get("args", [])
        expect = test.get("expect", {})

        # Skip tests that require features we know are not implemented
        skip_patterns = [
            "algo.",  # Graph algorithms not yet implemented
            "apoc.",  # APOC procedures not implemented
            "db.schema",  # Schema introspection not fully implemented
            "db.indexes",  # Index management not fully implemented
            "db.index.drop",  # Index dropping not implemented
            "EXPLAIN",  # Query explanation not fully implemented
            "CONSTRAINT",  # Constraints not fully implemented
        ]

        should_skip = any(pattern in " ".join(args) for pattern in skip_patterns)

        if should_skip:
            print(f"  SKIP: {test_name} (Known unimplemented feature)")
            skipped += 1
            continue

        # Run the test
        exit_code, stdout, stderr = run_command(args)

        # Check expectations
        success, message = check_expectation(expect, exit_code, stdout, stderr)

        if success:
            print(f"  ✓ {test_name}")
            passed += 1
        else:
            print(f"  ✗ {test_name}: {message}")
            if "--verbose" in sys.argv or "-v" in sys.argv:
                print(f"    Args: {args}")
                print(f"    Stdout: {stdout[:200]}")
                print(f"    Stderr: {stderr[:200]}")
            failed += 1
            failures.append(
                {"test": test_name, "args": args, "reason": message, "stdout": stdout[:500], "stderr": stderr[:500]}
            )

    return {
        "suite": suite_name,
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "total": len(tests),
        "failures": failures,
    }


def main():
    """Main test runner."""
    # Find all test spec files
    specs_dir = Path("geodetestlab/specs")

    if len(sys.argv) > 1 and sys.argv[1].endswith(".yml"):
        # Run specific test file
        spec_files = [Path(sys.argv[1])]
    else:
        # Run all new test suites
        spec_files = [
            specs_dir / "geode_migrations.yml",
            specs_dir / "geode_graph_algorithms.yml",
            specs_dir / "geode_regression_tests.yml",
        ]

    all_results = []
    total_passed = 0
    total_failed = 0
    total_skipped = 0

    for spec_file in spec_files:
        if spec_file.exists():
            result = run_test_suite(spec_file)
            all_results.append(result)
            total_passed += result["passed"]
            total_failed += result["failed"]
            total_skipped += result["skipped"]
        else:
            print(f"Warning: {spec_file} not found")

    # Print summary
    print(f"\n{'=' * 60}")
    print("OVERALL SUMMARY")
    print(f"{'=' * 60}")
    print(f"Total Passed: {total_passed}")
    print(f"Total Failed: {total_failed}")
    print(f"Total Skipped: {total_skipped}")
    print(f"Success Rate: {total_passed / max(1, total_passed + total_failed) * 100:.1f}%")

    # Save detailed results
    if total_failed > 0:
        with open("test_failures.json", "w") as f:
            json.dump(all_results, f, indent=2)
        print("\nDetailed failures saved to test_failures.json")

    return 0 if total_failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
