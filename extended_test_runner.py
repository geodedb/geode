#!/usr/bin/env python3
"""Extended test runner that tries more tests to identify what needs fixing."""

import subprocess
import yaml
import sys
from pathlib import Path

def run_test(test_case, binary="/home/benji/src/spyder/geode/zig-out/bin/geode"):
    """Run a single test case."""
    args = test_case.get("args", [])
    expect = test_case.get("expect", {})
    
    # Skip tests that need server
    needs_server = any("${server" in str(arg) for arg in args)
    needs_server = needs_server or any("--server" in str(arg) for arg in args)
    if needs_server:
        return None, "needs server"
    
    # Skip tests with complex expectations we can't check
    if "geode_query" in expect:
        return None, "needs query execution"
    if "stdout_json_assert" in expect:
        return None, "needs JSON parsing"
    
    try:
        result = subprocess.run(
            [binary] + args,
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
    
    # Check stdout_contains (geodetestlab checks both stdout and stderr)
    if "stdout_contains" in expect:
        combined = result.stdout + result.stderr
        for pattern in expect["stdout_contains"]:
            if pattern.lower() not in combined.lower():
                return False, f"missing: '{pattern}'"
    
    # Check stderr_contains
    if "stderr_contains" in expect:
        for pattern in expect["stderr_contains"]:
            if pattern.lower() not in result.stderr.lower():
                return False, f"stderr missing: '{pattern}'"
    
    # Check stdout_regex
    if "stdout_regex" in expect:
        import re
        combined = result.stdout + result.stderr
        for pattern in expect["stdout_regex"]:
            try:
                if not re.search(pattern, combined):
                    return False, f"regex not matched: '{pattern}'"
            except:
                return False, f"invalid regex: '{pattern}'"
    
    return True, "PASSED"

def main():
    specs_dir = Path("/home/benji/src/spyder/geode/geodetestlab/specs")
    
    # Run all specs and see what we can test
    total_passed = 0
    total_failed = 0
    total_skipped = 0
    all_failures = []
    
    for spec_file in sorted(specs_dir.glob("*.yml")):
        # Try to load the spec
        try:
            with open(spec_file, "r") as f:
                spec = yaml.safe_load(f)
        except Exception as e:
            print(f"Skipping {spec_file.name}: Invalid YAML")
            continue
        
        has_tests = False
        spec_passed = 0
        spec_failed = 0
        spec_skipped = 0
        
        for test in spec.get("tests", []):
            name = test["name"]
            success, message = run_test(test)
            
            if success is None:
                # Skipped
                spec_skipped += 1
                total_skipped += 1
            elif success:
                print(f"✓ [{spec_file.name}] {name}")
                spec_passed += 1
                total_passed += 1
                has_tests = True
            else:
                print(f"✗ [{spec_file.name}] {name}: {message}")
                spec_failed += 1
                total_failed += 1
                all_failures.append((spec_file.name, name, message))
                has_tests = True
        
        if has_tests:
            print(f"  {spec_file.name}: {spec_passed} passed, {spec_failed} failed, {spec_skipped} skipped")
            print()
    
    # Summary
    print(f"\n{'='*60}")
    print(f"TOTAL: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"{'='*60}")
    
    if all_failures:
        # Group failures by message type
        failure_types = {}
        for spec_file, name, message in all_failures:
            key = message.split(":")[0] if ":" in message else message
            if key not in failure_types:
                failure_types[key] = []
            failure_types[key].append((spec_file, name))
        
        print(f"\nFailure types:")
        for failure_type, tests in sorted(failure_types.items(), key=lambda x: -len(x[1])):
            print(f"  {failure_type}: {len(tests)} tests")
            if len(tests) <= 3:
                for spec_file, test in tests:
                    print(f"    - [{spec_file}] {test}")
    
    return 0 if total_failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())