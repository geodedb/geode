#!/usr/bin/env python3
"""Quick test of auth commands"""

import subprocess
import sys

def test_auth_help():
    result = subprocess.run(
        ["./zig-out/bin/geode", "auth", "--help"],
        capture_output=True,
        text=True,
        timeout=5
    )

    if result.returncode != 0:
        print(f"FAIL: auth-help - exit code {result.returncode}")
        return False

    combined = result.stdout + result.stderr
    if "login" in combined.lower() and "logout" in combined.lower() and "authentication" in combined.lower():
        print(f"PASS: auth-help")
        return True
    else:
        print(f"FAIL: auth-help - missing expected text")
        print(f"stdout: {result.stdout}")
        print(f"stderr: {result.stderr}")
        return False

def test_auth_login():
    result = subprocess.run(
        ["./zig-out/bin/geode", "auth", "login", "--user", "admin"],
        capture_output=True,
        text=True,
        timeout=5
    )

    if result.returncode != 0:
        print(f"FAIL: auth-login-admin - exit code {result.returncode}")
        return False

    combined = result.stdout + result.stderr
    if "successful" in combined.lower() and "login" in combined.lower():
        print(f"PASS: auth-login-admin")
        return True
    else:
        print(f"FAIL: auth-login-admin - missing expected text")
        print(f"stdout: {result.stdout}")
        print(f"stderr: {result.stderr}")
        return False

def test_user_create():
    result = subprocess.run(
        ["./zig-out/bin/geode", "user", "create", "testuser", "test@example.com"],
        capture_output=True,
        text=True,
        timeout=5
    )

    if result.returncode != 0:
        print(f"FAIL: user-create - exit code {result.returncode}")
        return False

    combined = result.stdout + result.stderr
    if "created" in combined.lower() and "testuser" in combined.lower():
        print(f"PASS: user-create")
        return True
    else:
        print(f"FAIL: user-create - missing expected text")
        print(f"stdout: {result.stdout}")
        print(f"stderr: {result.stderr}")
        return False

def main():
    tests = [
        test_auth_help,
        test_auth_login,
        test_user_create,
    ]

    passed = 0
    failed = 0

    for test in tests:
        if test():
            passed += 1
        else:
            failed += 1

    print(f"\n{passed} passed, {failed} failed")
    return 0 if failed == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
