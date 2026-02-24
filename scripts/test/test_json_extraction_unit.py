#!/usr/bin/env python3
"""Unit tests for JSON value extraction logic"""

import json


def extract_json_values(output):
    """Extract values from JSON output (mimics test runner logic)"""
    json_values = []
    for line in output.split("\n"):
        if line.startswith("{"):
            try:
                data = json.loads(line)
                # Extract values from JSON structure
                if "rows" in data:
                    for row in data["rows"]:
                        if isinstance(row, list):
                            for val in row:
                                json_values.append(str(val))
                        elif isinstance(row, dict):
                            for val in row.values():
                                json_values.append(str(val))

            except Exception:
                pass
    return json_values


def test_extraction(name, output, expected_values, expected_patterns):
    """Test JSON extraction and pattern matching"""
    extracted = extract_json_values(output)

    # Check extracted values
    values_match = extracted == expected_values

    # Check pattern matching
    patterns_match = all(pattern in extracted for pattern in expected_patterns)

    if values_match and patterns_match:
        print(f"✓ {name}")
        print(f"  Extracted: {extracted}")
        print(f"  Patterns matched: {expected_patterns}")
    else:
        print(f"✗ {name}")
        print(f"  Expected values: {expected_values}")
        print(f"  Got values: {extracted}")
        print(f"  Expected patterns: {expected_patterns}")
        print(f"  Patterns matched: {[p for p in expected_patterns if p in extracted]}")
        return False

    return True


def main():
    print("=" * 60)
    print("JSON Value Extraction Unit Tests")
    print("=" * 60)
    print()

    tests = [
        (
            "Simple count",
            '{"status_class":"00000","columns":[{"name":"count","type":"INTEGER"}],"rows":[{"count":1}]}',
            ["1"],
            ["1"],
        ),
        (
            "Multiple values in row",
            '{"status_class":"00000","columns":[{"name":"a","type":"INTEGER"},{"name":"b","type":"INTEGER"},{"name":"c","type":"INTEGER"}],"rows":[{"a":1,"b":2,"c":3}]}',
            ["1", "2", "3"],
            ["1", "2", "3"],
        ),
        (
            "String and numeric",
            '{"status_class":"00000","columns":[{"name":"name","type":"STRING"},{"name":"age","type":"INTEGER"}],"rows":[{"name":"Alice","age":30}]}',
            ["Alice", "30"],
            ["Alice", "30"],
        ),
        (
            "Multiple rows",
            '{"status_class":"00000","columns":[{"name":"name","type":"STRING"},{"name":"age","type":"INTEGER"}],"rows":[{"name":"Bob","age":25},{"name":"Alice","age":0}]}',
            ["Bob", "25", "Alice", "0"],
            ["Bob", "25", "Alice", "0"],
        ),
        ("Empty result", '{"status_class":"00000","columns":[],"rows":[]}', [], []),
        (
            "batch-update-properties output",
            '{"status_class":"00000","columns":[{"name":"count","type":"INTEGER"}],"rows":[{"count":1}],"flagger_findings":[]}',
            ["1"],
            ["1"],
        ),
    ]

    all_passed = True
    for name, output, expected_values, expected_patterns in tests:
        if not test_extraction(name, output, expected_values, expected_patterns):
            all_passed = False
        print()

    print("=" * 60)
    if all_passed:
        print("✓ All tests passed!")
        return 0
    else:
        print("✗ Some tests failed!")
        return 1


if __name__ == "__main__":
    import sys

    sys.exit(main())
