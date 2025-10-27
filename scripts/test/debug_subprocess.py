#!/usr/bin/env python3
"""Debug why geode hangs in subprocess."""

import subprocess
import sys

binary = '/home/benji/src/spyder/geode/zig-out/bin/geode'

print("Test 1: Run with shell=True")
try:
    result = subprocess.run(
        f'{binary} query --no-quic "RETURN 1 AS x"',
        shell=True,
        capture_output=True,
        text=True,
        timeout=2
    )
    print(f"✓ Success: exit={result.returncode}")
    print(f"  Output: {result.stdout[:50]}")
except subprocess.TimeoutExpired:
    print(f"✗ TIMEOUT")
except Exception as e:
    print(f"✗ Error: {e}")

print("\nTest 2: Run with shell=False")
try:
    result = subprocess.run(
        [binary, 'query', '--no-quic', 'RETURN 1 AS x'],
        capture_output=True,
        text=True,
        timeout=2
    )
    print(f"✓ Success: exit={result.returncode}")
    print(f"  Output: {result.stdout[:50]}")
except subprocess.TimeoutExpired:
    print(f"✗ TIMEOUT")
except Exception as e:
    print(f"✗ Error: {e}")

print("\nTest 3: Run with shell=False and input=''")
try:
    result = subprocess.run(
        [binary, 'query', '--no-quic', 'RETURN 1 AS x'],
        input='',
        capture_output=True,
        text=True,
        timeout=2
    )
    print(f"✓ Success: exit={result.returncode}")
    print(f"  Output: {result.stdout[:50]}")
except subprocess.TimeoutExpired:
    print(f"✗ TIMEOUT")
except Exception as e:
    print(f"✗ Error: {e}")

print("\nTest 4: Check if geode --help works")
try:
    result = subprocess.run(
        [binary, '--help'],
        capture_output=True,
        text=True,
        timeout=2
    )
    print(f"✓ Success: exit={result.returncode}")
    print(f"  Output: {result.stdout[:50]}")
except subprocess.TimeoutExpired:
    print(f"✗ TIMEOUT")
except Exception as e:
    print(f"✗ Error: {e}")
