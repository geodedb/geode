#!/usr/bin/env python3
"""Quick overview of test failures across all specs."""

import subprocess
import yaml
from pathlib import Path
from collections import defaultdict

def run_test(test_case, binary="/home/benji/src/gl/devnw/geode/geode/zig-out/bin/geode"):
    """Run a single test case."""
    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Add --server 127.0.0.1:3141 --insecure if not present for query commands
    if "query" in args and "--server 127.0.0.1:3141 --insecure" not in args:
        args = args.copy()
        args.insert(args.index("query") + 1, "--server 127.0.0.1:3141 --insecure")

    cmd = [binary] + args

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
            input=None
        )
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except Exception as e:
        return False, "error"

    # Check exit code
    expected_code = expect.get("exit_code", 0)
    if result.returncode != expected_code:
        return False, "exit_code"

    # Check stdout_contains
    if "stdout_contains" in expect:
        for pattern in expect["stdout_contains"]:
            if pattern not in result.stdout:
                return False, "missing"

    return True, "passed"


def test_spec(spec_path):
    """Quick test of a single spec."""
    try:
        with open(spec_path, "r") as f:
            spec = yaml.safe_load(f)
    except:
        return 0, 0, 0

    passed = failed = skipped = 0

    for test in spec.get("tests", []):
        if test.get("skip", False):
            skipped += 1
            continue

        success, _ = run_test(test)

        if success is None:
            skipped += 1
        elif success:
            passed += 1
        else:
            failed += 1

    return passed, failed, skipped


def main():
    specs_dir = Path("/home/benji/src/gl/devnw/geode/geode/geodetestlab/specs")

    # Focus on specs mentioned in user's context
    priority_specs = [
        "geode_migrations.yml",
        "geode_tde_security.yml",
        "geode_cdc_comprehensive.yml",
        "geode_audit_logging_enterprise.yml",
        "geode_auth_security.yml",
    ]

    print("Testing Priority Specs:")
    print("="*60)

    total_passed = total_failed = total_skipped = 0

    for spec_name in priority_specs:
        spec_path = specs_dir / spec_name
        if not spec_path.exists():
            print(f"  {spec_name:<45} NOT FOUND")
            continue

        passed, failed, skipped = test_spec(spec_path)
        total_passed += passed
        total_failed += failed
        total_skipped += skipped

        status = "✓" if failed == 0 else "✗"
        print(f"  {status} {spec_name:<40} {passed:>3}p {failed:>3}f {skipped:>3}s")

    print("="*60)
    print(f"  TOTAL: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")

    # Now sample other specs
    print("\n\nSampling Other Specs (first 10):")
    print("="*60)

    other_specs = sorted([s for s in specs_dir.glob("*.yml") if s.name not in priority_specs])[:10]

    other_passed = other_failed = other_skipped = 0

    for spec_path in other_specs:
        passed, failed, skipped = test_spec(spec_path)
        other_passed += passed
        other_failed += failed
        other_skipped += skipped

        if failed > 0:
            status = "✗"
            print(f"  {status} {spec_path.name:<40} {passed:>3}p {failed:>3}f {skipped:>3}s")

    print("="*60)
    print(f"  Sample: {other_passed} passed, {other_failed} failed, {other_skipped} skipped")


if __name__ == "__main__":
    main()
