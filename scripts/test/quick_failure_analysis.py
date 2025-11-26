#!/usr/bin/env python3
"""Quick analysis of failing tests to categorize them."""

import subprocess
import yaml
from pathlib import Path
from collections import defaultdict

def main():
    specs_dir = Path("/home/benji/src/spyder/geode/geodetestlab/specs")
    binary = "/home/benji/src/spyder/geode/zig-out/bin/geode"

    # Categories
    server_tests = []  # Tests that need a running server
    no_quic_tests = []  # Tests that can run with --server 127.0.0.1:3141 --insecure
    unknown_tests = []

    # Analyze each spec
    for spec_file in sorted(specs_dir.glob("*.yml")):
        try:
            with open(spec_file, "r") as f:
                spec = yaml.safe_load(f)
        except:
            continue

        # Check if spec requires server
        server_enabled = False
        cli_config = spec.get("cli", {})
        if isinstance(cli_config, dict):
            server_config = cli_config.get("server", {})
            if isinstance(server_config, dict):
                server_enabled = server_config.get("enabled", False)

        # Check each test
        for test in spec.get("tests", []):
            if test.get("skip", False):
                continue

            name = test.get("name", "unknown")
            args = test.get("args", [])

            # Categorize based on first arg (subcommand)
            if len(args) > 0:
                cmd = args[0]

                # Server-dependent commands
                if cmd in ["auth", "user", "role", "policy", "grant", "revoke"]:
                    server_tests.append((spec_file.name, name, cmd))
                # Query command can run with --server 127.0.0.1:3141 --insecure
                elif cmd == "query":
                    # But check if it has --server flag
                    if any("--server" in str(arg) for arg in args):
                        server_tests.append((spec_file.name, name, "query with --server"))
                    else:
                        no_quic_tests.append((spec_file.name, name, cmd))
                # Other commands
                elif cmd in ["serve", "backup", "restore", "migrate"]:
                    server_tests.append((spec_file.name, name, cmd))
                else:
                    no_quic_tests.append((spec_file.name, name, cmd))
            else:
                unknown_tests.append((spec_file.name, name, "no args"))

    # Print summary
    print(f"{'='*80}")
    print(f"TEST CATEGORIZATION")
    print(f"{'='*80}\n")

    print(f"Server-dependent tests: {len(server_tests)}")
    if server_tests:
        by_cmd = defaultdict(list)
        for spec, name, cmd in server_tests:
            by_cmd[cmd].append((spec, name))

        for cmd, tests in sorted(by_cmd.items()):
            print(f"\n  {cmd}: {len(tests)} tests")
            for spec, name in tests[:5]:
                print(f"    - [{spec}] {name}")
            if len(tests) > 5:
                print(f"    ... and {len(tests) - 5} more")

    print(f"\n{'='*80}")
    print(f"No-QUIC compatible tests: {len(no_quic_tests)}")
    if no_quic_tests:
        by_cmd = defaultdict(list)
        for spec, name, cmd in no_quic_tests:
            by_cmd[cmd].append((spec, name))

        for cmd, tests in sorted(by_cmd.items()):
            print(f"\n  {cmd}: {len(tests)} tests")

    print(f"\n{'='*80}")
    print(f"Unknown tests: {len(unknown_tests)}")

    print(f"\n{'='*80}")
    print(f"RECOMMENDATION:")
    print(f"{'='*80}")
    print(f"1. Server-dependent commands (auth/user/role/policy/grant/revoke) need either:")
    print(f"   a) A running server to connect to")
    print(f"   b) Implementation of --server 127.0.0.1:3141 --insecure mode for these commands")
    print(f"   c) Mock implementation for testing without server")
    print(f"\n2. For now, we should either:")
    print(f"   - Skip server-dependent tests in extended_test_runner.py")
    print(f"   - Or implement --server 127.0.0.1:3141 --insecure mode for these commands")

if __name__ == "__main__":
    main()
