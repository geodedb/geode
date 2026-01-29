#!/usr/bin/env python3
"""Debug script to run a single test and show detailed output."""

import sys
from pathlib import Path

import yaml

# Import the run_test function from extended_test_runner
sys.path.insert(0, str(Path(__file__).parent))
from extended_test_runner import run_test


def main():
    spec_file = Path("geodetestlab/specs/session_parameter_unit_tests.yml")

    with open(spec_file) as f:
        spec = yaml.safe_load(f)

    # Run the first failing test
    test_name = "session-set-table-shorthand"
    test = [t for t in spec["tests"] if t["name"] == test_name][0]

    print(f"=== Running test: {test_name} ===")
    print(f"Args: {test['args']}")
    print(f"Stdin: {repr(test['stdin'])}")
    print(f"Expect: {test['expect']}")
    print()

    success, message = run_test(test, spec_name=spec_file.name)

    print("=== Result ===")
    print(f"Success: {success}")
    print(f"Message: {message}")


if __name__ == "__main__":
    main()
