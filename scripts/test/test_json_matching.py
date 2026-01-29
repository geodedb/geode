#!/usr/bin/env python3
"""Test JSON matching in extended_test_runner.py"""

import subprocess
import sys


def test_batch_update_properties():
    """Test batch-update-properties with JSON matching"""
    print("Testing batch-update-properties with JSON matching...")
    print()

    # Clean database
    subprocess.run(
        ["./zig-out/bin/geode", "query", "--server 127.0.0.1:3141 --insecure", "MATCH (n) DELETE n"],
        capture_output=True,
    )

    # Setup: Create users
    subprocess.run(
        [
            "./zig-out/bin/geode",
            "query",
            "--server 127.0.0.1:3141 --insecure",
            "--format",
            "json",
            "CREATE (:User {name: 'Alice'}), (:User {name: 'Bob', age: 25})",
        ],
        capture_output=True,
    )

    # Execute the batch update query
    result = subprocess.run(
        [
            "./zig-out/bin/geode",
            "query",
            "--server 127.0.0.1:3141 --insecure",
            "--format",
            "json",
            "MATCH (u:User) WHERE u.age IS NULL SET u.age = 0 RETURN count(u)",
        ],
        capture_output=True,
        text=True,
    )

    print(f"Exit code: {result.returncode}")
    print(f"Stdout: {result.stdout}")
    print(f"Stderr: {result.stderr}")
    print()

    # Parse JSON and check if "1" is in the values
    import json

    json_values = []
    for line in result.stdout.split("\n"):
        if line.startswith("{"):
            try:
                data = json.loads(line)
                if "rows" in data:
                    for row in data["rows"]:
                        if isinstance(row, list):
                            for val in row:
                                json_values.append(str(val))
            except:
                pass

    print(f"Extracted JSON values: {json_values}")
    print()

    if "1" in json_values:
        print("✓ JSON matching works! Found '1' in extracted values")
        return True
    else:
        print("✗ JSON matching failed! '1' not found in extracted values")
        return False


def test_json_extraction():
    """Test JSON value extraction from various formats"""
    print("Testing JSON value extraction...")
    print()

    test_cases = [
        ('{"rows":[[1]]}', ["1"]),
        ('{"rows":[[1,2,3]]}', ["1", "2", "3"]),
        ('{"rows":[["Alice", 30]]}', ["Alice", "30"]),
        ('{"status_class":"00000","columns":["count"],"rows":[[1]]}', ["1"]),
    ]

    import json

    all_passed = True

    for json_str, expected in test_cases:
        json_values = []
        try:
            data = json.loads(json_str)
            if "rows" in data:
                for row in data["rows"]:
                    if isinstance(row, list):
                        for val in row:
                            json_values.append(str(val))
        except:
            pass

        if json_values == expected:
            print(f"  ✓ {json_str[:50]:<50} → {json_values}")
        else:
            print(f"  ✗ {json_str[:50]:<50} → {json_values} (expected {expected})")
            all_passed = False

    return all_passed


if __name__ == "__main__":
    print("=" * 60)
    print("JSON Matching Test")
    print("=" * 60)
    print()

    extraction_passed = test_json_extraction()
    print()

    batch_update_passed = test_batch_update_properties()
    print()

    print("=" * 60)
    if extraction_passed and batch_update_passed:
        print("All tests passed!")
        sys.exit(0)
    else:
        print("Some tests failed!")
        sys.exit(1)
