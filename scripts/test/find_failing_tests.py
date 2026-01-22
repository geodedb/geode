#!/usr/bin/env python3
"""Find which tests are actually failing in the extended runner."""

import subprocess
import yaml
import sys
from pathlib import Path
import os
import uuid
import time
from collections import defaultdict

# Import the run_test function from extended_test_runner
sys.path.insert(0, str(Path(__file__).parent))
from extended_test_runner import run_test

def main():
    specs_dir = Path("/home/benji/src/gl/devnw/codepros/geode/geodetestlab/specs")

    # Track failures by pattern
    failure_patterns = defaultdict(list)
    total_passed = 0
    total_failed = 0
    total_skipped = 0

    # Process all specs
    for spec_file in sorted(specs_dir.glob("*.yml")):
        try:
            with open(spec_file, "r") as f:
                spec = yaml.safe_load(f)
        except Exception as e:
            continue

        for test in spec.get("tests", []):
            name = test["name"]

            if test.get("skip", False):
                total_skipped += 1
                continue

            # Skip tests with parallel or loop for simplicity
            if test.get("parallel") or test.get("loop"):
                total_skipped += 1
                continue

            success, message = run_test(test, spec_name=spec_file.name)

            if success is None:
                total_skipped += 1
            elif success:
                total_passed += 1
            else:
                total_failed += 1
                # Categorize by failure message
                key = message.split(":")[0] if ":" in message else message
                failure_patterns[key].append((spec_file.name, name, message))

    print(f"{'='*80}")
    print(f"TEST RESULTS SUMMARY")
    print(f"{'='*80}")
    print(f"Passed:  {total_passed}")
    print(f"Failed:  {total_failed}")
    print(f"Skipped: {total_skipped}")
    print(f"{'='*80}\n")

    if failure_patterns:
        print(f"FAILURE PATTERNS:")
        print(f"{'='*80}")
        for pattern, failures in sorted(failure_patterns.items(), key=lambda x: -len(x[1])):
            print(f"\n{pattern}: {len(failures)} tests")
            # Show first 10 failures for this pattern
            for spec, name, msg in failures[:10]:
                print(f"  - [{spec}] {name}: {msg}")
            if len(failures) > 10:
                print(f"  ... and {len(failures) - 10} more")

    return 0 if total_failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
