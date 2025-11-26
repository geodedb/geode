#!/usr/bin/env python3
"""Test CREATE SCHEMA with embedded server"""

import subprocess
import sys

def test_create_schema():
    # Test CREATE SCHEMA with embedded server
    cmd = [
        "/home/benji/src/spyder/geode/zig-out/bin/geode",
        "query",
        "--server 127.0.0.1:3141 --insecure",
        "CREATE SCHEMA test_schema"
    ]
    
    print(f"Running: {' '.join(cmd)}")
    
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=10
    )
    
    print(f"Exit code: {result.returncode}")
    print(f"STDOUT:\n{result.stdout}")
    print(f"STDERR:\n{result.stderr}")
    
    # Check for success
    if result.returncode == 0 and "Schema test_schema created successfully" in result.stdout:
        print("✓ CREATE SCHEMA test passed!")
        return True
    else:
        print("✗ CREATE SCHEMA test failed!")
        return False

if __name__ == "__main__":
    success = test_create_schema()
    sys.exit(0 if success else 1)