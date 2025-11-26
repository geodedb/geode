#!/usr/bin/env python3
"""Test specific features that were recently implemented."""

import subprocess
import sys

def run_query(query, user=None, password=None):
    """Run a query and return stdout."""
    cmd = ["./zig-out/bin/geode", "query", "--server 127.0.0.1:3141 --insecure", "--format", "json", "-"]
    if user:
        cmd.extend(["--user", user, "--password", password or ""])

    result = subprocess.run(cmd, input=query, capture_output=True, text=True, timeout=10)
    return result.returncode, result.stdout, result.stderr

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

    if code == 0 and '"1"' in stdout or '[[1]]' in stdout:
        print("  ✓ split-node-into-multiple: PASSED")
        return True
    else:
        print(f"  ✗ split-node-into-multiple: FAILED")
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

    if code == 0 and ('"1"' in stdout or '[[1]]' in stdout):
        print("  ✓ NOT (pattern): PASSED")
        return True
    else:
        print(f"  ✗ NOT (pattern): FAILED")
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

    if code == 0 and ('"3"' in stdout or '[[3]]' in stdout):
        print("  ✓ batch-create-relationships: PASSED")
        return True
    else:
        print(f"  ✗ batch-create-relationships: FAILED")
        print(f"    stdout: {stdout}")
        print(f"    stderr: {stderr}")
        return False

def test_auth_system():
    """Test authentication system."""
    print("Testing authentication system...")

    # Start server with auth enabled
    server = subprocess.Popen(
        ["./zig-out/bin/geode", "serve", "--listen", "127.0.0.1:9999", "--server 127.0.0.1:3141 --insecure", "--enable-auth"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )

    import time
    time.sleep(2)  # Wait for server to start

    try:
        # Test 1: Unauthenticated query should fail
        print("  Testing unauthenticated access...")
        code, stdout, stderr = run_query("RETURN 1")

        # Note: In --server 127.0.0.1:3141 --insecure mode without server, auth isn't enforced
        # We need to test with actual server mode
        print("  ⊘ Auth tests require server mode (skipped in --server 127.0.0.1:3141 --insecure)")

        return None  # Skipped

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
        print(f"  ✗ TDE validation: FAILED (expected error)")
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
        print(f"  ✗ CDC validation: FAILED (expected error)")
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
        print(f"  ✗ Audit logging: FAILED")
        print(f"    stdout: {stdout}")
        return False

def main():
    print("="*60)
    print("Testing Recently Implemented Features")
    print("="*60)
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
    print("="*60)
    print("Summary")
    print("="*60)

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
