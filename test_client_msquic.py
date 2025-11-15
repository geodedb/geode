#!/usr/bin/env python3
"""Test Python client with msquic server."""

import asyncio
import sys
import os

# Add clients/python to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'clients', 'python'))

from geode_client import Connection, GeodeError


async def test_basic_connection():
    """Test basic connection to msquic server."""
    print("Testing Python client connection to msquic server...")
    
    try:
        # Connect with self-signed cert (no verification)
        async with Connection(
            host="127.0.0.1",
            port=7567,
            skip_verify=True  # Self-signed cert
        ) as conn:
            print("✅ Connected to server via QUIC+TLS")
            
            # Try a simple query
            result = await conn.execute("RETURN 1 AS x")
            rows = [row async for row in result]
            print(f"✅ Query executed: {rows}")
            
            if rows and len(rows) > 0 and rows[0].get('x') == 1:
                print("✅ Result matches expected value")
                return True
            else:
                print(f"❌ Unexpected result: {rows}")
                return False
                
    except GeodeError as e:
        print(f"❌ Geode error: {e}")
        return False
    except Exception as e:
        print(f"❌ Connection failed: {e}")
        import traceback
        traceback.print_exc()
        return False


async def test_transaction():
    """Test transaction support."""
    print("\nTesting transactions...")
    
    try:
        async with Connection(
            host="127.0.0.1",
            port=7567,
            skip_verify=True
        ) as conn:
            # Begin transaction
            await conn.begin()
            print("✅ Transaction started")
            
            # Execute query in transaction
            result = await conn.execute("RETURN 2 AS y")
            rows = [row async for row in result]
            print(f"✅ Query in transaction: {rows}")
            
            # Commit
            await conn.commit()
            print("✅ Transaction committed")
            return True
            
    except Exception as e:
        print(f"❌ Transaction test failed: {e}")
        return False


async def test_multiple_queries():
    """Test multiple queries on same connection."""
    print("\nTesting multiple queries...")
    
    try:
        async with Connection(
            host="127.0.0.1",
            port=7567,
            skip_verify=True
        ) as conn:
            for i in range(3):
                result = await conn.execute(f"RETURN {i} AS num")
                rows = [row async for row in result]
                print(f"✅ Query {i}: {rows}")
                
            return True
            
    except Exception as e:
        print(f"❌ Multiple queries test failed: {e}")
        return False


async def main():
    """Run all tests."""
    tests = [
        ("Basic Connection", test_basic_connection),
        ("Transactions", test_transaction),
        ("Multiple Queries", test_multiple_queries),
    ]
    
    results = []
    for name, test_func in tests:
        print(f"\n{'='*60}")
        print(f"Test: {name}")
        print('='*60)
        try:
            result = await test_func()
            results.append((name, result))
        except Exception as e:
            print(f"❌ Test crashed: {e}")
            results.append((name, False))
    
    # Summary
    print(f"\n{'='*60}")
    print("Test Summary")
    print('='*60)
    passed = sum(1 for _, result in results if result)
    total = len(results)
    
    for name, result in results:
        status = "✅ PASS" if result else "❌ FAIL"
        print(f"{status}: {name}")
    
    print(f"\nResults: {passed}/{total} tests passed")
    
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
