#!/usr/bin/env python3
"""Test system features (TDE, CDC, Audit, Auth)."""

import subprocess
import yaml
from pathlib import Path

def run_test(test_case, binary="./zig-out/bin/geode"):
    """Run a single test case."""
    if test_case.get("skip", False):
        return None, "skipped"

    args = test_case.get("args", [])
    expect = test_case.get("expect", {})

    # Build command
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
                return False, f"missing '{pattern}' in stdout"

    # Check stderr_contains
    if "stderr_contains" in expect:
        for pattern in expect["stderr_contains"]:
            if pattern not in result.stderr:
                return False, f"missing '{pattern}' in stderr"

    return True, "PASSED"


def test_spec(spec_path):
    """Test a single spec file."""
    with open(spec_path, "r") as f:
        spec = yaml.safe_load(f)

    spec_name = Path(spec_path).name
    print(f"\n{'='*60}")
    print(f"Testing: {spec_name}")
    print(f"{'='*60}")

    passed = 0
    failed = 0
    skipped = 0
    failures = []

    for test in spec.get("tests", []):
        name = test["name"]

        if test.get("skip", False):
            print(f"⊘ {name} [skipped]")
            skipped += 1
            continue

        success, message = run_test(test)

        if success is None:
            print(f"⊘ {name} [skipped]")
            skipped += 1
        elif success:
            print(f"✓ {name}")
            passed += 1
        else:
            print(f"✗ {name}: {message}")
            failed += 1
            failures.append((name, message))

    print(f"\n{spec_name}: {passed} passed, {failed} failed, {skipped} skipped")

    return passed, failed, skipped, failures


def main():
    specs = [
        "/home/benji/src/geode/geode/geodetestlab/specs/geode_tde_security.yml",
        "/home/benji/src/geode/geode/geodetestlab/specs/geode_cdc_comprehensive.yml",
        "/home/benji/src/geode/geode/geodetestlab/specs/geode_audit_logging_enterprise.yml",
        "/home/benji/src/geode/geode/geodetestlab/specs/geode_auth_security.yml",
    ]

    total_passed = 0
    total_failed = 0
    total_skipped = 0
    all_failures = []

    for spec_path in specs:
        if not Path(spec_path).exists():
            print(f"Skipping {Path(spec_path).name}: File not found")
            continue

        passed, failed, skipped, failures = test_spec(spec_path)
        total_passed += passed
        total_failed += failed
        total_skipped += skipped
        all_failures.extend([(Path(spec_path).name, name, msg) for name, msg in failures])

    print(f"\n{'='*60}")
    print(f"TOTAL: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"{'='*60}")

    if all_failures:
        print(f"\nFailed tests:")
        for spec, name, message in all_failures[:20]:  # Show first 20 failures
            print(f"  [{spec}] {name}: {message}")
        if len(all_failures) > 20:
            print(f"  ... and {len(all_failures) - 20} more")

    return 0 if total_failed == 0 else 1


if __name__ == "__main__":
    import sys
    sys.exit(main())
