#!/usr/bin/env python3
"""Quick test of a few specs from extended_test_runner to see what's failing."""

import subprocess
import yaml
import sys
from pathlib import Path
import os
import uuid
import time

# Import the run_test function from extended_test_runner
sys.path.insert(0, str(Path(__file__).parent))
from extended_test_runner import run_test

def main():
    specs_dir = Path("/home/benji/src/gl/devnw/geode/geode/geodetestlab/specs")

    # Test just a few specific specs
    test_specs = [
        "geode_cli_only.yml",
        "geode_auth.yml",
    ]

    total_passed = 0
    total_failed = 0
    total_skipped = 0
    all_failures = []

    for spec_name in test_specs:
        spec_file = specs_dir / spec_name
        if not spec_file.exists():
            continue

        try:
            with open(spec_file, "r") as f:
                spec = yaml.safe_load(f)
        except Exception as e:
            print(f"Skipping {spec_name}: Invalid YAML - {e}")
            continue

        print(f"\n{'='*60}")
        print(f"Testing: {spec_name}")
        print(f"{'='*60}")

        spec_passed = 0
        spec_failed = 0
        spec_skipped = 0

        for test in spec.get("tests", []):
            name = test["name"]

            if test.get("skip", False):
                spec_skipped += 1
                total_skipped += 1
                continue

            success, message = run_test(test, spec_name=spec_name)

            if success is None:
                spec_skipped += 1
                total_skipped += 1
            elif success:
                print(f"✓ {name}")
                spec_passed += 1
                total_passed += 1
            else:
                print(f"✗ {name}: {message}")
                spec_failed += 1
                total_failed += 1
                all_failures.append((spec_name, name, message))

        print(f"  {spec_name}: {spec_passed} passed, {spec_failed} failed, {spec_skipped} skipped")

    print(f"\n{'='*60}")
    print(f"TOTAL: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    print(f"{'='*60}")

    if all_failures:
        print(f"\nFailures:")
        for spec_file, name, message in all_failures:
            print(f"  [{spec_file}] {name}: {message}")

    return 0 if total_failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
