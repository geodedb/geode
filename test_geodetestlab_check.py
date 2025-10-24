#!/usr/bin/env python3
"""Test geodetestlab-style checks."""

import subprocess

def test_command(args, stderr_contains):
    """Test a command like geodetestlab does."""
    result = subprocess.run(
        ["/home/benji/src/spyder/geode/zig-out/bin/geode"] + args,
        capture_output=True,
        text=True
    )
    
    print(f"Command: geode {' '.join(args)}")
    print(f"Exit code: {result.returncode}")
    print(f"Stderr: {result.stderr[:100]}")
    
    for pattern in stderr_contains:
        if pattern.lower() not in result.stderr.lower():
            print(f"  ✗ Pattern '{pattern}' NOT found in stderr")
            return False
        else:
            print(f"  ✓ Pattern '{pattern}' found in stderr")
    
    return True

# Test the three failing cases
print("Testing invalid-command...")
test_command(["nonexistent-command"], ["error", "unknown"])

print("\nTesting invalid-option...")
test_command(["--invalid-option"], ["error", "unknown"])

print("\nTesting missing-subcommand...")
test_command([], ["error", "missing", "subcommand"])