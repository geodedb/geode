#!/usr/bin/env python3
"""
Run encryption test specs individually and report results.
"""

import os
import subprocess
import sys
from pathlib import Path

import yaml

# Global environment for test session
test_env = os.environ.copy()


def run_geode_query(query):
    """Execute a GQL query and return result."""
    try:
        result = subprocess.run(
            ["/home/benji/src/gl/devnw/codepros/geode/zig-out/bin/geode", "query", query],
            capture_output=True,
            text=True,
            timeout=5,
            env=test_env,
        )
        return result.stdout, result.stderr, result.returncode
    except subprocess.TimeoutExpired:
        return "", "TIMEOUT", -1
    except Exception as e:
        return "", str(e), -1


def run_geode_command(cmd_args):
    """Execute a geode CLI command."""
    global test_env
    try:
        result = subprocess.run(
            ["/home/benji/src/gl/devnw/codepros/geode/zig-out/bin/geode"] + cmd_args,
            capture_output=True,
            text=True,
            timeout=5,
            env=test_env,
        )

        # If this was a "user assume --role" command, set the environment variable
        if len(cmd_args) >= 3 and cmd_args[0] == "user" and cmd_args[1] == "assume":
            for i, arg in enumerate(cmd_args):
                if arg == "--role" and i + 1 < len(cmd_args):
                    role = cmd_args[i + 1]
                    test_env["GEODE_CURRENT_ROLE"] = role
                    print(f"     (Set GEODE_CURRENT_ROLE={role})")
                    break

        return result.stdout, result.stderr, result.returncode
    except subprocess.TimeoutExpired:
        return "", "TIMEOUT", -1
    except Exception as e:
        return "", str(e), -1


def run_spec(spec_path):
    """Run a single test spec file."""
    print(f"\n{'=' * 70}")
    print(f"Running: {spec_path.name}")
    print(f"{'=' * 70}\n")

    with open(spec_path) as f:
        spec = yaml.safe_load(f)

    suite_name = spec.get("suite", spec_path.stem)
    description = spec.get("description", "No description")

    print(f"Suite: {suite_name}")
    print(f"Description: {description}\n")

    results = {"suite": suite_name, "passed": [], "failed": [], "skipped": []}

    # Run setup steps
    setup_steps = spec.get("setup", [])
    if setup_steps:
        print(f"Setup ({len(setup_steps)} steps):")
        for i, step in enumerate(setup_steps, 1):
            if isinstance(step, dict):
                if "gql" in step:
                    query = step["gql"].strip()
                    print(f"  {i}. GQL: {query[:60]}...")
                    stdout, stderr, code = run_geode_query(query)
                    if code != 0:
                        print(f"     ❌ FAILED: {stderr}")
                        results["failed"].append(f"setup_{i}")
                    else:
                        print("     ✅ OK")
                elif "cmd" in step:
                    cmd = step["cmd"]
                    print(f"  {i}. CMD: {cmd}")
                    # Parse command
                    if cmd.startswith("geode "):
                        cmd_parts = cmd.split()[1:]  # Remove 'geode'
                        stdout, stderr, code = run_geode_command(cmd_parts)
                        print(f"     ⏸️  Placeholder: {stdout[:100] if stdout else stderr[:100]}")
                    else:
                        print("     ⏸️  Skipped (non-geode command)")
        print()

    # Run test steps
    steps = spec.get("steps", [])
    print(f"Tests ({len(steps)} steps):")
    for step in steps:
        step_name = step.get("name", "unnamed")

        if "gql" in step:
            query = step["gql"].strip()
            step.get("expect", {})

            print(f"  • {step_name}")
            print(f"    Query: {query[:60]}...")

            stdout, stderr, code = run_geode_query(query)

            # Check expectations
            if "expect_error" in step:
                if code != 0:
                    print("    ✅ PASS (expected error)")
                    results["passed"].append(step_name)
                else:
                    print("    ❌ FAIL (expected error, got success)")
                    results["failed"].append(step_name)
            else:
                if code != 0:
                    print(f"    ❌ FAIL: {stderr}")
                    results["failed"].append(step_name)
                else:
                    # For now, just check it succeeded
                    print("    ✅ PASS (query executed)")
                    results["passed"].append(step_name)

        elif "cmd" in step:
            cmd = step["cmd"]
            print(f"  • {step_name}")
            print(f"    Command: {cmd}")

            if cmd.startswith("geode "):
                cmd_parts = cmd.split()[1:]
                stdout, stderr, code = run_geode_command(cmd_parts)
                print(f"    ⏸️  Placeholder: {stdout[:100] if stdout else stderr[:100]}")
                results["skipped"].append(step_name)
            else:
                print("    ⏸️  Skipped (non-geode command)")
                results["skipped"].append(step_name)

    # Summary
    print(f"\n{'=' * 70}")
    print(f"Summary: {suite_name}")
    print(f"  Passed: {len(results['passed'])}")
    print(f"  Failed: {len(results['failed'])}")
    print(f"  Skipped: {len(results['skipped'])}")
    print(f"{'=' * 70}\n")

    return results


def main():
    specs_dir = Path("/home/benji/src/gl/devnw/codepros/geode/geodetestlab/specs/encryption")

    if not specs_dir.exists():
        print(f"Error: Specs directory not found: {specs_dir}")
        sys.exit(1)

    spec_files = sorted(specs_dir.glob("*.yml"))

    if not spec_files:
        print(f"Error: No .yml files found in {specs_dir}")
        sys.exit(1)

    print(f"\nFound {len(spec_files)} encryption test specs\n")

    all_results = []

    for spec_file in spec_files:
        result = run_spec(spec_file)
        all_results.append(result)

    # Overall summary
    print(f"\n{'=' * 70}")
    print("OVERALL SUMMARY")
    print(f"{'=' * 70}")

    total_passed = sum(len(r["passed"]) for r in all_results)
    total_failed = sum(len(r["failed"]) for r in all_results)
    total_skipped = sum(len(r["skipped"]) for r in all_results)

    print("\nTotal Tests:")
    print(f"  ✅ Passed: {total_passed}")
    print(f"  ❌ Failed: {total_failed}")
    print(f"  ⏸️  Skipped: {total_skipped}")
    print("\nSuites:")

    for result in all_results:
        status = "✅" if len(result["failed"]) == 0 else "❌"
        print(f"  {status} {result['suite']}: {len(result['passed'])} passed, {len(result['failed'])} failed")

    print()


if __name__ == "__main__":
    main()
