#!/usr/bin/env python3
"""Parallel optimized test runner with smart caching and minimal overhead."""

import multiprocessing as mp
import os
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path

import yaml

# Categorize tests that need cleanup vs read-only
NEEDS_CLEANUP_PATTERNS = [
    "CREATE",
    "MERGE",
    "DELETE",
    "SET",
    "REMOVE",
    "DROP",
    "ALTER",
    "INSERT",
    "UPDATE",
    "create",
    "delete",
    "enable",
    "disable",
]


def needs_cleanup(test_case):
    """Determine if test modifies state and needs cleanup."""
    args = test_case.get("args", [])
    stdin = test_case.get("stdin", "")

    # Check args for write operations
    args_str = " ".join(str(arg) for arg in args)
    if any(pattern in args_str for pattern in NEEDS_CLEANUP_PATTERNS):
        return True

    # Check stdin for write operations
    if stdin and any(pattern in stdin for pattern in NEEDS_CLEANUP_PATTERNS):
        return True

    # Has setup/teardown = likely modifies state
    if test_case.get("setup") or test_case.get("teardown"):
        return True

    return False


def categorize_test_speed(test_case):
    """Categorize test by expected execution time."""
    args = test_case.get("args", [])

    if not args:
        return "fast"

    cmd = args[0] if args else ""

    # Fast: Help commands, version, simple CLI
    if any(flag in args for flag in ["--help", "-h", "--version", "-v"]):
        return "fast"

    # Fast: Auth, user, role commands (simple operations)
    if cmd in ["auth", "user", "role", "policy", "grant", "revoke"]:
        return "fast"

    # Medium: Simple queries
    if cmd == "query":
        query_str = " ".join(str(arg) for arg in args)
        # Fast queries: RETURN, simple MATCH
        if "RETURN 1" in query_str or "RETURN count" in query_str:
            return "fast"
        # Slow queries: CALL procedures, complex operations
        if "CALL" in query_str or "PROCEDURE" in query_str:
            return "slow"
        return "medium"

    # Slow: Backup, restore, serve
    if cmd in ["backup", "restore", "serve", "migrate"]:
        return "slow"

    return "medium"


def cleanup_files():
    """Clean up catalog and persistence files."""
    try:
        os.remove("/tmp/geode_graph_store.dat")
    except FileNotFoundError:
        pass

    home_dir = os.path.expanduser("~")
    catalog_paths = [
        f"{home_dir}/.geode/catalog.json",
        f"{home_dir}/.geode/catalog_indexes.json",
        f"{home_dir}/.geode/catalog_schemas.json",
    ]
    for catalog_path in catalog_paths:
        try:
            os.remove(catalog_path)
        except FileNotFoundError:
            pass


def run_test_worker(test_data):
    """Worker function to run a single test."""
    test_case, spec_name, binary = test_data

    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Add --server 127.0.0.1:3141 --insecure for query commands
    if len(args) > 0 and args[0] == "query":
        if not any("--server" in str(arg) for arg in args) and not any(
            "--server 127.0.0.1:3141 --insecure" in str(arg) for arg in args
        ):
            args = ["query", "--server 127.0.0.1:3141 --insecure"] + args[1:]

    # Only cleanup if test modifies state
    if needs_cleanup(test_case):
        cleanup_files()

    stdin_content = test_case.get("stdin", None)

    # Determine timeout based on test speed
    speed = categorize_test_speed(test_case)
    timeout = {"fast": 1, "medium": 2, "slow": 5}.get(speed, 2)

    try:
        result = subprocess.run([binary] + args, input=stdin_content, capture_output=True, text=True, timeout=timeout)
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


def process_spec_file(spec_file_path):
    """Process a single spec file and return results."""
    try:
        with open(spec_file_path) as f:
            spec = yaml.safe_load(f)
    except:
        return []

    binary = "/home/benji/src/gl/devnw/codepros/geode/zig-out/bin/geode"
    results = []

    for test in spec.get("tests", []):
        name = test["name"]

        # Skip parallel/loop tests for now
        if test.get("parallel") or test.get("loop"):
            results.append((spec_file_path.name, name, None, "skipped"))
            continue

        success, message = run_test_worker((test, spec_file_path.name, binary))
        results.append((spec_file_path.name, name, success, message))

    return results


def main():
    specs_dir = Path("/home/benji/src/gl/devnw/codepros/geode/geodetestlab/specs")

    # Get all spec files
    spec_files = sorted(specs_dir.glob("*.yml"))

    print(f"Running {len(spec_files)} spec files with {mp.cpu_count()} workers...")
    print(f"{'=' * 80}\n")

    start_time = time.time()

    # Use multiprocessing pool to process spec files in parallel
    num_workers = min(8, mp.cpu_count())
    with mp.Pool(num_workers) as pool:
        all_results = pool.map(process_spec_file, spec_files)

    # Flatten results
    results = [item for sublist in all_results for item in sublist]

    # Aggregate statistics
    total_passed = 0
    total_failed = 0
    total_skipped = 0
    failure_patterns = defaultdict(list)

    for spec_name, test_name, success, message in results:
        if success is None:
            total_skipped += 1
        elif success:
            print(f"✓ [{spec_name}] {test_name}")
            total_passed += 1
        else:
            print(f"✗ [{spec_name}] {test_name}: {message}")
            total_failed += 1
            key = message.split()[0] if " " in message else message
            failure_patterns[key].append((spec_name, test_name))

    elapsed = time.time() - start_time

    print(f"\n{'=' * 80}")
    print(f"TOTAL: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"Time: {elapsed:.2f} seconds ({total_passed + total_failed + total_skipped} tests)")
    print(f"Speed: {(total_passed + total_failed + total_skipped) / elapsed:.1f} tests/second")
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
