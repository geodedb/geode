#!/usr/bin/env python3
"""Test multiple operations with embedded server"""

import subprocess
import sys

def run_query(query, expect_exit_code=0):
    cmd = [
        "/home/benji/src/geode/geode/zig-out/bin/geode",
        "query",
        "--server 127.0.0.1:3141 --insecure",
        query
    ]
    
    print(f"Running: {query}")
    
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=10
    )
    
    print(f"Exit code: {result.returncode} (expected: {expect_exit_code})")
    
    if result.returncode != expect_exit_code:
        print(f"STDOUT:\n{result.stdout}")
        print(f"STDERR:\n{result.stderr}")
        return False
    
    return True

def main():
    tests = [
        ("CREATE SCHEMA test_schema2", 0),
        ("DROP SCHEMA test_schema2", 0),
        ("CREATE SCHEMA IF NOT EXISTS conditional_schema", 0),
        ("CREATE SCHEMA IF NOT EXISTS conditional_schema", 0),  # Should succeed (already exists)
        ("DROP SCHEMA IF EXISTS conditional_schema", 0),
        ("DROP SCHEMA IF EXISTS nonexistent_schema", 0),  # Should succeed (doesn't exist)
        ("RETURN 1 AS x", 0),
        ("RETURN 'hello' AS greeting", 0),
    ]
    
    passed = 0
    failed = 0
    
    for query, expected_exit in tests:
        if run_query(query, expected_exit):
            passed += 1
            print("✓ PASSED\n")
        else:
            failed += 1
            print("✗ FAILED\n")
    
    print(f"Results: {passed} passed, {failed} failed")
    return failed == 0

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1)