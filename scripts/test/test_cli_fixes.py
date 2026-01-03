#!/usr/bin/env python3
"""Direct test runner for Geode CLI fixes."""

import subprocess
import sys

def run_command(args, check_exit_code=None, check_stdout=None, check_stderr=None):
    """Run a command and check its output."""
    result = subprocess.run(
        ["/home/benji/src/geode/geode/zig-out/bin/geode"] + args,
        capture_output=True,
        text=True
    )
    
    success = True
    if check_exit_code is not None and result.returncode != check_exit_code:
        success = False
        print(f"  ✗ Expected exit code {check_exit_code}, got {result.returncode}")
    
    if check_stdout:
        # Check both stdout and stderr since help text goes to stderr currently
        combined_output = result.stdout + result.stderr
        for text in check_stdout:
            if text not in combined_output:
                success = False
                print(f"  ✗ Expected '{text}' in output")
    
    if check_stderr:
        for text in check_stderr:
            if text not in result.stderr:
                success = False
                print(f"  ✗ Expected '{text}' in stderr")
    
    return success

def main():
    tests = [
        # Basic help tests
        ("help-command", ["--help"], 0, ["Usage:", "Subcommands:"], None),
        ("serve-help", ["serve", "--help"], 0, ["serve", "Start", "database", "server"], None),
        ("query-help", ["query", "--help"], 0, ["query", "Execute", "GQL"], None),
        ("backup-help", ["backup", "--help"], 0, ["backup", "database"], None),
        ("restore-help", ["restore", "--help"], 0, ["restore", "database"], None),
        ("migrate-help", ["migrate", "--help"], 0, ["migrate", "database"], None),
        
        # Auth commands
        ("auth-help", ["auth", "--help"], 0, ["auth", "commands"], None),
        ("auth-login-help", ["auth", "login", "--help"], 0, ["login", "Authenticate"], None),
        ("auth-logout-help", ["auth", "logout", "--help"], 0, ["logout", "Clear", "credentials"], None),
        
        # User commands
        ("user-help", ["user", "--help"], 0, ["user", "management"], None),
        ("user-create-help", ["user", "create", "--help"], 0, ["create", "user"], None),
        ("user-list-help", ["user", "list", "--help"], 0, ["list", "users"], None),
        ("user-delete-help", ["user", "delete", "--help"], 0, ["delete", "user"], None),
        ("user-show-help", ["user", "show", "--help"], 0, ["show", "user"], None),
        
        # Role commands
        ("role-help", ["role", "--help"], 0, ["role", "management"], None),
        ("role-create-help", ["role", "create", "--help"], 0, ["create", "role"], None),
        ("role-list-help", ["role", "list", "--help"], 0, ["list", "roles"], None),
        ("role-delete-help", ["role", "delete", "--help"], 0, ["delete", "role"], None),
        
        # Policy commands
        ("policy-help", ["policy", "--help"], 0, ["policy", "RLS"], None),
        ("policy-create-help", ["policy", "create", "--help"], 0, ["create", "policy"], None),
        ("policy-list-help", ["policy", "list", "--help"], 0, ["list", "policies"], None),
        ("policy-delete-help", ["policy", "delete", "--help"], 0, ["delete", "policy"], None),
        
        # Grant and Revoke
        ("grant-help", ["grant", "--help"], 0, ["grant", "permissions"], None),
        ("revoke-help", ["revoke", "--help"], 0, ["revoke", "permissions"], None),
        
        # Error cases (checking for "Error" with capital E)
        ("invalid-command", ["nonexistent-command"], 2, None, ["Error", "unknown"]),
        ("invalid-option", ["--invalid-option"], 2, None, ["Error", "unknown"]),
        ("missing-subcommand", [], 2, None, ["Error", "missing"]),
        
        # Global options
        ("verbose-flag", ["--verbose", "--help"], 0, ["Usage:"], None),
        ("json-flag", ["--json", "--help"], 0, ["Usage:"], None),
        ("config-flag", ["--config", "/nonexistent/config.toml", "--help"], 0, ["Usage:"], None),
        
        # Audit options
        ("audit-flag", ["--audit", "--help"], 0, ["Usage:"], None),
        ("audit-file-flag", ["--audit-file", "/tmp/audit.log", "--help"], 0, ["Usage:"], None),
        ("audit-syslog-flag", ["--audit-syslog", "localhost:514", "--help"], 0, ["Usage:"], None),
        
        # Combined options
        ("multiple-options", ["--verbose", "--json", "--audit", "--help"], 0, ["Usage:"], None),
        
        # Subcommand errors
        ("auth-missing-subcommand", ["auth"], 2, None, ["missing", "subcommand"]),
        ("user-missing-subcommand", ["user"], 2, None, ["missing", "subcommand"]),
        ("role-missing-subcommand", ["role"], 2, None, ["missing", "subcommand"]),
        ("policy-missing-subcommand", ["policy"], 2, None, ["missing", "subcommand"]),
    ]
    
    passed = 0
    failed = 0
    
    print("Running Geode CLI tests...")
    print("=" * 60)
    
    for name, args, exit_code, stdout_checks, stderr_checks in tests:
        print(f"\nTest: {name}")
        print(f"  Command: geode {' '.join(args)}")
        
        if run_command(args, exit_code, stdout_checks, stderr_checks):
            print(f"  ✓ PASSED")
            passed += 1
        else:
            print(f"  ✗ FAILED")
            failed += 1
    
    print("\n" + "=" * 60)
    print(f"Results: {passed}/{passed+failed} tests passed")
    
    if failed > 0:
        print(f"\n{failed} tests failed!")
        sys.exit(1)
    else:
        print("\nAll tests passed!")
        sys.exit(0)

if __name__ == "__main__":
    main()