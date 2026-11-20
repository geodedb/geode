#!/usr/bin/env python3
"""Test specific features that were recently implemented."""

import json
import os
import subprocess
import sys

ADMIN_USER = os.getenv("GEODE_ADMIN_USERNAME", "geode")
ADMIN_PASS = os.getenv("GEODE_DEFAULT_PASSWORD", "Geode Test Admin Passphrase")


def run_query(query, user=ADMIN_USER, password=ADMIN_PASS, server="127.0.0.1:3141"):
    """Run a query and return stdout."""
    cmd = ["./zig-out/bin/geode", "query", "--server", server, "--insecure", "--format", "json", "-"]
    if user is not None:
        cmd.extend(["--user", user, "--password", password or ""])

    result = subprocess.run(cmd, input=query, capture_output=True, text=True, timeout=10)
    return result.returncode, result.stdout, result.stderr


def json_rows_contain_value(stdout, expected):
    for line in stdout.splitlines():
        if not line.startswith("{"):
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        rows = data.get("rows", [])
        for row in rows:
            if isinstance(row, dict):
                if expected in row.values():
                    return True
            elif isinstance(row, list) and expected in row:
                return True
    return False


def test_split_node():
    """Test split-node-into-multiple variable scoping."""
    print("Testing split-node-into-multiple...")

    # Clean database
    run_query("MATCH (n) DELETE n")

    # Setup
    run_query("CREATE (:Person {name: 'John', type: 'employee', department: 'Engineering'})")

    # Execute split-node query
    query = """MATCH (p:Person) WHERE p.type = 'employee'
               CREATE (e:Employee {name: p.name}), (d:Department {name: p.department})
               CREATE (e)-[:WORKS_IN]->(d)
               DELETE p
               RETURN count(e)"""

    code, stdout, stderr = run_query(query)

    if code == 0 and json_rows_contain_value(stdout, 1):
        print("  ✓ split-node-into-multiple: PASSED")
        return True
    else:
        print("  ✗ split-node-into-multiple: FAILED")
        print(f"    stdout: {stdout}")
        print(f"    stderr: {stderr}")
        return False


def test_not_pattern():
    """Test NOT (pattern) syntax."""
    print("Testing NOT (pattern) syntax...")

    # Clean database
    run_query("MATCH (n) DELETE n")

    # Create test data
    run_query("CREATE (:A {id: 1}), (:A {id: 2})-[:REL]->(:B {id: 3})")

    # Query for orphaned nodes using NOT pattern
    query = "MATCH (n) WHERE NOT (n)--() DELETE n RETURN count(n)"

    code, stdout, stderr = run_query(query)

    if code == 0 and json_rows_contain_value(stdout, 1):
        print("  ✓ NOT (pattern): PASSED")
        return True
    else:
        print("  ✗ NOT (pattern): FAILED")
        print(f"    stdout: {stdout}")
        print(f"    stderr: {stderr}")
        return False


def test_batch_create_relationships():
    """Test batch-create-relationships."""
    print("Testing batch-create-relationships...")

    # Clean database
    run_query("MATCH (n) DELETE n")

    # Execute batch create query
    query = """CREATE (:User {name: 'Alice'}), (:User {name: 'Bob'}), (:User {name: 'Charlie'})
               MATCH (u1:User), (u2:User) WHERE u1.name < u2.name
               CREATE (u1)-[:POTENTIAL_FRIEND]->(u2)
               RETURN count(*)"""

    code, stdout, stderr = run_query(query)

    if code == 0 and json_rows_contain_value(stdout, 3):
        print("  ✓ batch-create-relationships: PASSED")
        return True
    else:
        print("  ✗ batch-create-relationships: FAILED")
        print(f"    stdout: {stdout}")
        print(f"    stderr: {stderr}")
        return False


def test_auth_system():
    """Test authentication system."""
    print("Testing authentication system...")

    # Start server with auth enabled (default)
    server = subprocess.Popen(
        [
            "./zig-out/bin/geode",
            "serve",
            "--listen",
            "127.0.0.1:9999",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    import time

    time.sleep(2)  # Wait for server to start

    try:
        # Test 1: Unauthenticated query should fail
        print("  Testing unauthenticated access...")
        code, stdout, stderr = run_query("RETURN 1", user=None, password=None, server="127.0.0.1:9999")
        combined = stdout + stderr
        if "Authentication required" in combined or code != 0:
            print("  ✓ Unauthenticated access blocked")
        else:
            print("  ✗ Unauthenticated access not blocked as expected")
            return False

        code, stdout, stderr = run_query("RETURN 1", user=ADMIN_USER, password=ADMIN_PASS, server="127.0.0.1:9999")
        if code == 0 and '"status_class":"00000"' in stdout:
            print("  ✓ Authenticated access allowed")
            return True
        print("  ✗ Authenticated access failed")
        return False

    finally:
        server.terminate()
        server.wait()


def test_tde_validation():
    """Test TDE provider validation."""
    print("Testing TDE provider validation...")

    # Test invalid provider
    query = "CALL tde.configure_provider('InvalidProvider', 'key123')"
    code, stdout, stderr = run_query(query)

    # Should return error
    if "InvalidKeyProvider" in stderr or "error" in stdout.lower():
        print("  ✓ TDE validation: PASSED")
        return True
    else:
        print("  ✗ TDE validation: FAILED (expected error)")
        print(f"    stdout: {stdout}")
        return False


def test_cdc_validation():
    """Test CDC guardrail validation."""
    print("Testing CDC guardrail validation...")

    # Test invalid threshold
    query = "CALL cdc.set_guardrail('invalid_threshold', -1)"
    code, stdout, stderr = run_query(query)

    # Should return error
    if "InvalidGuardrailConfiguration" in stderr or "error" in stdout.lower():
        print("  ✓ CDC validation: PASSED")
        return True
    else:
        print("  ✗ CDC validation: FAILED (expected error)")
        print(f"    stdout: {stdout}")
        return False


def test_audit_logging():
    """Test audit.get_recent_events procedure."""
    print("Testing audit logging...")

    # Call audit procedure
    query = "CALL audit.get_recent_events({limit: 10})"
    code, stdout, stderr = run_query(query)

    # Should return structured data with columns
    if code == 0 and ("seq_no" in stdout or "columns" in stdout):
        print("  ✓ Audit logging: PASSED")
        return True
    else:
        print("  ✗ Audit logging: FAILED")
        print(f"    stdout: {stdout}")
        return False


def main():
    print("=" * 60)
    print("Testing Recently Implemented Features")
    print("=" * 60)
    print()

    results = []

    # Category 4: Complex Execution
    results.append(("split-node-into-multiple", test_split_node()))
    results.append(("NOT (pattern)", test_not_pattern()))
    results.append(("batch-create-relationships", test_batch_create_relationships()))

    # Category 3: System Features
    results.append(("TDE validation", test_tde_validation()))
    results.append(("CDC validation", test_cdc_validation()))
    results.append(("Audit logging", test_audit_logging()))

    # Auth system (requires server mode)
    auth_result = test_auth_system()
    if auth_result is not None:
        results.append(("Auth system", auth_result))

    print()
    print("=" * 60)
    print("Summary")
    print("=" * 60)

    passed = sum(1 for _, r in results if r is True)
    failed = sum(1 for _, r in results if r is False)

    print(f"Total: {passed} passed, {failed} failed")

    if failed > 0:
        print("\nFailed tests:")
        for name, result in results:
            if result is False:
                print(f"  - {name}")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
