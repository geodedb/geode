#!/usr/bin/env python3
"""Verify all geodetestlab comprehensive tests would pass."""

import subprocess
import yaml

def run_test(test_case):
    """Run a single test case."""
    args = test_case.get("args", [])
    expect = test_case.get("expect", {})
    
    result = subprocess.run(
        ["/home/benji/src/gl/devnw/geode/geode/zig-out/bin/geode"] + args,
        capture_output=True,
        text=True
    )
    
    # Check exit code
    if "exit_code" in expect:
        if result.returncode != expect["exit_code"]:
            return False, f"Expected exit code {expect['exit_code']}, got {result.returncode}"
    
    # Check stdout_contains (geodetestlab checks both stdout and stderr)
    if "stdout_contains" in expect:
        combined = result.stdout + result.stderr
        for pattern in expect["stdout_contains"]:
            if pattern.lower() not in combined.lower():
                return False, f"Pattern '{pattern}' not found in output"
    
    # Check stderr_contains
    if "stderr_contains" in expect:
        for pattern in expect["stderr_contains"]:
            if pattern.lower() not in result.stderr.lower():
                return False, f"Pattern '{pattern}' not found in stderr"
    
    return True, "PASSED"

# Load the spec
with open("/home/benji/src/gl/devnw/geode/geode/geodetestlab/specs/geode_comprehensive.yml", "r") as f:
    spec = yaml.safe_load(f)

passed = 0
failed = 0
failures = []

print("Running geodetestlab comprehensive tests...")
print("=" * 60)

for test in spec["tests"]:
    name = test["name"]
    success, message = run_test(test)
    
    if success:
        print(f"✓ {name}")
        passed += 1
    else:
        print(f"✗ {name}: {message}")
        failed += 1
        failures.append(name)

print("\n" + "=" * 60)
print(f"Results: {passed}/{passed+failed} tests passed")

if failed > 0:
    print(f"\nFailed tests:")
    for name in failures:
        print(f"  - {name}")
else:
    print("\nAll tests passed!")