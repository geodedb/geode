#!/usr/bin/env python3
"""Run all geodetestlab tests and track progress."""

import subprocess
import yaml
import sys
from pathlib import Path

def run_test(test_case, binary="/home/benji/src/geode/geode/zig-out/bin/geode"):
    """Run a single test case."""
    args = test_case.get("args", [])
    expect = test_case.get("expect", {})
    
    result = subprocess.run(
        [binary] + args,
        capture_output=True,
        text=True,
        timeout=5
    )
    
    # Check exit code
    if "exit_code" in expect:
        if result.returncode != expect["exit_code"]:
            return False, f"Exit code: expected {expect['exit_code']}, got {result.returncode}"
    
    # Check stdout_contains (geodetestlab checks both stdout and stderr)
    if "stdout_contains" in expect:
        combined = result.stdout + result.stderr
        for pattern in expect["stdout_contains"]:
            if pattern.lower() not in combined.lower():
                return False, f"stdout: '{pattern}' not found"
    
    # Check stderr_contains
    if "stderr_contains" in expect:
        for pattern in expect["stderr_contains"]:
            if pattern.lower() not in result.stderr.lower():
                return False, f"stderr: '{pattern}' not found"
    
    # Check stdout_regex
    if "stdout_regex" in expect:
        import re
        combined = result.stdout + result.stderr
        for pattern in expect["stdout_regex"]:
            if not re.search(pattern, combined):
                return False, f"regex: '{pattern}' not matched"
    
    return True, "PASSED"

def main():
    specs_dir = Path("/home/benji/src/geode/geode/geodetestlab/specs")
    
    # Define which specs can run without a server
    no_server_specs = [
        "geode_cli_only.yml",
        "geode_comprehensive.yml",  # We modified to not need server
    ]
    
    # Also test some from other specs that don't need server (help commands)
    partial_specs = {
        "geode_basic.yml": ["help-command", "version-command", "server-help", "shell-help", "auth-help", "user-help"],
        "geode_auth.yml": ["auth-help", "auth-login-help", "auth-logout-help"],
    }
    
    total_passed = 0
    total_failed = 0
    all_failures = []
    
    # Run no-server specs
    for spec_file in no_server_specs:
        spec_path = specs_dir / spec_file
        if not spec_path.exists():
            continue
            
        with open(spec_path, "r") as f:
            spec = yaml.safe_load(f)
        
        print(f"\n{'='*60}")
        print(f"Running tests from: {spec_file}")
        print(f"{'='*60}")
        
        for test in spec.get("tests", []):
            name = test["name"]
            success, message = run_test(test)
            
            if success:
                print(f"✓ {name}")
                total_passed += 1
            else:
                print(f"✗ {name}: {message}")
                total_failed += 1
                all_failures.append((spec_file, name, message))
    
    # Run partial specs (only tests that don't need server)
    for spec_file, test_names in partial_specs.items():
        spec_path = specs_dir / spec_file
        if not spec_path.exists():
            continue
            
        with open(spec_path, "r") as f:
            spec = yaml.safe_load(f)
        
        print(f"\n{'='*60}")
        print(f"Running selected tests from: {spec_file}")
        print(f"{'='*60}")
        
        for test in spec.get("tests", []):
            name = test["name"]
            if name not in test_names:
                continue
                
            success, message = run_test(test)
            
            if success:
                print(f"✓ {name}")
                total_passed += 1
            else:
                print(f"✗ {name}: {message}")
                total_failed += 1
                all_failures.append((spec_file, name, message))
    
    # Summary
    print(f"\n{'='*60}")
    print(f"SUMMARY: {total_passed}/{total_passed+total_failed} tests passed")
    print(f"{'='*60}")
    
    if all_failures:
        print(f"\nFailed tests ({len(all_failures)}):")
        for spec_file, name, message in all_failures:
            print(f"  [{spec_file}] {name}: {message}")
        
        # Group failures by type
        print(f"\nFailure analysis:")
        failure_types = {}
        for spec_file, name, message in all_failures:
            key = message.split(":")[0] if ":" in message else message
            if key not in failure_types:
                failure_types[key] = []
            failure_types[key].append(name)
        
        for failure_type, tests in failure_types.items():
            print(f"  {failure_type}: {len(tests)} tests")
            if len(tests) <= 5:
                for test in tests:
                    print(f"    - {test}")
    
    return 0 if total_failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())